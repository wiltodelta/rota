import Foundation

/// The exact reply envelope Rota sends for an asynchronous question.
/// Ordinary JSON messages and malformed envelopes remain ordinary user text.
public struct QuestionReceipt: Decodable, Equatable, Sendable {
    public struct Field: Decodable, Equatable, Sendable {
        public let question: String
        public let answers: [String]
    }

    public let action: String
    public let questions: [Field]

    static func message(_ question: AgentQuestion, answer: QuestionAnswer) -> String {
        let fields = question.fields.map { field in
            ["question": field.title, "answers": answer.values[field.id] ?? []] as [String: Any]
        }
        return "Answer to your question " + question.id + ":\n" + QuestionRequest.json([
            "action": answer.action, "questions": fields,
        ])
    }

    public static func decode(_ text: String) -> QuestionReceipt? {
        guard text.hasPrefix("Answer to your question "), let boundary = text.range(of: ":\n"),
              boundary.lowerBound > text.index(text.startIndex, offsetBy: "Answer to your question ".count),
              let receipt = try? JSONDecoder().decode(Self.self, from: Data(text[boundary.upperBound...].utf8))
        else { return nil }
        return receipt
    }

    /// The question a receipt closes: only a well-formed envelope with a final action counts.
    static func answer(_ text: String) -> (id: String, receipt: QuestionReceipt)? {
        guard let receipt = decode(text), ["accept", "decline", "cancel"].contains(receipt.action),
              let boundary = text.range(of: ":\n") else { return nil }
        let start = text.index(text.startIndex, offsetBy: "Answer to your question ".count)
        return (String(text[start..<boundary.lowerBound]), receipt)
    }

    public var summary: String {
        let answers = questions.flatMap(\.answers).filter { !$0.isEmpty }
        if !answers.isEmpty { return answers.joined(separator: "\n") }
        switch action {
        case "accept": return "Approved"
        case "decline": return "Declined"
        case "cancel": return "Cancelled"
        default: return action
        }
    }
}
