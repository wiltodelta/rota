import Foundation

extension Scheduler {
    /// Every routine's sessions, newest first. Skipped slots stay in each
    /// routine's own history: they have nothing to open.
    public func allRecords() -> [RunRecord] {
        routines.flatMap { history.records(for: $0.id) }.filter { !$0.isSkip }
            .sorted { $0.startedAt > $1.startedAt }
    }

    public func isActive(_ record: RunRecord) -> Bool {
        active[record.routineID]?.id == record.id
    }

    /// Whether Rota can message this session now, running or finished.
    public func canMessage(_ record: RunRecord) -> Bool {
        guard !openingTerminals.contains(record.id), record.sessionID != nil else { return false }
        if isActive(record), active[record.routineID]?.terminalState != nil { return false }
        let running = isActive(record)
        // While another run of the routine works, its finished sessions wait.
        if !running && active[record.routineID] != nil { return false }
        return record.harness.takesMessages
    }

    func updateConfiguration(_ configuration: SessionConfiguration, routineID: String, runID: UUID) {
        guard var record = active[routineID], record.id == runID else { return }
        let previous = record
        if let model = configuration.model { record.reportedModel = model }
        if let effort = configuration.effort { record.reportedEffort = effort }
        guard previous != record else { return }
        active[routineID] = record
        saveRecord(record)
    }
}
