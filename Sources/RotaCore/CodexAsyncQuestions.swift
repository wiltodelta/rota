import Foundation

/// The lifecycle of a Codex thread's async questions within one run. A resumed
/// thread replays its whole history, so a question is asked only once it is
/// known to be open: no Rota receipt for it in the history, in the prompt that
/// continues the thread or in a message sent during the run.
struct CodexAsyncQuestions {
    private var known: [String: AgentQuestion] = [:]
    private var answers: [String: [QuestionReceipt]] = [:]
    private var pending: [String: Int] = [:]
    private var asked: Set<String> = []
    /// Question ids met while the history loads, in order; nil once it has.
    private var held: [String]?

    /// Holds questions back until the history and the events deferred behind it are all seen.
    mutating func hold() {
        held = []
    }

    /// Notes the receipt in a message Rota sends or the history holds; other text is ignored.
    @discardableResult
    mutating func noteAnswer(_ text: String) -> String? {
        guard let (id, receipt) = QuestionReceipt.answer(text) else { return nil }
        if answers[id]?.contains(receipt) != true { answers[id, default: []].append(receipt) }
        return known[id].flatMap { matches(receipt, $0) ? id : nil }
    }

    /// Suppress replay while delivery is in flight, without committing an answer yet.
    mutating func sending(_ text: String) {
        guard QuestionReceipt.answer(text) != nil else { return }
        pending[text, default: 0] += 1
    }

    @discardableResult
    mutating func delivered(_ text: String) -> String? {
        removePending(text)
        return noteAnswer(text)
    }

    mutating func noteAnswers(in item: [String: Any]) -> [String] {
        guard item["type"] as? String == "userMessage" else { return [] }
        return (item["content"] as? [[String: Any]] ?? []).compactMap { block in
            guard block["type"] as? String == "text", let text = block["text"] as? String else { return nil }
            return noteAnswer(text)
        }
    }

    var closed: [String] {
        known.values.filter { question in
            answers[question.id]?.contains(where: { matches($0, question) }) == true
        }.map(\.id)
    }

    /// The question to ask now, if it is open and was not asked yet.
    mutating func offer(_ question: AgentQuestion) -> AgentQuestion? {
        known[question.id] = question
        guard var ids = held else { return take(question.id) }
        if !ids.contains(question.id) { ids.append(question.id) }
        held = ids
        return nil
    }

    /// The open questions of the loaded history, after every page and its answers were seen.
    mutating func restored() -> [AgentQuestion] {
        let ids = held ?? []
        held = nil
        return ids.compactMap { take($0) }
    }

    /// An answer that did not reach Codex reopens its question.
    mutating func undelivered(_ text: String) -> AgentQuestion? {
        guard let (id, _) = QuestionReceipt.answer(text) else { return nil }
        removePending(text)
        asked.remove(id)
        return held == nil ? take(id) : nil
    }

    private mutating func removePending(_ text: String) {
        if let count = pending[text], count > 1 { pending[text] = count - 1 } else { pending[text] = nil }
    }

    private func matches(_ receipt: QuestionReceipt, _ question: AgentQuestion) -> Bool {
        guard receipt.questions.map(\.question) == question.fields.map(\.title) else { return false }
        let values = Dictionary(uniqueKeysWithValues: zip(question.fields, receipt.questions).map {
            ($0.0.id, $0.1.answers)
        })
        return (try? question.validate(.init(action: receipt.action, values: values))) != nil
    }

    private func answered(_ question: AgentQuestion) -> Bool {
        if answers[question.id]?.contains(where: { matches($0, question) }) == true { return true }
        return pending.keys.contains { text in
            guard let (id, receipt) = QuestionReceipt.answer(text), id == question.id else { return false }
            return matches(receipt, question)
        }
    }

    private mutating func take(_ id: String) -> AgentQuestion? {
        guard let question = known[id], !asked.contains(id) else { return nil }
        // A receipt answers the question it was written for, field by field.
        if answered(question) { return nil }
        asked.insert(id)
        return question
    }
}
