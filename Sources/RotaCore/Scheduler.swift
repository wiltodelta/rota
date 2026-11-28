internal import CRotaFFI
import Foundation
import Observation
import os

@MainActor
public protocol RunNotifying {
    func runEnded(_ record: RunRecord, routine: Routine)
    func routinePaused(_ routine: Routine, failures: Int)
    func routineAdded(_ routine: Routine)
    func sessionNotified(_ record: RunRecord?, routine: Routine?, title: String?, text: String, needsReply: Bool)
}

public extension RunNotifying {
    func routineAdded(_ routine: Routine) {}
    func sessionNotified(_ record: RunRecord?, routine: Routine?, title: String?, text: String, needsReply: Bool) {}
}

struct SchedulerSnapshotPayload: Decodable {
    var revision: UInt64
    var routines: [Routine]
    var active: [String: RunRecord]
    var survivingSessions: [String: RunRecord]
    var openingTerminals: [String]
    var runStarts: [String: Date]
    var lastError: String?
}

private struct RevisionEventPayload: Decodable {
    var revision: UInt64
}

private struct WeakSchedulerBox: @unchecked Sendable {
    weak var scheduler: Scheduler?
}

private let schedulerCallbacks = FFICallbackRegistry<WeakSchedulerBox>()

private func schedulerEventTrampoline(
    ctx: UInt,
    kind: UInt32,
    payloadPtr: UnsafePointer<CChar>?
) {
    let payload = payloadPtr.map { String(cString: $0) } ?? "{}"
    DispatchQueue.main.async {
        MainActor.assumeIsolated {
            schedulerCallbacks.lookup(ctx)?.scheduler?.handleRustEvent(kind: kind, payloadJSON: payload)
        }
    }
}

/// Owns scheduled routines and sessions, delegating execution, persistence and resilience to `rota-core`.
@MainActor
@Observable
public final class Scheduler {
    static let log = Logger(subsystem: "com.wiltodelta.rota", category: "scheduler")

    public internal(set) var routines: [Routine] = [] {
        didSet { cachedSessions = nil }
    }
    public internal(set) var active: [UUID: RunRecord] = [:]
    public internal(set) var historyVersion = 0 {
        didSet {
            cachedHistory.removeAll(keepingCapacity: true)
            cachedSessions = nil
        }
    }
    public var lastError: String? {
        didSet {
            guard !suppressErrorSync, lastError != oldValue else { return }
            _ = try? callRustRaw("setLastError", params: ["error": lastError as Any], includeSeams: false)
        }
    }

    @ObservationIgnored private var hasCustomNow = false
    @ObservationIgnored public var now: () -> Date = Date.init {
        didSet { hasCustomNow = true }
    }
    @ObservationIgnored public var calendar = Calendar.current
    @ObservationIgnored public var executable: (Harness) -> String = { $0.defaultExecutable() }
    @ObservationIgnored public var isOnline: () -> Bool = { true }
    @ObservationIgnored public var claudeInteractive: () -> Bool = { false }
    @ObservationIgnored public var notifier: RunNotifying?
    @ObservationIgnored public var commandPath: String?
    @ObservationIgnored public let history: RunHistory
    @ObservationIgnored var cachedHistory: [String: [RunRecord]] = [:]
    @ObservationIgnored var cachedSessions: [RunRecord]?

    @ObservationIgnored var survivingSessions: [UUID: RunRecord] = [:]
    @ObservationIgnored var openingTerminals: Set<UUID> = []
    @ObservationIgnored var runStarts: [UUID: Date] = [:]

    @ObservationIgnored nonisolated(unsafe) var handle: OpaquePointer?
    @ObservationIgnored nonisolated(unsafe) private var callbackToken: UInt = 0
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored var lastAppliedRevision: UInt64 = 0
    @ObservationIgnored private var refreshScheduled = false
    @ObservationIgnored private var suppressErrorSync = false

    public init(location: StorageLocation, launcher: RoutineLaunching) {
        history = RunHistory(location: location)
        let token = schedulerCallbacks.register(WeakSchedulerBox(scheduler: self))
        callbackToken = token
        var errPtr: UnsafeMutablePointer<CChar>?
        let realLauncher = launcher is ProcessLauncher
        let created = location.root.path.withCString { rootPtr in
            location.logs.path.withCString { logsPtr in
                rota_scheduler_create(rootPtr, logsPtr, realLauncher, token, schedulerEventTrampoline, &errPtr)
            }
        }
        handle = created
        if created == nil {
            let msg = FFIJSON.string(taking: errPtr) ?? "Could not initialize scheduler."
            suppressErrorSync = true
            lastError = msg
            suppressErrorSync = false
            Self.log.error("\(msg, privacy: .public)")
        } else {
            refreshSnapshotFromRust()
        }
    }

    deinit {
        if callbackToken != 0 {
            schedulerCallbacks.unregister(callbackToken)
        }
        if let handle {
            rota_scheduler_free(handle)
        }
    }

    public func start() {
        _ = callRust("start")
        timer?.invalidate()
        let nextTimer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(nextTimer, forMode: .common)
        timer = nextTimer
    }

    public func tick() {
        _ = callRust("tick")
    }

    public func systemWillSleep() {
        _ = callRust("systemWillSleep")
    }

    public func networkBecameAvailable() {
        _ = callRust("networkBecameAvailable")
    }

    func seamsDictionary() -> [String: Any] {
        var exeMap: [String: String] = [:]
        for harness in Harness.allCases {
            exeMap[harness.rawValue] = executable(harness)
        }
        var seams: [String: Any] = [
            "executables": exeMap,
            "claudeInteractive": claudeInteractive(),
            "online": isOnline(),
            "timeZone": calendar.timeZone.identifier,
            "commandPath": commandPath as Any
        ]
        seams["now"] = hasCustomNow ? FFIDateCoding.format(now()) : NSNull()
        return seams
    }

    func refreshSnapshotFromRust() {
        guard let handle,
              let raw = FFIJSON.string(taking: rota_scheduler_snapshot(handle)),
              let snap = try? FFIJSON.decoder.decode(SchedulerSnapshotPayload.self, from: Data(raw.utf8)) else {
            return
        }
        applySnapshot(snap)
    }

    private static func mapUUIDKeys<Value>(_ raw: [String: Value]) -> [UUID: Value] {
        var mapped: [UUID: Value] = [:]
        for (key, val) in raw {
            if let uuid = UUID(uuidString: key) { mapped[uuid] = val }
        }
        return mapped
    }

    func applySnapshotObject(_ obj: Any) {
        guard let snap = try? FFIJSON.decode(SchedulerSnapshotPayload.self, from: obj) else { return }
        applySnapshot(snap)
    }

    private func applySnapshot(_ snap: SchedulerSnapshotPayload) {
        let revisionBumped = snap.revision != lastAppliedRevision
        lastAppliedRevision = snap.revision
        if routines != snap.routines { routines = snap.routines }
        let nextActive = Self.mapUUIDKeys(snap.active)
        if active != nextActive { active = nextActive }
        survivingSessions = Self.mapUUIDKeys(snap.survivingSessions)
        openingTerminals = Set(snap.openingTerminals.compactMap(UUID.init(uuidString:)))
        runStarts = Self.mapUUIDKeys(snap.runStarts)
        if lastError != snap.lastError {
            suppressErrorSync = true
            lastError = snap.lastError
            suppressErrorSync = false
        }
        if revisionBumped { historyVersion += 1 }
    }

    func handleRustEvent(kind: UInt32, payloadJSON: String) {
        if kind == ROTA_EVENT_REVISION_CHANGED.rawValue {
            if let rev = try? FFIJSON.decoder.decode(RevisionEventPayload.self, from: Data(payloadJSON.utf8)),
               rev.revision <= lastAppliedRevision {
                return
            }
            guard !refreshScheduled else { return }
            refreshScheduled = true
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.refreshScheduled = false
                    self.refreshSnapshotFromRust()
                }
            }
            return
        }
        refreshSnapshotFromRust()
        guard let dict = (try? JSONSerialization.jsonObject(with: Data(payloadJSON.utf8))) as? [String: Any] else {
            return
        }
        deliverNotificationEvent(kind: kind, dict: dict)
    }

    private func deliverNotificationEvent(kind: UInt32, dict: [String: Any]) {
        switch kind {
        case ROTA_EVENT_RUN_ENDED.rawValue:
            if let recObj = dict["record"], let routObj = dict["routine"],
               let rec = try? FFIJSON.decode(RunRecord.self, from: recObj),
               let rout = try? FFIJSON.decode(Routine.self, from: routObj) {
                notifier?.runEnded(rec, routine: rout)
            }
        case ROTA_EVENT_ROUTINE_PAUSED.rawValue:
            if let routObj = dict["routine"],
               let rout = try? FFIJSON.decode(Routine.self, from: routObj),
               let count = dict["failures"] as? Int {
                notifier?.routinePaused(rout, failures: count)
            }
        case ROTA_EVENT_ROUTINE_ADDED.rawValue:
            if let routObj = dict["routine"],
               let rout = try? FFIJSON.decode(Routine.self, from: routObj) {
                notifier?.routineAdded(rout)
            }
        case ROTA_EVENT_SESSION_NOTIFIED.rawValue:
            let rec = dict["record"].flatMap { try? FFIJSON.decode(RunRecord.self, from: $0) }
            let rout = dict["routine"].flatMap { try? FFIJSON.decode(Routine.self, from: $0) }
            let title = dict["title"] as? String
            let text = dict["text"] as? String ?? ""
            let needsReply = dict["needsReply"] as? Bool ?? false
            notifier?.sessionNotified(rec, routine: rout, title: title, text: text, needsReply: needsReply)
        default:
            break
        }
    }
}
