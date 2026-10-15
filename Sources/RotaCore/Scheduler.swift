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
    @ObservationIgnored var runTokens: [String: UUID] = [:]
    /// Deleted runs keep their control alive until Stop completes its cleanup.
    @ObservationIgnored var retiringControls: [UUID: RunControl] = [:]
    @ObservationIgnored private var routinesReadable = true
    /// When each routine's current run started, a continued session included.
    @ObservationIgnored var runStarts: [String: Date] = [:]
    @ObservationIgnored private var timer: Timer?

    public init(location: StorageLocation, launcher: RoutineLaunching) {
        store = RoutineStore(location: location)
        history = RunHistory(location: location)
        self.launcher = launcher
        do {
            routines = try store.load()
        } catch {
            routinesReadable = false
            lastError = "Could not read routines: \(error.localizedDescription)"
            Self.log.error("Could not read routines: \(error.localizedDescription, privacy: .private)")
        }
        do {
            for routine in routines { _ = try history.loadRecords(for: routine.id) }
        } catch {
            lastError = "Could not read run history: \(error.localizedDescription)"
            Self.log.error("Could not read run history: \(error.localizedDescription, privacy: .private)")
        }
    }

    /// Closes runs a previous launch left open and starts the 30-second tick.
    public func start() {
        guard timer == nil else { return }
        // Runs the last launch left open were cut off: the Mac shut down, or Rota stopped.
        let orphans: [RunRecord]
        do {
            orphans = try history.closeOrphans(routineIDs: routines.map(\.id), now: now())
        } catch {
            orphans = []
            lastError = "Could not recover unfinished sessions: \(error.localizedDescription)"
            Self.log.error("Could not recover unfinished sessions: \(error.localizedDescription, privacy: .private)")
        }
        for record in orphans
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
        // Agent slots wait for their service; local shell commands do not require a network.
        let online = isOnline()
        let current = now()
        let previous = routines
        var dueRoutines: [(Routine, Date)] = []
        var changed = false
        for index in routines.indices where routines[index].enabled {
            if routines[index].harness.isAgent && !online { continue }
            guard let schedule = try? CronSchedule(routines[index].schedule) else { continue }
            guard let due = routines[index].nextFire else {
                routines[index].nextFire = schedule.next(after: current, calendar: calendar)
                changed = true
                continue
            }
            guard due <= current else { continue }
            routines[index].nextFire = schedule.next(after: current, calendar: calendar)
            changed = true
            dueRoutines.append((routines[index], due))
        }
        if changed, !persist() {
            routines = previous
            return
        }
        // A due slot is durably advanced before any process or notification starts.
        for (routine, due) in dueRoutines {
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
    }

    // MARK: Editing

    public func routine(_ id: String) -> Routine? {
        routines.first { $0.id == id }
    }

    public func containsStorageID(_ id: String) -> Bool {
        let key = Routine.storageIDKey(id)
        return routines.contains { Routine.storageIDKey($0.id) == key }
    }

    /// Adds or replaces a routine, recomputing its next slot from the saved schedule.
    @discardableResult
    public func save(_ routine: Routine) -> Bool {
        let previous = routines
        var routine = routine
        routine.nextFire = routine.enabled
            ? (try? CronSchedule(routine.schedule))?.next(after: now(), calendar: calendar)
            : nil
        if let index = routines.firstIndex(where: { $0.id == routine.id }) {
            routines[index] = routine
        } else {
            routines.append(routine)
        }
        guard persist() else { routines = previous; return false }
        return true
    }

    @discardableResult
    public func setEnabled(_ enabled: Bool, for id: String) -> Bool {
        guard var routine = routine(id) else { return false }
        routine.enabled = enabled
        return save(routine)
    }

    @discardableResult
    public func delete(_ id: String) -> Bool {
        let previous = routines
        routines.removeAll { $0.id == id }
        guard persist() else { routines = previous; return false }
        stop(id)
        if let token = runTokens.removeValue(forKey: id), let control = controls.removeValue(forKey: id) {
            retiringControls[token] = control
        }
        active[id] = nil
        runStarts[id] = nil
        sleptThrough.remove(id)
        pendingResumes = pendingResumes.filter { $0.value != id }
        pendingReruns[id] = nil
        reruns[id] = nil
        history.removeAll(for: id)
        historyVersion += 1
        return true
    }

    private func persist() -> Bool {
        guard routinesReadable else {
            lastError = "Routines could not be read. Repair routines.json and reopen Rota before saving changes."
            return false
        }
        do {
            try store.save(routines)
            return true
        } catch {
            lastError = "Could not save routines: \(error.localizedDescription)"
            Self.log.error("Could not save routines: \(error.localizedDescription, privacy: .public)")
            return false
        }
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

    @discardableResult
    func saveRecord(_ record: RunRecord) -> Bool {
        do {
            try history.upsert(record)
        } catch {
            lastError = "Could not save run history: \(error.localizedDescription)"
            Self.log.error("Could not save run history: \(error.localizedDescription, privacy: .private)")
            return false
        }
        historyVersion += 1
        return true
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
        guard var record = current(record.id, routineID: record.routineID) else { return nil }
        guard canMessage(record), let logPath = record.logPath else { return nil }
        guard !message.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || !message.attachments.isEmpty else {
            throw ControlError("The message needs text or an attachment.")
        }
        let messageID = UUID().uuidString
        let message = try ChatAttachmentStore.retain(message, log: URL(fileURLWithPath: logPath), messageID: messageID)
        // Answering is what the session waited for; the continued run saves this copy, so it must not carry the mark.
        dismissAttention(record)
        record.attention = nil
        if isActive(record) {
            controls[record.routineID]?.send(message, id: messageID)
        } else {
            guard continueSession(record, with: message.text, messageID: messageID,
                                  attachments: message.attachments) else {
                let latest = current(record.id, routineID: record.routineID)
                throw ControlError(lastError ?? latest?.outcome.title ?? "Could not continue the session.")
            }
        }
        return messageID
    }
}
