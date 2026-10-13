import Foundation
import Observation
import os

@MainActor
public protocol RunNotifying {
    func runEnded(_ record: RunRecord, routine: Routine)
    /// The routine was turned off after failing `failures` times in a row.
    func routinePaused(_ routine: Routine, failures: Int)
    /// Another process, such as an agent through the `rota` command, added the routine.
    func routineAdded(_ routine: Routine)
    /// A session (or, without one, a process outside Rota) sent the user a notification.
    func sessionNotified(_ record: RunRecord?, routine: Routine?, title: String?, text: String, needsReply: Bool)
}

public extension RunNotifying {
    func routineAdded(_ routine: Routine) {}
    func sessionNotified(_ record: RunRecord?, routine: Routine?, title: String?, text: String, needsReply: Bool) {}
}

/// Owns the routines, fires them on schedule and tracks the runs in flight.
@MainActor
@Observable
public final class Scheduler {
    /// A slot missed by up to this long (the Mac slept, Rota was closed) runs once
    /// late, as Claude Desktop does; an older one is recorded as skipped.
    public static let missedRunGrace: TimeInterval = 7 * 24 * 3600
    /// Scheduled runs failing this many times in a row pause the routine.
    public static let failuresBeforePause = 5
    static let log = Logger(subsystem: "com.wiltodelta.rota", category: "scheduler")

    public private(set) var routines: [Routine] = []
    public internal(set) var active: [String: RunRecord] = [:]
    /// Bumped whenever a run record changes, so views re-read history.
    public private(set) var historyVersion = 0
    public var lastError: String?

    @ObservationIgnored public var now: () -> Date = Date.init
    @ObservationIgnored public var calendar = Calendar.current
    @ObservationIgnored public var executable: (Harness) -> String = { $0.defaultExecutable() }
    /// What the user's `~/.claude.json` turns on for Claude runs; read at each run, as Claude would.
    @ObservationIgnored public var claudeSettings: () -> ClaudeUserSettings = { ClaudeUserSettings.read() }
    /// Whether the Mac is online; while it is not, scheduled runs and resumes wait.
    @ObservationIgnored public var isOnline: () -> Bool = { true }
    /// Whether a screen session is still up; a seam so tests never run `screen`.
    @ObservationIgnored public var sessionAlive: (String) -> Bool = { ScreenRun.alive($0) }
    /// Routines whose run was going when the Mac went to sleep.
    @ObservationIgnored var sleptThrough: Set<String> = []
    /// Sessions cut off by sleep, shutdown or a lost network, to continue once online: record id to routine id.
    @ObservationIgnored var pendingResumes: [UUID: String] = [:]
    /// Agent runs that failed on the network before they had a session, to run again: routine id to trigger.
    @ObservationIgnored var pendingReruns: [String: RunTrigger] = [:]
    /// Reruns in a row per routine, reset by a run that gets a session.
    @ObservationIgnored var reruns: [String: Int] = [:]
    @ObservationIgnored var retryScheduled = false
    /// Asks the harness's service whether it answers (`ServiceProbe`); a seam so tests never use the network.
    @ObservationIgnored public var probe: (Harness, @escaping @MainActor (Bool) -> Void) -> Void = ServiceProbe.check
    /// Whether Claude routines run as an interactive `claude` (Settings), else `claude -p`.
    @ObservationIgnored public var claudeInteractive: () -> Bool = { false }
    @ObservationIgnored public var notifier: RunNotifying?
    /// The `rota` command inside the app, handed to runs as ROTA_CLI.
    @ObservationIgnored public var commandPath: String?
    @ObservationIgnored let store: RoutineStore
    @ObservationIgnored public let history: RunHistory
    @ObservationIgnored let launcher: RoutineLaunching
    @ObservationIgnored var controls: [String: RunControl] = [:]
    /// When each routine's current run started, a continued session included.
    @ObservationIgnored private var runStarts: [String: Date] = [:]
    @ObservationIgnored private var timer: Timer?

    public init(location: StorageLocation, launcher: RoutineLaunching) {
        store = RoutineStore(location: location)
        history = RunHistory(location: location)
        self.launcher = launcher
        do {
            routines = try store.load()
        } catch {
            lastError = "Could not read routines: \(error.localizedDescription)"
            Self.log.error("Could not read routines: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Closes runs a previous launch left open and starts the 30-second tick.
    public func start() {
        // Runs the last launch left open were cut off: the Mac shut down, or Rota stopped.
        for record in history.closeOrphans(routineIDs: routines.map(\.id), now: now())
        where resumable(record) && !stillRunning(record) {
            pendingResumes[record.id] = record.routineID
        }
        tick()
        resumePending()
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    public func tick() {
        // Offline (just woken, no Wi-Fi yet), a due slot waits rather than failing; it runs once online.
        guard isOnline() else { return }
        let current = now()
        var changed = false
        for index in routines.indices where routines[index].enabled {
            guard let schedule = try? CronSchedule(routines[index].schedule) else { continue }
            guard let due = routines[index].nextFire else {
                routines[index].nextFire = schedule.next(after: current, calendar: calendar)
                changed = true
                continue
            }
            guard due <= current else { continue }
            routines[index].nextFire = schedule.next(after: current, calendar: calendar)
            changed = true
            let routine = routines[index]
            if current.timeIntervalSince(due) > Self.missedRunGrace {
                record(skipped: "missed the \(due.formatted(date: .abbreviated, time: .shortened)) slot",
                       routine: routine, at: current)
            } else if active[routine.id] != nil {
                record(skipped: "the previous run was still going", routine: routine, at: current, notify: false)
            } else {
                // A minute late is the tick's own lag; later than that, the slot was missed.
                run(routine, trigger: current.timeIntervalSince(due) > 120 ? .catchUp : .scheduled)
            }
        }
        if changed { persist() }
    }

    // MARK: Editing

    public func routine(_ id: String) -> Routine? {
        routines.first { $0.id == id }
    }

    /// Adds or replaces a routine, recomputing its next slot from the saved schedule.
    public func save(_ routine: Routine) {
        var routine = routine
        routine.nextFire = routine.enabled
            ? (try? CronSchedule(routine.schedule))?.next(after: now(), calendar: calendar)
            : nil
        if let index = routines.firstIndex(where: { $0.id == routine.id }) {
            routines[index] = routine
        } else {
            routines.append(routine)
        }
        persist()
    }

    public func setEnabled(_ enabled: Bool, for id: String) {
        guard var routine = routine(id) else { return }
        routine.enabled = enabled
        save(routine)
    }

    public func delete(_ id: String) {
        stop(id)
        routines.removeAll { $0.id == id }
        history.removeAll(for: id)
        persist()
    }

    private func persist() {
        do {
            try store.save(routines)
        } catch {
            lastError = "Could not save routines: \(error.localizedDescription)"
            Self.log.error("Could not save routines: \(error.localizedDescription, privacy: .public)")
        }
    }

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
            mode: harness.launchMode, timeout: routine.timeLimitMinutes.map { TimeInterval($0 * 60) },
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
    private func start(_ record: RunRecord, spec: LaunchSpec) {
        var record = record
        let id = record.routineID
        if record.configuration == nil {
            record.configuration = RunConfiguration(model: spec.model, effort: spec.effort,
                                                     workingDirectory: spec.workingDirectory)
        }
        let events = RunEvents(
            session: { [weak self] session in self?.attachSession(session, to: id) },
            finished: { [weak self] outcome in self?.finish(id, outcome: outcome) },
            metadata: { [weak self] value in self?.updateMetadata(value, routineID: id, recordID: record.id) },
            eventError: { [weak self] reason in self?.eventWriteFailed(reason, routineID: id, recordID: record.id) },
            requests: { [weak self] requests in self?.updateRequests(requests, routineID: id, recordID: record.id) })
        do {
            active[id] = record
            runStarts[id] = now()
            controls[id] = try launcher.launch(spec, events: events)
            // The launch may already have reported the session (a runner that waits
            // on a process spins the run loop), so save what is active, not the copy.
            saveRecord(active[id] ?? record)
            Self.log.info("Started \(id, privacy: .public) on \(record.harness.rawValue, privacy: .public)")
        } catch {
            active[id] = nil
            record.outcome = .launchFailed(error.localizedDescription)
            record.endedAt = now()
            saveRecord(record)
            if let routine = self.routine(id) { notifier?.runEnded(record, routine: routine) }
        }
    }

    public func stop(_ id: String) {
        controls[id]?.stop()
    }

    public func stopAll() {
        controls.values.forEach { $0.stop() }
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

    func continueSession(_ record: RunRecord, with message: String, messageID: String = UUID().uuidString,
                         attachments: [ChatAttachment] = []) {
        guard let routine = routine(record.routineID), let session = record.sessionID,
              let logPath = record.logPath else { return }
        var record = record
        record.outcome = .running
        record.endedAt = nil
        var launch = spec(for: routine, record: record, harness: record.harness, prompt: message,
                          log: URL(fileURLWithPath: logPath), resume: session)
        launch.messageID = messageID
        launch.attachments = attachments
        start(record, spec: launch)
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
        if record.attention == record.requests?.first?.title { record.attention = nil }
        record.requests = nil
        active[routineID] = nil
        controls[routineID] = nil
        runStarts[routineID] = nil
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
        setEnabled(false, for: routineID)
        Self.log.warning("\(routineID, privacy: .public) paused after \(Self.failuresBeforePause) failures")
        notifier?.routinePaused(routine, failures: Self.failuresBeforePause)
    }

    /// Marks `record`'s session read, now that the user has it open.
    public func markRead(_ record: RunRecord) {
        guard record.isUnread, var stored = history.records(for: record.routineID).first(where: { $0.id == record.id })
        else { return }
        stored.readAt = now()
        saveRecord(stored)
    }

    /// Sessions that finished since the user last opened them.
    public var unreadCount: Int {
        _ = historyVersion
        return allRecords().filter(\.isUnread).count
    }

    private func record(skipped reason: String, routine: Routine, at date: Date, notify: Bool = true) {
        let record = RunRecord(routineID: routine.id, trigger: .scheduled, harness: routine.harness,
                               startedAt: date, endedAt: date, outcome: .skipped(reason))
        saveRecord(record)
        Self.log.warning("\(routine.id, privacy: .public) skipped: \(reason, privacy: .public)")
        if notify { notifier?.runEnded(record, routine: routine) }
    }

    func saveRecord(_ record: RunRecord) {
        do {
            try history.upsert(record)
        } catch {
            lastError = "Could not save run history: \(error.localizedDescription)"
        }
        historyVersion += 1
    }
}

// Message delivery and attachment retention share the scheduler's actor isolation.
extension Scheduler {
    /// Sends `message` into `record`'s session: into the live session while it
    /// runs, or by continuing the finished session as a run of its own.
    @discardableResult
    public func message(_ message: String, to record: RunRecord) -> String? {
        try? self.message(ChatMessage(text: message), to: record)
    }

    @discardableResult
    public func message(_ message: ChatMessage, to record: RunRecord) throws -> String? {
        guard canMessage(record), let logPath = record.logPath else { return nil }
        let messageID = UUID().uuidString
        let message = try ChatAttachmentStore.retain(message, log: URL(fileURLWithPath: logPath), messageID: messageID)
        // Answering is what the session waited for; the continued run saves this copy, so it must not carry the mark.
        dismissAttention(record)
        var record = record
        record.attention = nil
        if isActive(record) {
            controls[record.routineID]?.send(message, id: messageID)
        } else {
            continueSession(record, with: message.text, messageID: messageID, attachments: message.attachments)
        }
        return messageID
    }
}
