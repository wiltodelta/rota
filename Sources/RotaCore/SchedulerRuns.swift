import Foundation

/// Launch and completion stay on the scheduler actor, with one token per invocation.
extension Scheduler {
    // MARK: Running

    public func run(_ routine: Routine, trigger: RunTrigger) {
        guard active[routine.id] == nil else { return }
        var record = RunRecord(routineID: routine.id, trigger: trigger, harness: routine.harness,
                               startedAt: now(), outcome: .running)
        let logURL = history.logFile(for: record)
        record.logPath = logURL.path
        start(record, spec: spec(for: routine, record: record, harness: routine.harness, prompt: routine.prompt,
                                 log: logURL))
    }

    /// How `routine` runs `prompt` on `harness`: a new session, or `resume`'s.
    private func spec(for routine: Routine, record: RunRecord, harness: Harness, prompt: String, log: URL,
                      resume: String? = nil) -> LaunchSpec {
        // A session started on another harness keeps that harness; the routine's model ids are not its.
        let sameHarness = harness == routine.harness
        // Only Claude reads ~/.claude.json, a file of hundreds of KB on a busy Mac.
        let settings = harness == .claude ? claudeSettings() : ClaudeUserSettings()
        let captured = resume == nil ? nil : record.configuration
        var spec = LaunchSpec(
            executable: executable(harness), prompt: prompt,
            arguments: harness.arguments(settings: settings, resume: resume),
            workingDirectory: captured?.workingDirectory ?? routine.workingDirectory,
            environment: sessionEnvironment(record),
            mode: harness.launchMode, timeout: routine.timeLimitMinutes.map { TimeInterval($0) * 60 },
            log: log, resume: resume,
            model: captured.map(\.model) ?? (sameHarness ? routine.model : nil),
            effort: captured.map(\.effort) ?? (sameHarness ? routine.effort : nil))
        if harness == .claude, claudeInteractive() {
            if settings.trusts(spec.workingDirectory) {
                spec.mode = .claudeInteractive
            } else {
                spec.notice = "ran with claude -p: Claude Code has not been trusted in this folder; "
                    + "open Claude Code there once and trust it to run interactively, with computer use"
            }
        }
        return spec
    }

    /// Launches `spec` as `record`, which becomes the routine's active run.
    @discardableResult
    private func start(_ record: RunRecord, spec: LaunchSpec) -> Bool {
        var record = record
        record.stopRequestedAt = nil
        let id = record.routineID
        let token = UUID()
        if record.configuration == nil {
            record.configuration = RunConfiguration(model: spec.model, effort: spec.effort,
                                                     workingDirectory: spec.workingDirectory)
        }
        guard saveRecord(record) else { return false }
        runTokens[id] = token
        let events = events(for: record, token: token)
        do {
            active[id] = record
            runStarts[id] = now()
            let control = try launcher.launch(spec, events: events)
            // A synchronous completion may have ended or continued this invocation already.
            if runTokens[id] == token, active[id] != nil {
                controls[id] = control
            }
            Self.log.info("Started \(id, privacy: .public) on \(record.harness.rawValue, privacy: .public)")
            return true
        } catch {
            active[id] = nil
            controls[id] = nil
            runStarts[id] = nil
            runTokens[id] = nil
            record.outcome = .launchFailed(error.localizedDescription)
            record.endedAt = now()
            saveRecord(record)
            if let routine = self.routine(id) { notifier?.runEnded(record, routine: routine) }
            return false
        }
    }

    private func events(for record: RunRecord, token: UUID) -> RunEvents {
        let id = record.routineID
        let recordID = record.id
        return RunEvents(
            session: { [weak self] session in
                guard self?.runTokens[id] == token else { return }
                self?.attachSession(session, to: id)
            },
            finished: { [weak self] outcome in
                self?.retiringControls[token] = nil
                guard self?.runTokens[id] == token else { return }
                self?.finish(id, outcome: outcome)
            },
            metadata: { [weak self] value in
                guard self?.runTokens[id] == token else { return }
                self?.updateMetadata(value, routineID: id, recordID: recordID)
            },
            eventError: { [weak self] reason in
                guard self?.runTokens[id] == token else { return }
                self?.eventWriteFailed(reason, routineID: id, recordID: recordID)
            },
            requests: { [weak self] requests in
                guard self?.runTokens[id] == token else { return }
                self?.updateRequests(requests, routineID: id, recordID: recordID)
            })
    }

    @discardableResult
    public func stop(_ id: String) -> Bool {
        var persisted = true
        if var record = active[id] {
            if record.stopRequestedAt == nil { record.stopRequestedAt = now() }
            active[id] = record
            persisted = saveRecord(record)
        }
        controls[id]?.stop()
        return persisted
    }

    public func stopAll() {
        Array(controls.keys).forEach { stop($0) }
    }

    /// Every routine's sessions, newest first. Skipped slots stay in each
    /// routine's own history: they have nothing to open.
    public func allRecords() -> [RunRecord] {
        routines.flatMap { history.records(for: $0.id) }.filter { !$0.isSkip }
            .sorted { $0.startedAt > $1.startedAt }
    }

    /// Whether Rota can message `record`'s session now, running or finished.
    public func canMessage(_ record: RunRecord) -> Bool {
        guard record.sessionID != nil else { return false }
        let running = isActive(record)
        // While another run of the routine works, its finished sessions wait.
        if !running && active[record.routineID] != nil { return false }
        return record.harness.takesMessages
    }

    /// When `record`'s run started, while it runs: a continued session's run, not the session's first.
    public func runStartedAt(_ record: RunRecord) -> Date? {
        isActive(record) ? runStarts[record.routineID] : nil
    }

    public func isActive(_ record: RunRecord) -> Bool {
        active[record.routineID]?.id == record.id
    }

    /// The terminal command for `record`'s session, with the harness's executable filled in.
    public func terminalCommand(for record: RunRecord) -> (executable: String, arguments: [String])? {
        if isActive(record), let command = controls[record.routineID]?.attachCommand, let program = command.first {
            return (program, Array(command.dropFirst()))
        }
        guard let session = record.sessionID,
              let (program, arguments) = record.harness.terminal(session: session, running: isActive(record))
        else { return nil }
        return (program ?? executable(record.harness), arguments)
    }

    @discardableResult
    func continueSession(_ record: RunRecord, with message: String, messageID: String = UUID().uuidString,
                         attachments: [ChatAttachment] = []) -> Bool {
        guard let routine = routine(record.routineID), let session = record.sessionID,
              let logPath = record.logPath else { return false }
        var record = record
        record.outcome = .running
        record.endedAt = nil
        var launch = spec(for: routine, record: record, harness: record.harness, prompt: message,
                          log: URL(fileURLWithPath: logPath), resume: session)
        launch.messageID = messageID
        launch.attachments = attachments
        return start(record, spec: launch)
    }

    private func eventWriteFailed(_ reason: String, routineID: String, recordID: UUID) {
        guard var record = active[routineID], record.id == recordID else { return }
        record.eventError = reason
        active[routineID] = record
        saveRecord(record)
    }

    private func updateMetadata(_ value: SessionMetadata, routineID: String, recordID: UUID) {
        guard var record = active[routineID], record.id == recordID else { return }
        record.metadata = SessionMetadata(model: value.model ?? record.metadata?.model,
                                          effort: value.effort ?? record.metadata?.effort)
        active[routineID] = record
        saveRecord(record)
    }

    private func attachSession(_ session: String, to routineID: String) {
        guard var record = active[routineID] else { return }
        record.sessionID = session
        active[routineID] = record
        saveRecord(record)
    }

    private func finish(_ routineID: String, outcome: RunOutcome) {
        guard var record = active[routineID] else { return }
        record.outcome = outcome
        record.endedAt = now()
        record.clearProviderRequests()
        active[routineID] = nil
        controls[routineID] = nil
        runStarts[routineID] = nil
        runTokens[routineID] = nil
        saveRecord(record)
        recover(record, sleptThrough: self.sleptThrough.remove(routineID) != nil)
        Self.log.info("\(routineID, privacy: .public) ended: \(outcome.title, privacy: .public)")
        if let routine = routine(routineID) { notifier?.runEnded(record, routine: routine) }
        pauseAfterRepeatedFailures(routineID)
    }

    /// Turns a routine off once its last scheduled runs all failed, instead of
    /// failing and notifying on every slot.
    private func pauseAfterRepeatedFailures(_ routineID: String) {
        guard let routine = routine(routineID), routine.enabled else { return }
        // Skips are not failures of the routine: an overlap only means a long run.
        let scheduled = history.records(for: routineID).filter { record in
            guard record.trigger != .manual, record.outcome != .running else { return false }
            if case .skipped = record.outcome { return false }
            return true
        }
        let recent = scheduled.prefix(Self.failuresBeforePause)
        guard recent.count == Self.failuresBeforePause, recent.allSatisfy({ $0.outcome.isFailure }) else { return }
        guard setEnabled(false, for: routineID) else { return }
        Self.log.warning("\(routineID, privacy: .public) paused after \(Self.failuresBeforePause) failures")
        notifier?.routinePaused(routine, failures: Self.failuresBeforePause)
    }

}
