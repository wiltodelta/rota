import Foundation

/// A provider request that can only be answered while its owning connection is live.
public struct SessionRequest: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var detail: String
    public var choices: [Choice]
    public var questions: [Question]

    public struct Choice: Codable, Equatable, Identifiable, Sendable {
        public var id: String
        public var title: String
    }

    public struct Question: Codable, Equatable, Identifiable, Sendable {
        public var id: String
        public var title: String
        public var options: [String]
        public var multiple: Bool
        public var descriptions: [String: String]
        public var allowsText: Bool
        public var secret: Bool
    }
}

public struct SessionResponse: Equatable, Sendable {
    public var choice: String
    public var answers: [String: String]

    public init(choice: String, answers: [String: String] = [:]) {
        self.choice = choice
        self.answers = answers
    }
}

/// Runs entirely on a runner's serial queue. Answer closures retain the original wire payload.
final class SessionRequests {
    private struct Pending {
        var request: SessionRequest
        var answer: (SessionResponse) -> Void
        var cancel: () -> Void
    }
    private var pending: [Pending] = []
    private let changed: ([SessionRequest]) -> Void

    init(changed: @escaping ([SessionRequest]) -> Void) { self.changed = changed }

    var isEmpty: Bool { pending.isEmpty }

    func add(_ request: SessionRequest, answer: @escaping (SessionResponse) -> Void,
             cancel: @escaping () -> Void) {
        guard !pending.contains(where: { $0.request.id == request.id }) else { return }
        pending.append(Pending(request: request, answer: answer, cancel: cancel))
        changed(pending.map(\.request))
    }

    @discardableResult
    func answer(_ id: String, _ response: SessionResponse) -> Bool {
        guard let index = pending.firstIndex(where: { $0.request.id == id }),
              pending[index].request.choices.contains(where: { $0.id == response.choice }) else { return false }
        let request = pending[index].request
        if response.choice == "submit" {
            guard request.questions.allSatisfy({ question in
                guard let text = response.answers[question.id], !text.trimmingCharacters(in: .whitespaces).isEmpty
                else { return false }
                return question.allowsText || question.options.contains(text)
            }) else { return false }
        }
        let entry = pending.remove(at: index)
        changed(pending.map(\.request))
        entry.answer(response)
        return true
    }

    func cancel(_ id: String, notifyProvider: Bool = true) {
        guard let index = pending.firstIndex(where: { $0.request.id == id }) else { return }
        let entry = pending.remove(at: index)
        changed(pending.map(\.request))
        if notifyProvider { entry.cancel() }
    }

    func cancelAll(notifyProvider: Bool = true) {
        let entries = pending
        pending.removeAll()
        changed([])
        if notifyProvider { entries.forEach { $0.cancel() } }
    }
}

/// Only choices whose protocol meaning is known are offered. Durable policy changes are separate.
enum RequestPresentation {
    static func detail(_ params: [String: Any]) -> String {
        ["command", "cwd", "reason", "description", "rawInput", "input", "changes", "grantRoot", "permissions"]
            .compactMap { key in EventContent.text(params[key]).map { key + ": " + $0 } }
            .joined(separator: "\n\n")
    }

    static func permission(title: String, detail: String) -> SessionRequest {
        SessionRequest(id: UUID().uuidString, title: title, detail: detail,
                       choices: [.init(id: "allow", title: "Allow Once"), .init(id: "deny", title: "Deny")],
                       questions: [])
    }

    static func codex(_ method: String, _ params: [String: Any]) -> SessionRequest? {
        switch method {
        case "item/commandExecution/requestApproval":
            return permission(title: "Allow command?", detail: detail(params))
        case "item/fileChange/requestApproval":
            return permission(title: "Allow file changes?", detail: detail(params))
        case "item/permissions/requestApproval":
            return permission(title: "Grant permissions for this turn?", detail: detail(params))
        case "item/tool/requestUserInput":
            let items = params["questions"] as? [[String: Any]] ?? []
            let questions: [SessionRequest.Question] = items.compactMap { item in
                guard let id = item["id"] as? String, let title = item["question"] as? String else { return nil }
                let choices = item["options"] as? [[String: Any]] ?? []
                let options = choices.compactMap { $0["label"] as? String }
                var descriptions: [String: String] = [:]
                for choice in choices {
                    if let label = choice["label"] as? String, let description = choice["description"] as? String {
                        descriptions[label] = description
                    }
                }
                return .init(id: id, title: title, options: options, multiple: item["multiSelect"] as? Bool == true,
                             descriptions: descriptions,
                             allowsText: options.isEmpty || item["isOther"] as? Bool == true,
                             secret: item["isSecret"] as? Bool == true)
            }
            guard !questions.isEmpty else { return nil }
            return SessionRequest(id: UUID().uuidString, title: "Answer the agent", detail: "",
                                  choices: [.init(id: "submit", title: "Submit Answers"),
                                            .init(id: "cancel", title: "Cancel")], questions: questions)
        default: return nil
        }
    }

    static func claude(_ params: [String: Any]) -> SessionRequest? {
        guard params["tool_name"] as? String == "AskUserQuestion",
              let input = params["input"] as? [String: Any],
              let questions = input["questions"] as? [[String: Any]] else { return nil }
        let transformed = questions.enumerated().map { index, original in
            var question = original
            question["id"] = String(index)
            question["isOther"] = true
            return question
        }
        return codex("item/tool/requestUserInput", ["questions": transformed])
    }

    static func claudeResponse(_ params: [String: Any], _ response: SessionResponse) -> [String: Any] {
        guard response.choice == "allow" || response.choice == "submit" else {
            return ["behavior": "deny", "message": "The user declined this request."]
        }
        var input = params["input"] as? [String: Any] ?? [:]
        if params["tool_name"] as? String == "AskUserQuestion" {
            let questions = input["questions"] as? [[String: Any]] ?? []
            var answers: [String: String] = [:]
            for (index, question) in questions.enumerated() {
                if let title = question["question"] as? String { answers[title] = response.answers[String(index)] }
            }
            input["answers"] = answers
        }
        return ["behavior": "allow", "updatedInput": input]
    }

    static func codexResponse(_ method: String, _ params: [String: Any], _ response: SessionResponse) -> Any {
        switch method {
        case "item/tool/requestUserInput":
            let answers = response.choice == "submit" ? response.answers : [:]
            return ["answers": answers.mapValues { ["answers": [$0]] }]
        case "item/permissions/requestApproval":
            return ["permissions": response.choice == "allow" ? params["permissions"] ?? [:] : [:], "scope": "turn"]
        default:
            return ["decision": response.choice == "allow" ? "accept"
                    : response.choice == "cancel" ? "cancel" : "decline"]
        }
    }

    static func grok(_ params: [String: Any]) -> SessionRequest? {
        let choices = (params["options"] as? [[String: Any]] ?? []).compactMap { item -> SessionRequest.Choice? in
            guard let id = item["optionId"] as? String, let name = item["name"] as? String,
                  let kind = item["kind"] as? String, ["allow_once", "reject_once"].contains(kind) else { return nil }
            return .init(id: id, title: name)
        }
        guard !choices.isEmpty else { return nil }
        let tool = params["toolCall"] as? [String: Any] ?? [:]
        return SessionRequest(id: UUID().uuidString, title: tool["title"] as? String ?? "Tool permission",
                              detail: detail(tool), choices: choices, questions: [])
    }
}
