import Foundation

extension Scheduler {
    /// Every routine's sessions, most recently active first. Skipped slots stay in each
    /// routine's own history: they have nothing to open.
    public func allRecords() -> [RunRecord] {
        _ = historyVersion
        _ = routines
        if let cachedSessions { return cachedSessions }
        let sessions = routines.flatMap { records(for: $0.id) }.filter { !$0.isSkip }
            .sorted { $0.isMoreRecentlyActive(than: $1) }
        cachedSessions = sessions
        return sessions
    }

    /// A display snapshot, reused until history changes. Mutation guards read
    /// `history` directly so confirmation dialogs still recheck the stored record.
    public func records(for routineID: String) -> [RunRecord] {
        _ = historyVersion
        if let records = cachedHistory[routineID] { return records }
        let records = readHistory(history, routineID)
        cachedHistory[routineID] = records
        return records
    }

    public func isActive(_ record: RunRecord) -> Bool {
        active[record.id] != nil
    }

    public func hasActiveSession(_ routineID: String) -> Bool {
        active.values.contains { $0.routineID == routineID }
    }

    /// Routine-level actions default to the session most recently started or continued.
    public func activeRecord(for routineID: String) -> RunRecord? {
        active.values.filter { $0.routineID == routineID }.max {
            (runStarts[$0.id] ?? $0.startedAt, $0.id.uuidString)
                < (runStarts[$1.id] ?? $1.startedAt, $1.id.uuidString)
        }
    }

    /// Different conversations may run together; two owners of one native conversation may not.
    func hasNativeConflict(_ record: RunRecord) -> Bool {
        guard let session = record.sessionID else { return false }
        let matches = { (other: RunRecord) in
            other.id != record.id && other.harness == record.harness && other.sessionID == session
        }
        return active.values.contains(where: matches) || survivingSessions.values.contains(where: matches)
    }

    /// Whether Rota can message this session now, running or finished.
    public func canMessage(_ record: RunRecord) -> Bool {
        guard !openingTerminals.contains(record.id), survivingSessions[record.id] == nil,
              record.sessionID != nil, !hasNativeConflict(record) else { return false }
        if isActive(record), active[record.id]?.terminalState != nil { return false }
        let running = isActive(record)
        let mode = running ? record.launchMode ?? record.harness.launchMode : record.harness.launchMode
        return mode.capabilities.messages != .terminal
    }

    func updateConfiguration(_ configuration: SessionConfiguration, routineID: String, runID: UUID) {
        guard var record = active[runID], record.routineID == routineID else { return }
        let previous = record
        if let model = configuration.model {
            if model != record.reportedModel { record.reportedModelTitle = nil }
            record.reportedModel = model
        }
        if let title = configuration.modelTitle { record.reportedModelTitle = title }
        if let effort = configuration.effort { record.reportedEffort = effort }
        guard previous != record else { return }
        active[runID] = record
        saveRecord(record)
    }
}
