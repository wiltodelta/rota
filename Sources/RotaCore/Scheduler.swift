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

    public internal(set) var routines: [Routine] = [] {
        didSet { cachedSessions = nil }
    }
    public internal(set) var active: [String: RunRecord] = [:]
    /// Bumped whenever a run record changes, so views re-read history.
    public internal(set) var historyVersion = 0 {
        didSet {
            cachedHistory.removeAll(keepingCapacity: true)
            cachedSessions = nil
        }
    }
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
    var survivingSessions: [String: RunRecord] = [:]
    @ObservationIgnored var reconciliationRetry: [String: Date] = [:]
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
    /// Read seam for verifying that UI refreshes reuse decoded history.
    @ObservationIgnored var readHistory: (RunHistory, String) -> [RunRecord] = { $0.records(for: $1) }
    @ObservationIgnored var cachedHistory: [String: [RunRecord]] = [:]
    @ObservationIgnored var cachedSessions: [RunRecord]?
    @ObservationIgnored let launcher: RoutineLaunching
    @ObservationIgnored var questionDeliveries: [UUID: Set<String>] = [:]
    @ObservationIgnored var questionReplies: [UUID: [String: @Sendable (QuestionAnswer) -> Void]] = [:]
    @ObservationIgnored var hookAnswers: [String: QuestionAnswer] = [:]
    @ObservationIgnored var controls: [String: RunControl] = [:]
    /// Each launch has its own identity, including continuations of the same record.
    @ObservationIgnored var launchIDs: [String: UUID] = [:]
    /// When each routine's current run started, a continued session included.
    @ObservationIgnored var runStarts: [String: Date] = [:]
    /// Messages a run handed back as its session ended, by routine; the session continues with them.
    @ObservationIgnored var lateMessages: [String: [String]] = [:]
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
        for record in history.closeOrphans(routineIDs: routines.map(\.id), now: now()) {
            if stillRunning(record) {
                if adoptSurviving(record) { continue }
                survivingSessions[record.routineID] = record
            } else if record.sessionID != nil
                || record.logPath.map({ RunLease.read(URL(fileURLWithPath: $0)) != nil }) == true {
                reconcileNative(record)
            }
        }
        historyVersion += 1
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
        refreshSurvivingSession()
        reconcilePending()
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
            } else if active[routine.id] != nil || survivingSessions[routine.id] != nil {
                record(skipped: "the previous run was still going", routine: routine, at: current, notify: false)
            } else {
                // A minute late is the tick's own lag; later than that, the slot was missed.
                run(routine, trigger: current.timeIntervalSince(due) > 120 ? .catchUp : .scheduled)
            }
        }
        if changed { persist() }
    }

    // MARK: Running

    public func run(_ routine: Routine, trigger: RunTrigger) {
        guard active[routine.id] == nil else { return }
        guard !hasSurvivingSession(routine.id) else {
            lastError = "This routine still has a native session running. Close it before starting another."
            return
        }
        var record = RunRecord(routineID: routine.id, trigger: trigger, harness: routine.harness,
                               startedAt: now(), outcome: .running)
        record.model = routine.model
        record.effort = routine.effort
        let logURL = history.logFile(for: record)
        record.logPath = logURL.path
        start(record, spec: spec(for: routine, record: record, harness: routine.harness, prompt: routine.prompt,
                                 log: logURL))
    }

    /// How `routine` runs `prompt` on `harness`: a new session, or `resume`'s.
    func spec(for routine: Routine, record: RunRecord, harness: Harness, prompt: String, log: URL,
              resume: String? = nil) -> LaunchSpec {
        // Historical sessions keep their original options; never borrow a later routine edit.
        // Only Claude reads ~/.claude.json, a file of hundreds of KB on a busy Mac.
        let settings = harness == .claude ? claudeSettings() : ClaudeUserSettings()
        var spec = LaunchSpec(
            executable: executable(harness), prompt: prompt,
            arguments: harness.arguments(settings: settings, resume: resume),
            workingDirectory: routine.workingDirectory,
            environment: sessionEnvironment(record),
            mode: harness.launchMode, timeout: routine.timeLimitMinutes.map { TimeInterval($0 * 60) },
            log: log, resume: resume,
            model: record.model, effort: record.effort)
        if harness == .claude, claudeInteractive() {
            if settings.trusts(routine.workingDirectory) {
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
    func start(_ record: RunRecord, spec: LaunchSpec) -> Bool {
        var record = record
        record.launchMode = spec.mode
        record.executablePath = spec.executable
        record.cliVersion = nil
        record.serverVersion = nil
        record.needsReconciliation = nil
        let id = record.routineID
        let launchID = UUID()
        record.executionID = launchID
        launchIDs[id] = launchID
        let events = events(for: record, launchID: launchID)
        do {
            active[id] = record
            runStarts[id] = now()
            let control = try launcher.launch(spec, events: events)
            guard launchIDs[id] == launchID else { return true }
            controls[id] = control
            // The launch may already have reported the session (a runner that waits
            // on a process spins the run loop), so save what is active, not the copy.
            saveRecord(active[id] ?? record)
            Self.log.info("Started \(id, privacy: .public) on \(record.harness.rawValue, privacy: .public)")
            return true
        } catch {
            guard launchIDs[id] == launchID else { return false }
            launchIDs[id] = nil
            runStarts[id] = nil
            active[id] = nil
            record.outcome = .launchFailed(error.localizedDescription)
            record.endedAt = now()
            saveRecord(record)
            if let routine = self.routine(id) { notifier?.runEnded(record, routine: routine) }
            return false
        }
    }

    public func stop(_ id: String) {
        if let record = active[id] { cancelQuestions(on: record) }
        controls[id]?.stop()
    }

    public func stopAll() {
        Array(controls.keys).forEach { stop($0) }
    }

    /// Sends `message` into `record`'s session: into the live session while it
    /// runs, or by continuing the finished session as a run of its own.
    @discardableResult
    public func message(_ message: String, to record: RunRecord) -> Bool {
        guard var record = current(record.id, routineID: record.routineID) else { return false }
        guard !record.hasBlockingQuestion else { return false }
        // The delivery path saves this copy, including the cleared attention mark.
        record.attention = record.nextQuestion?.title
        return deliverMessage(message, to: record)
    }

    /// Shared delivery for ordinary messages and explicit answers to async questions.
    func deliverMessage(_ message: String, to record: RunRecord) -> Bool {
        guard canMessage(record) else { return false }
        if isActive(record) {
            guard let control = controls[record.routineID] else { return false }
            control.send(message)
            active[record.routineID] = record
            saveRecord(record)
            return true
        }
        return continueSession(record, with: message)
    }

    /// The current run start, or current native terminal turn start, while it works.
    public func runStartedAt(_ record: RunRecord) -> Date? {
        isActive(record) ? runStarts[record.routineID] : nil
    }

    /// Transcript lookup is off the main actor; tests supply an isolated producer file.
    public var terminalTranscript: @Sendable (Harness, String) -> URL? = NativeTranscript.locate
    var openingTerminals: Set<UUID> = []

    func attachSession(_ session: String, to routineID: String) {
        guard var record = active[routineID] else { return }
        record.sessionID = session
        active[routineID] = record
        saveRecord(record)
    }

    func finish(_ routineID: String, outcome: RunOutcome) {
        guard var record = active[routineID] else { return }
        cancelQuestions(on: record)
        record = current(record.id, routineID: routineID) ?? record
        record.outcome = outcome
        record.endedAt = now()
        active[routineID] = nil
        launchIDs[routineID] = nil
        controls[routineID] = nil
        runStarts[routineID] = nil
        saveRecord(record)
        let slept = self.sleptThrough.remove(routineID) != nil
        if record.needsReconciliation == true {
            reserveUnverified(record)
        } else {
            recover(record, sleptThrough: slept)
        }
        Self.log.info("\(routineID, privacy: .public) ended: \(outcome.title, privacy: .public)")
        if let routine = routine(routineID) { notifier?.runEnded(record, routine: routine) }
        pauseAfterRepeatedFailures(routineID)
        if let messages = lateMessages.removeValue(forKey: routineID) {
            continueLate(record, with: messages.joined(separator: "\n\n"))
        }
    }

    /// A message the run could no longer take waits for the run's end, then continues its session.
    func receiveLate(_ message: String, routineID: String, runID: UUID) {
        if active[routineID]?.id == runID { return lateMessages[routineID, default: []].append(message) }
        guard let record = current(runID, routineID: routineID), record.outcome != .running else { return }
        continueLate(record, with: message)
    }

    private func continueLate(_ record: RunRecord, with message: String) {
        guard !continueSession(record, with: message) else { return }
        Self.log.error("\(record.routineID, privacy: .public): a late message could not continue the session")
    }

    /// Turns a routine off once its last scheduled runs all failed, instead of
    /// failing and notifying on every slot.
    private func pauseAfterRepeatedFailures(_ routineID: String) {
        guard let routine = routine(routineID), routine.enabled else { return }
        // Skips are not failures of the routine: an overlap only means a long run.
        let scheduled = history.records(for: routineID).filter { record in
            guard record.trigger != .manual, record.terminalState == nil,
                  record.outcome != .running else { return false }
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
