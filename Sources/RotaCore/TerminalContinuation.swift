import Foundation

extension Scheduler {
    /// The terminal command for `record`'s session, with the harness's executable filled in.
    public func terminalCommand(for record: RunRecord) -> (executable: String, arguments: [String])? {
        if isSurvivingSession(record) {
            if let path = record.logPath, let lease = RunLease.read(URL(fileURLWithPath: path)),
               let name = lease.screenName, lease.process?.exists == true {
                return (ScreenRun.screen, ["-x", name])
            }
            if record.harness == .shell || record.harness == .claude, let session = record.sessionID {
                let name = record.harness == .shell ? session : ClaudeInteractiveRun.screenName(session)
                if sessionAlive(name) { return (ScreenRun.screen, ["-r", name]) }
            }
            return nil
        }
        if isActive(record), let command = controls[record.routineID]?.attachCommand, let program = command.first {
            return (program, Array(command.dropFirst()))
        }
        guard isActive(record) || active[record.routineID] == nil,
              let session = record.sessionID,
              let (program, arguments) = record.harness.terminal(session: session, running: isActive(record))
        else { return nil }
        return (program ?? executable(record.harness), arguments)
    }

    /// Resumes the native CLI under Rota's ownership without submitting a new prompt.
    public func continueInTerminal(_ record: RunRecord) async -> Bool {
        guard !openingTerminals.contains(record.id), !hasSurvivingSession(record.routineID),
              active[record.routineID] == nil,
              let record = current(record.id, routineID: record.routineID),
              let routine = routine(record.routineID), let session = record.sessionID,
              let logPath = record.logPath,
              let command = record.harness.terminal(session: session, running: false) else { return false }
        openingTerminals.insert(record.id)
        defer { openingTerminals.remove(record.id) }
        let lookup = terminalTranscript
        let source = await Task.detached { lookup(record.harness, session) }.value
        guard let source else {
            lastError = "Could not find this session's native transcript. Terminal continuation was not started."
            return false
        }
        guard active[record.routineID] == nil, !hasSurvivingSession(record.routineID), let latest = current(record.id),
              latest.sessionID == session, latest.logPath == logPath,
              self.routine(record.routineID) != nil else { return false }
        var next = latest
        next.outcome = .running
        next.endedAt = nil
        next.questions = next.questions?.filter { $0.replyViaMessage == true }
        next.terminalState = .waiting
        var spec = spec(for: routine, record: latest, harness: record.harness, prompt: "",
                        log: URL(fileURLWithPath: logPath), resume: session)
        spec.mode = .terminal(record.harness)
        spec.arguments = command.arguments
        spec.timeout = nil
        spec.terminalTranscript = source
        return start(next, spec: spec)
    }

    @discardableResult
    func continueSession(_ record: RunRecord, with message: String) -> Bool {
        guard !hasSurvivingSession(record.routineID), let reopened = reopen(record, prompt: message) else {
            return false
        }
        var record = reopened.0
        let spec = reopened.1
        record.reportedModel = nil
        record.reportedEffort = nil
        record.questions = record.questions?.filter { $0.replyViaMessage == true }
        record.terminalState = nil
        return start(record, spec: spec)
    }

    /// `record` running again, with the spec that resumes its session into its own log.
    func reopen(_ record: RunRecord, prompt: String) -> (RunRecord, LaunchSpec)? {
        guard let routine = routine(record.routineID), let session = record.sessionID,
              let logPath = record.logPath else { return nil }
        var record = record
        record.outcome = .running
        record.endedAt = nil
        return (record, spec(for: routine, record: record, harness: record.harness, prompt: prompt,
                             log: URL(fileURLWithPath: logPath), resume: session))
    }

}
