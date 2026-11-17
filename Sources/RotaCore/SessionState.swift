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

    /// A message can go out now: the session takes messages and no question blocks them.
    public func acceptsMessage(_ record: RunRecord) -> Bool {
        canMessage(record) && !record.hasBlockingQuestion
    }

    /// Whether the next message may run on another model or effort: an agent session between runs.
    public func canConfigure(_ record: RunRecord) -> Bool {
        record.harness.isAgent && !isActive(record) && canMessage(record)
    }

    /// The model and effort the session's next run uses; nil leaves the choice to the harness.
    /// The reported values belong to the last run, so they go until the next run reports again;
    /// earlier answers keep theirs in `configurations`.
    @discardableResult
    public func configure(_ record: RunRecord, model: String?, effort: String?) -> Bool {
        guard var stored = current(record.id, routineID: record.routineID), canConfigure(stored) else { return false }
        guard stored.model != model || stored.effort != effort else { return true }
        // A session from before marks were kept: its answers so far ran on what it last reported.
        if stored.configurations == nil, stored.reportedModel ?? stored.model != nil {
            stored.configurations = [stored.reportedMark(from: 0)]
        }
        stored.model = model
        stored.effort = effort
        stored.reportedModel = nil
        stored.reportedModelTitle = nil
        stored.reportedEffort = nil
        saveRecord(stored)
        return true
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
        if let start = configuration.fromItem {
            // Runs only move forward, so this run's mark is the last; one matching the run before adds nothing.
            var marks = (record.configurations ?? []).filter { $0.fromItem != start }
            let mark = record.reportedMark(from: start)
            if marks.last.map({ !$0.labels(like: mark) }) ?? true { marks.append(mark) }
            record.configurations = marks
        }
        guard previous != record else { return }
        active[runID] = record
        saveRecord(record)
    }
}
