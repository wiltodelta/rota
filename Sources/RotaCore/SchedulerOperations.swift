internal import CRotaFFI
import Foundation

extension Scheduler {
    private func decodeSchedulerEnvelope(_ raw: String?, method: String) throws -> Any {
        guard let raw,
              let env = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [String: Any] else {
            throw FFICallError(message: "Invalid FFI response for \(method).")
        }
        if let snap = env["snapshot"] {
            applySnapshotObject(snap)
        }
        if let err = env["error"] as? String {
            throw FFICallError(message: err)
        }
        return env["ok"] ?? NSNull()
    }

    func callRustRaw(_ method: String, params: [String: Any] = [:], includeSeams: Bool = true) throws -> Any {
        guard let handle else { throw FFICallError(message: "Scheduler is unavailable.") }
        var fullParams = params
        if includeSeams {
            fullParams["seams"] = seamsDictionary()
        }
        let encoded = FFIJSON.encodeParams(fullParams)
        let raw = method.withCString { mPtr in
            encoded.withCString { pPtr in
                FFIJSON.string(taking: rota_scheduler_call(handle, mPtr, pPtr))
            }
        }
        return try decodeSchedulerEnvelope(raw, method: method)
    }

    @discardableResult
    func callRust(_ method: String, params: [String: Any] = [:]) -> Bool {
        (try? callRustRaw(method, params: params)) != nil
    }

    public func routine(_ id: String) -> Routine? {
        routines.first { $0.id == id }
    }

    @discardableResult
    public func save(_ routine: Routine) -> Bool {
        guard let obj = FFIJSON.toJSONValue(routine) else { return false }
        return callRust("saveRoutine", params: ["routine": obj])
    }

    @discardableResult
    public func setEnabled(_ enabled: Bool, for id: String) -> Bool {
        callRust("setEnabled", params: ["id": id, "enabled": enabled])
    }

    @discardableResult
    public func delete(_ id: String) -> Bool {
        callRust("deleteRoutine", params: ["id": id])
    }

    @discardableResult
    public func run(_ routine: Routine, trigger: RunTrigger) -> Bool {
        guard let obj = FFIJSON.toJSONValue(routine),
              let trig = FFIJSON.toJSONValue(trigger) else { return false }
        return callRust("runRoutine", params: [
            "routine": obj,
            "trigger": trig
        ])
    }

    public func stop(_ routineID: String) {
        _ = callRust("stopRoutine", params: ["id": routineID])
    }

    public func stop(_ id: UUID) {
        _ = callRust("stopSession", params: ["id": id.uuidString])
    }

    public func stopAll() {
        _ = callRust("stopAll")
    }

    @discardableResult
    public func message(_ message: String, to record: RunRecord) -> Bool {
        callRust("messageEncoded", params: ["id": record.id.uuidString, "message": message])
    }

    public func runStartedAt(_ record: RunRecord) -> Date? {
        isActive(record) ? runStarts[record.id] : nil
    }

    public func markRead(_ record: RunRecord) {
        guard record.isUnread else { return }
        _ = callRust("markRead", params: ["id": record.id.uuidString])
    }

    public func markUnread(_ record: RunRecord) {
        guard record.canMarkUnread else { return }
        _ = callRust("markUnread", params: ["id": record.id.uuidString])
    }

    public var unreadCount: Int {
        _ = historyVersion
        return allRecords().filter(\.isUnread).count
    }

    public var attentionCount: Int {
        _ = historyVersion
        return allRecords().filter { $0.attention != nil }.count
    }

    public func dismissAttention(_ record: RunRecord) {
        _ = callRust("dismissAttention", params: ["id": record.id.uuidString])
    }

    public func notify(
        _ text: String,
        title: String?,
        session: String?,
        routineID: String?,
        needsReply: Bool
    ) throws -> RunRecord? {
        var params: [String: Any] = ["text": text, "needsReply": needsReply]
        if let title { params["title"] = title }
        if let session { params["session"] = session }
        if let routineID { params["routineID"] = routineID }
        do {
            let raw = try callRustRaw("notify", params: params)
            if raw is NSNull { return nil }
            return try FFIJSON.decode(RunRecord.self, from: raw)
        } catch let err as FFICallError {
            throw ControlError(err.message)
        }
    }

    public func answerQuestion(_ id: String, on record: RunRecord, answer: QuestionAnswer) throws {
        guard let ansObj = FFIJSON.toJSONValue(answer) else { return }
        do {
            _ = try callRustRaw("answerQuestion", params: [
                "sessionID": record.id.uuidString,
                "questionID": id,
                "answer": ansObj
            ])
        } catch let err as FFICallError {
            throw ControlError(err.message)
        }
    }
}

extension Scheduler {
    public func allRecords() -> [RunRecord] {
        _ = historyVersion
        _ = routines
        if let cachedSessions { return cachedSessions }
        let sessions = routines.flatMap { records(for: $0.id) }.filter { !$0.isSkip }
            .sorted { $0.isMoreRecentlyActive(than: $1) }
        cachedSessions = sessions
        return sessions
    }

    public func records(for routineID: String) -> [RunRecord] {
        _ = historyVersion
        if let cached = cachedHistory[routineID] { return cached }
        let loaded = history.records(for: routineID)
        cachedHistory[routineID] = loaded
        return loaded
    }

    public func current(_ id: UUID, routineID: String? = nil) -> RunRecord? {
        if let running = active[id], routineID == nil || running.routineID == routineID {
            return running
        }
        let routineIDs = routineID.map { [$0] } ?? routines.map(\.id)
        for candidate in routineIDs {
            if let found = records(for: candidate).first(where: { $0.id == id }) {
                return found
            }
        }
        return nil
    }

    public func isActive(_ record: RunRecord) -> Bool {
        active[record.id] != nil
    }

    public func hasActiveSession(_ routineID: String) -> Bool {
        active.values.contains { $0.routineID == routineID }
    }

    public func activeRecord(for routineID: String) -> RunRecord? {
        active.values.filter { $0.routineID == routineID }.max {
            (runStarts[$0.id] ?? $0.startedAt, $0.id.uuidString)
                < (runStarts[$1.id] ?? $1.startedAt, $1.id.uuidString)
        }
    }

    public func isSurvivingSession(_ record: RunRecord) -> Bool {
        survivingSessions[record.id] != nil
    }

    func hasNativeConflict(_ record: RunRecord) -> Bool {
        guard let session = record.sessionID else { return false }
        let matches = { (other: RunRecord) in
            other.id != record.id && other.harness == record.harness && other.sessionID == session
        }
        return active.values.contains(where: matches) || survivingSessions.values.contains(where: matches)
    }

    public func canMessage(_ record: RunRecord) -> Bool {
        guard !openingTerminals.contains(record.id), survivingSessions[record.id] == nil,
              record.sessionID != nil, !hasNativeConflict(record) else { return false }
        let runningRecord = active[record.id]
        if runningRecord?.terminalState != nil { return false }
        let mode = runningRecord != nil ? record.launchMode ?? record.harness.launchMode : record.harness.launchMode
        return mode.capabilities.messages != .terminal
    }

    public func acceptsMessage(_ record: RunRecord) -> Bool {
        canMessage(record) && !record.hasBlockingQuestion
    }

    public func canConfigure(_ record: RunRecord) -> Bool {
        record.harness.isAgent && !isActive(record) && canMessage(record)
    }

    @discardableResult
    public func configure(_ record: RunRecord, model: String?, effort: String?) -> Bool {
        var params: [String: Any] = ["id": record.id.uuidString]
        if let model { params["model"] = model }
        if let effort { params["effort"] = effort }
        return callRust("configureSession", params: params)
    }

    public func canDelete(_ record: RunRecord) -> Bool {
        guard !isActive(record), !isSurvivingSession(record),
              let stored = records(for: record.routineID).first(where: { $0.id == record.id }) else {
            return false
        }
        return stored.outcome != .running && stored.needsReconciliation != true
    }

    @discardableResult
    public func deleteSession(_ record: RunRecord) -> Bool {
        callRust("deleteSession", params: ["id": record.id.uuidString])
    }

    private func canStartFrom(_ record: RunRecord) -> Bool {
        !record.isSkip && record.outcome != .running && routine(record.routineID) != nil
            && !isActive(record) && !isSurvivingSession(record)
            && !openingTerminals.contains(record.id) && !hasNativeConflict(record)
    }

    public func canRestart(_ record: RunRecord) -> Bool {
        record.harness.isAgent && canStartFrom(record)
    }

    func callRustAsync(_ method: String, params: [String: Any] = [:]) async throws -> Any {
        guard let rawHandle = handle else { throw FFICallError(message: "Scheduler is unavailable.") }
        var fullParams = params
        fullParams["seams"] = seamsDictionary()
        let encoded = FFIJSON.encodeParams(fullParams)
        nonisolated(unsafe) let sendableHandle = rawHandle
        let raw = await Task.detached {
            method.withCString { mPtr in
                encoded.withCString { pPtr in
                    FFIJSON.string(taking: rota_scheduler_call(sendableHandle, mPtr, pPtr))
                }
            }
        }.value
        return try decodeSchedulerEnvelope(raw, method: method)
    }

    public func restart(_ record: RunRecord, with harness: Harness) async -> RunRecord? {
        guard let raw = try? await callRustAsync("restart", params: [
            "id": record.id.uuidString,
            "harness": harness.rawValue
        ]) else { return nil }
        return try? FFIJSON.decode(RunRecord.self, from: raw)
    }

    public func canDiscuss(_ record: RunRecord) -> Bool {
        record.harness == .shell && canStartFrom(record)
    }

    public func discussions(of record: RunRecord) -> [RunRecord] {
        guard let raw = try? callRustRaw("discussions", params: ["id": record.id.uuidString], includeSeams: false),
              let decoded = try? FFIJSON.decode([RunRecord].self, from: raw) else { return [] }
        return decoded
    }

    public func discuss(
        _ record: RunRecord,
        with harness: Harness,
        model: String? = nil,
        effort: String? = nil,
        message: String
    ) async -> RunRecord? {
        var params: [String: Any] = [
            "id": record.id.uuidString,
            "harness": harness.rawValue,
            "prompt": message
        ]
        if let model { params["model"] = model }
        if let effort { params["effort"] = effort }
        guard let raw = try? await callRustAsync("discuss", params: params) else { return nil }
        return try? FFIJSON.decode(RunRecord.self, from: raw)
    }

    public func terminalCommand(for record: RunRecord) -> (executable: String, arguments: [String])? {
        guard let recObj = FFIJSON.toJSONValue(record),
              let raw = try? callRustRaw("terminalCommand", params: ["record": recObj], includeSeams: false),
              let dict = raw as? [String: Any],
              let exe = dict["executable"] as? String,
              let args = dict["arguments"] as? [String] else {
            return nil
        }
        return (exe, args)
    }

    public func continueInTerminal(_ record: RunRecord) async -> Bool {
        (try? await callRustAsync("continueInTerminal", params: ["id": record.id.uuidString])) != nil
    }

    public static func parseCalendarAnchor(_ text: String, calendar: Calendar = .current) -> Date? {
        guard let iso = try? FFIBridge.callCore(String?.self, "calendar.parseAnchor", params: [
            "text": text,
            "timeZone": calendar.timeZone.identifier
        ]) else {
            return nil
        }
        return FFIDateCoding.parse(iso)
    }

    public func control(_ method: String, _ params: [String: Any]) -> Result<Any, ControlError> {
        do {
            let val = try callRustRaw("controlRequest", params: [
                "method": method,
                "params": params
            ])
            return .success(val)
        } catch let err as FFICallError {
            return .failure(ControlError(err.message))
        } catch {
            return .failure(ControlError(error.localizedDescription))
        }
    }

    public func controlRequest(_ method: String, _ params: [String: Any]) async -> Result<Any, ControlError> {
        control(method, params)
    }
}
