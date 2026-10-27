import Foundation

extension QuestionRequest {
    /// Headless agy skips its native questionnaire. Rota collects an explicit
    /// answer as a subsequent user turn, rather than inventing a tool response.
    static func antigravity(_ tool: String, arguments: [String: Any], id: String) -> AgentQuestion? {
        guard ["ask_question", "ask_permission", "ask_custom_permission"].contains(tool) else { return nil }
        var question: AgentQuestion
        if tool == "ask_question", let fields = antigravityFields(arguments["questions"]), !fields.isEmpty {
            question = AgentQuestion(id: id, title: "Antigravity needs your reply", fields: fields)
        } else {
            let permission = tool != "ask_question"
            question = AgentQuestion(
                id: id, title: permission ? "Permission request needs Antigravity" : "This question needs Antigravity",
                detail: permission
                    ? "Antigravity handles permissions through its headless execution policy. "
                        + "Rota cannot grant or revoke them here. Cancel or decline to send that instruction "
                        + "to the conversation; use Antigravity itself to manage permissions."
                    : "Antigravity supplied a question format Rota cannot display. "
                        + "Cancel or decline to send that instruction to the conversation.",
                actions: [], allowsDecline: true)
        }
        question.replyViaMessage = true
        return question
    }

    private static func antigravityFields(_ value: Any?) -> [QuestionField]? {
        let decoded: Any?
        if let text = value as? String {
            decoded = try? JSONSerialization.jsonObject(with: Data(text.utf8))
        } else {
            decoded = value
        }
        guard let rows = decoded as? [[String: Any]] else { return nil }
        var fields: [QuestionField] = []
        for (index, row) in rows.enumerated() {
            guard let title = row["question"] as? String, !title.isEmpty,
                  let options = row["options"] as? [String],
                  options.allSatisfy({ !$0.isEmpty }), Set(options).count == options.count,
                  row["is_multi_select"] == nil || row["is_multi_select"] is Bool else { return nil }
            fields.append(QuestionField(
                id: String(index), title: title,
                kind: options.isEmpty ? .text : row["is_multi_select"] as? Bool == true ? .multiple : .choice,
                options: options.map { .init(id: $0, label: $0) }))
        }
        return fields
    }
}

/// Reads only native tool-call metadata. Stream-json omits ask_question arguments;
/// prose and model reasoning never enter the question adapter.
struct AntigravityQuestionArchive {
    let session: String
    let file: URL
    private var offset: UInt64 = 0
    private var pending = Data()
    private var seen = Set<String>()
    private var reasoningSteps = Set<Int>()
    private var reasoning: [(String, String)] = []

    mutating func takeReasoning() -> [(String, String)] {
        defer { reasoning.removeAll() }
        return reasoning
    }

    init?(session: String, home: URL = FileManager.default.homeDirectoryForCurrentUser,
          skipExisting: Bool = false) {
        guard UUID(uuidString: session) != nil else { return nil }
        self.session = session
        file = home.appendingPathComponent(".gemini/antigravity-cli/brain")
            .appendingPathComponent(session).appendingPathComponent(".system_generated/logs/transcript.jsonl")
        if skipExisting {
            offset = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? UInt64) ?? 0
        }
    }

    mutating func read(final: Bool = false) throws -> [AgentQuestion] {
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let end = try handle.seekToEnd()
        guard end >= offset else { throw CocoaError(.fileReadCorruptFile) }
        try handle.seek(toOffset: offset)
        var questions: [AgentQuestion] = []
        while offset < end {
            let bytes = try handle.read(upToCount: Int(min(65_536, end - offset))) ?? Data()
            guard !bytes.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
            offset += UInt64(bytes.count)
            pending.append(bytes)
            while let newline = pending.firstIndex(of: 10) {
                let line = Data(pending[..<newline])
                pending.removeSubrange(...newline)
                questions += try parse(line)
            }
        }
        if final, !pending.isEmpty { throw CocoaError(.fileReadCorruptFile) }
        return questions
    }

    private mutating func parse(_ line: Data) throws -> [AgentQuestion] {
        guard !line.isEmpty else { return [] }
        let object = try JSONSerialization.jsonObject(with: line)
        guard let row = object as? [String: Any], row["type"] as? String == "PLANNER_RESPONSE",
              row["status"] as? String == "DONE", let step = row["step_index"] as? Int else { return [] }
        if let text = row["thinking"] as? String, !text.isEmpty, reasoningSteps.insert(step).inserted {
            reasoning.append(("antigravity/\(session)/\(step)/thinking", text))
        }
        let calls = row["tool_calls"] as? [[String: Any]] ?? []
        return calls.enumerated().compactMap { index, call in
            let id = "antigravity/\(session)/\(step)/\(index)"
            guard let tool = call["name"] as? String,
                  let question = QuestionRequest.antigravity(tool, arguments: call["args"] as? [String: Any] ?? [:],
                                                            id: id), seen.insert(id).inserted else { return nil }
            return question
        }
    }
}
