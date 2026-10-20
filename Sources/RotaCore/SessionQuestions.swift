import Foundation

extension Scheduler {
    func events(for record: RunRecord) -> RunEvents {
        let id = record.routineID
        let runID = record.id
        return RunEvents(
            session: { [weak self] session in self?.attachSession(session, to: id) },
            finished: { [weak self] outcome in self?.finish(id, outcome: outcome) },
            configuration: { [weak self] configuration in
                self?.updateConfiguration(configuration, routineID: id, runID: runID)
            },
            question: { [weak self] question, reply in
                self?.receiveQuestion(question, runID: runID, reply: reply)
            },
            questionResolved: { [weak self] questionID in
                self?.resolveQuestion(questionID, runID: runID)
            },
            terminalState: { [weak self] state in
                guard let self, var current = self.active[id], current.id == runID,
                      current.terminalState != state else { return }
                if state == .working { self.runStarts[id] = self.now() }
                current.terminalState = state
                self.active[id] = current
                self.saveRecord(current)
            }, terminalInput: { [weak self] in
                guard let self, let current = self.active[id], current.id == runID else { return }
                self.dismissAttention(current)
            })
    }

    func receiveQuestion(
        _ question: AgentQuestion, runID: UUID,
        reply: @escaping @Sendable (QuestionAnswer) -> Void
    ) {
        guard var record = current(runID), isActive(record) else { return reply(.init(action: "cancel")) }
        guard record.questions?.contains(where: { $0.id == question.id }) != true else { return }
        if question.replyViaMessage != true { questionReplies[runID, default: [:]][question.id] = reply }
        record.questions = (record.questions ?? []) + [question]
        let marked = setAttention(question.title, on: record)
        notifier?.sessionNotified(
            marked, routine: routine(record.routineID), title: nil,
            text: question.fields.first?.title ?? question.title, needsReply: true)
    }

    public func answerQuestion(_ id: String, on record: RunRecord, answer: QuestionAnswer) throws {
        guard let current = current(record.id), let question = current.questions?.first(where: { $0.id == id }) else {
            throw ControlError("This question is no longer waiting for an answer.")
        }
        try question.validate(answer)
        if question.replyViaMessage == true {
            return try answerMessageQuestion(question, on: current, answer: answer)
        }
        guard isActive(current), let reply = questionReplies[record.id]?[id] else {
            throw ControlError("This question is no longer waiting for an answer.")
        }
        resolveQuestion(id, runID: record.id)
        reply(answer)
    }

    private func answerMessageQuestion(_ question: AgentQuestion, on record: RunRecord,
                                       answer: QuestionAnswer) throws {
        guard canMessage(record), questionReplies[record.id]?.isEmpty != false else {
            throw ControlError("Answer the blocking question or wait for this session to become available first.")
        }
        let fields = question.fields.map { field in
            ["question": field.title, "answers": answer.values[field.id] ?? []] as [String: Any]
        }
        let text = "Answer to your question " + question.id + ":\n" + QuestionRequest.json([
            "action": answer.action, "questions": fields,
        ])
        var next = record
        next.questions?.removeAll { $0.id == question.id }
        next.attention = next.nextQuestion?.title
        if !deliverMessage(text, to: next) {
            // A failed launch must leave the question available for retry.
            var failed = current(record.id) ?? record
            failed.questions = record.questions
            failed.attention = record.attention
            saveRecord(failed)
            throw ControlError("Could not continue the session. Your question is still pending.")
        }
    }

    func resolveQuestion(_ id: String, runID: UUID) {
        questionReplies[runID]?[id] = nil
        guard var record = current(runID), record.questions?.contains(where: { $0.id == id }) == true else { return }
        record.questions?.removeAll { $0.id == id }
        record.attention = record.nextQuestion?.title
        if isActive(record) { active[record.routineID] = record }
        saveRecord(record)
    }

    func cancelQuestions(on record: RunRecord) {
        let replies = questionReplies.removeValue(forKey: record.id) ?? [:]
        if !replies.isEmpty, var current = current(record.id) {
            current.questions = current.questions?.filter { $0.replyViaMessage == true }
            if current.questions?.isEmpty == true { current.questions = nil }
            current.attention = current.nextQuestion?.title
            if isActive(current) { active[current.routineID] = current }
            saveRecord(current)
        }
        for reply in replies.values { reply(.init(action: "cancel")) }
        hookAnswers = hookAnswers.filter { !$0.key.hasPrefix(record.id.uuidString + "/") }
    }

    /// Hook helpers poll this socket while Claude's PreToolUse or Elicitation hook blocks.
    func questionCommand(_ method: String, _ params: [String: Any]) throws -> Any? {
        guard method.hasPrefix("questions.") else { return nil }
        guard let session = params["session"] as? String, let record = current(session), isActive(record) else {
            throw ControlError("The session is no longer running.")
        }
        switch method {
        case "questions.create":
            let data = try JSONSerialization.data(withJSONObject: params["question"] ?? [:])
            let question = try JSONDecoder().decode(AgentQuestion.self, from: data)
            let key = record.id.uuidString + "/" + question.id
            receiveQuestion(question, runID: record.id) { [weak self] answer in
                MainActor.assumeIsolated { self?.hookAnswers[key] = answer }
            }
            return ["question": question.id]
        case "questions.poll":
            guard let id = params["question"] as? String else { throw ControlError("Missing question id.") }
            let key = record.id.uuidString + "/" + id
            if let answer = hookAnswers.removeValue(forKey: key) {
                return try JSONSerialization.jsonObject(with: JSONEncoder().encode(answer))
            }
            guard questionReplies[record.id]?[id] != nil else { throw ControlError("The question has expired.") }
            return ["pending": true]
        default: throw ControlError("Unknown question method.")
        }
    }
}
