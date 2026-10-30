import Foundation

extension Scheduler {
    /// Every routine's sessions, newest first. Skipped slots stay in each
    /// routine's own history: they have nothing to open.
    public func allRecords() -> [RunRecord] {
        _ = historyVersion
        _ = routines
        if let cachedSessions { return cachedSessions }
        let sessions = routines.flatMap { records(for: $0.id) }.filter { !$0.isSkip }
            .sorted { $0.startedAt > $1.startedAt }
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
        active[record.routineID]?.id == record.id
    }

    /// Whether Rota can message this session now, running or finished.
    public func canMessage(_ record: RunRecord) -> Bool {
        guard !openingTerminals.contains(record.id), survivingSessions[record.routineID] == nil,
              record.sessionID != nil else { return false }
        if isActive(record), active[record.routineID]?.terminalState != nil { return false }
        let running = isActive(record)
        // While another run of the routine works, its finished sessions wait.
        if !running && active[record.routineID] != nil { return false }
        let mode = running ? record.launchMode ?? record.harness.launchMode : record.harness.launchMode
        return mode.capabilities.messages != .terminal
    }

    func updateConfiguration(_ configuration: SessionConfiguration, routineID: String, runID: UUID) {
        guard var record = active[routineID], record.id == runID else { return }
        let previous = record
        if let model = configuration.model {
            if model != record.reportedModel { record.reportedModelTitle = nil }
            record.reportedModel = model
        }
        if let title = configuration.modelTitle { record.reportedModelTitle = title }
        if let effort = configuration.effort { record.reportedEffort = effort }
        guard previous != record else { return }
        active[routineID] = record
        saveRecord(record)
    }
}
