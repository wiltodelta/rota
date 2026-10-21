import Foundation

extension Scheduler {
    /// Resumes the native CLI under Rota's ownership without submitting a new prompt.
    public func continueInTerminal(_ record: RunRecord) async -> Bool {
        guard !openingTerminals.contains(record.id), !hasSurvivingClaude(record.routineID),
              active[record.routineID] == nil,
              let record = current(record.id, routineID: record.routineID),
              let routine = routine(record.routineID), let session = record.sessionID,
              let logPath = record.logPath,
              let command = record.harness.terminal(session: session, running: false) else { return false }
        openingTerminals.insert(record.id)
        defer { openingTerminals.remove(record.id) }
        let lookup = terminalTranscript
        let source = await Task.detached { lookup(record.harness, session) }.value
        guard let source else {
            lastError = "Could not find this session's native transcript. Terminal continuation was not started."
            return false
        }
        guard active[record.routineID] == nil, !hasSurvivingClaude(record.routineID), let latest = current(record.id),
              latest.sessionID == session, latest.logPath == logPath,
              self.routine(record.routineID) != nil else { return false }
        var next = latest
        next.outcome = .running
        next.endedAt = nil
        next.questions = next.questions?.filter { $0.replyViaMessage == true }
        next.terminalState = .waiting
        var spec = spec(for: routine, record: latest, harness: record.harness, prompt: "",
                        log: URL(fileURLWithPath: logPath), resume: session)
        spec.mode = .terminal(record.harness)
        spec.arguments = command.arguments
        spec.timeout = nil
        spec.terminalTranscript = source
        return start(next, spec: spec)
    }

    @discardableResult
    func continueSession(_ record: RunRecord, with message: String) -> Bool {
        guard !hasSurvivingClaude(record.routineID),
              let routine = routine(record.routineID), let session = record.sessionID,
              let logPath = record.logPath else { return false }
        var record = record
        record.outcome = .running
        record.endedAt = nil
        record.reportedModel = nil
        record.reportedEffort = nil
        record.questions = record.questions?.filter { $0.replyViaMessage == true }
        record.terminalState = nil
        return start(record, spec: spec(for: routine, record: record, harness: record.harness, prompt: message,
                                 log: URL(fileURLWithPath: logPath), resume: session))
    }

}
