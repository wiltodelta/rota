import Foundation

/// Notifications a routine sends while it runs, through `rota notify` or the
/// `notify_user` MCP tool, and sessions that wait for the user's answer.
extension Scheduler {
    /// Tells every run which session it is and how to reach Rota, so a routine
    /// can notify without naming itself.
    /// A session as it is now: the running copy, which the run's end saves, or the stored one.
    public func current(_ id: UUID, routineID: String? = nil) -> RunRecord? {
        if let routineID {
            if let running = active[routineID], running.id == id { return running }
            return history.records(for: routineID).first { $0.id == id }
        }
        return active.values.first { $0.id == id } ?? routines.lazy.compactMap { routine in
            self.history.records(for: routine.id).first { $0.id == id }
        }.first
    }

    /// `current(_:)` for a session id as callers write it, in any letter case.
    func current(_ text: String, routineID: String? = nil) -> RunRecord? {
        UUID(uuidString: text).flatMap { current($0, routineID: routineID) }
    }

    func sessionEnvironment(_ record: RunRecord) -> [String: String] {
        var environment = ["ROTA_SESSION": record.id.uuidString, "ROTA_ROUTINE": record.routineID]
        if let cli = commandPath { environment["ROTA_CLI"] = cli }
        return environment
    }

    /// Shows `text` as a notification from the session `session` (a run's id),
    /// or from `routineID`'s running or latest session, or from no session.
    /// `needsReply` marks the session until the user answers it.
    @discardableResult
    public func notify(_ text: String, title: String?, session: String?, routineID: String?,
                       needsReply: Bool) throws -> RunRecord? {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ControlError("The notification needs a message.")
        }
        var record = try notifyingRecord(session: session, routineID: routineID)
        if needsReply {
            guard let found = record else {
                throw ControlError("A notification that needs a reply must come from a session.")
            }
            record = setAttention(text, on: found)
        }
        notifier?.sessionNotified(record, routine: record.flatMap { routine($0.routineID) }, title: title,
                                  text: text, needsReply: needsReply)
        return record
    }

    private func notifyingRecord(session: String?, routineID: String?) throws -> RunRecord? {
        if let session {
            guard let record = current(session) else { throw ControlError("No session \(session).") }
            return record
        }
        guard let routineID else { return nil }
        guard routine(routineID) != nil else { throw ControlError("No routine \(routineID).") }
        return active[routineID] ?? history.records(for: routineID).first { !$0.isSkip }
    }

    private func setAttention(_ text: String?, on record: RunRecord) -> RunRecord {
        var record = record
        record.attention = text
        if active[record.routineID]?.id == record.id { active[record.routineID] = record }
        saveRecord(record)
        return record
    }

    public func dismissAttention(_ record: RunRecord) {
        guard let now = current(record.id, routineID: record.routineID), now.attention != nil,
              now.requests?.isEmpty != false else { return }
        _ = setAttention(nil, on: now)
    }

    /// Sessions waiting for the user's answer.
    public var attentionCount: Int {
        _ = historyVersion
        return allRecords().filter { $0.attention != nil }.count
    }
}
