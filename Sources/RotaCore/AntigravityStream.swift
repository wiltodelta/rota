import Foundation

/// The agy headless wire format, separate from Claude's `type`-based stream.
/// Result.response repeats streamed text, so it is used only when no text arrived.
struct AntigravityStream {
    enum Event: Equatable {
        case session(String)
        case configuration(SessionConfiguration)
        case text(String)
        case textStarted(Int?)
        case textEnded(Int?)
        case item(TranscriptItem.Kind, String, step: Int? = nil)
        case result(RunOutcome)
        case unknownStep
    }

    private var hadText = false
    private var tools = Set<Int>()
    private var subagents = Set<String>()
    private var textStep: Int?
    private var writingText = false

    mutating func events(_ data: Data) -> [Event] {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let event = object["event"] as? String else {
            let text = lossyUTF8(data).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? [] : [.item(.error, text)]
        }
        switch event {
        case "init":
            var events: [Event] = []
            if let id = object["conversation_id"] as? String, !id.isEmpty { events.append(.session(id)) }
            let config = object["init"] as? [String: Any] ?? [:]
            events.append(.configuration(.init(model: config["model"] as? String, effort: config["effort"] as? String)))
            return events
        case "step_update":
            return step(object["step_update"] as? [String: Any] ?? [:])
        case "result":
            return result(object["result"] as? [String: Any] ?? [:])
        default: return []
        }
    }

    private mutating func step(_ step: [String: Any]) -> [Event] {
        if step["step_type"] as? String == "unknown" { return [.unknownStep] }
        if step["step_type"] as? String == "agent_response" {
            return response(step)
        }
        if step["step_type"] as? String == "subagent" {
            return subagent(step)
        }
        guard step["step_type"] as? String == "tool", let index = step["step_index"] as? Int else { return [] }
        let info = step["tool_info"] as? [String: Any] ?? [:]
        var events: [Event] = []
        if tools.insert(index).inserted {
            let name = step["tool_name"] as? String ?? info["name"] as? String ?? "tool"
            let parameters = info["parameters"].map(QuestionRequest.json) ?? ""
            events.append(.item(.tool, name + (parameters.isEmpty ? "" : " " + parameters), step: index))
        }
        if ["DONE", "ERROR"].contains(step["state"] as? String ?? "") {
            if let output = info["output"] as? String, !output.isEmpty {
                events.append(.item(.output, output, step: index))
            }
            if let error = info["error"] as? [String: Any], let message = error["message"] as? String {
                events.append(.item(.error, message, step: index))
            }
        }
        return events
    }

    private mutating func response(_ step: [String: Any]) -> [Event] {
        let index = step["step_index"] as? Int
        var events: [Event] = []
        if !writingText || textStep != index {
            events.append(.textStarted(index))
            textStep = index
            writingText = true
        }
        if let delta = step["text_delta"] as? String, !delta.isEmpty {
            hadText = true
            events.append(.text(delta))
        }
        if step["state"] as? String == "DONE" {
            writingText = false
            events.append(.textEnded(index))
        }
        return events
    }

    private mutating func subagent(_ step: [String: Any]) -> [Event] {
        let info = step["subagent_info"] as? [String: Any] ?? [:]
        let agents = info["subagents"] as? [[String: Any]] ?? []
        // DONE completes invoke_subagent, not the child conversation.
        let status = step["state"] as? String == "ERROR" ? "failed to start" : "started"
        return agents.compactMap { agent in
            guard let id = agent["conversation_id"] as? String,
                  subagents.insert(id + "/" + status).inserted else { return nil }
            return .item(.status, "Agent \(agent["role"] as? String ?? id): \(status)",
                         step: step["step_index"] as? Int)
        }
    }

    private mutating func result(_ result: [String: Any]) -> [Event] {
        var events: [Event] = []
        if let id = result["conversation_id"] as? String, !id.isEmpty { events.append(.session(id)) }
        if !hadText, let response = result["response"] as? String, !response.isEmpty { events.append(.text(response)) }
        hadText = false
        writingText = false
        let (outcome, error) = Self.outcome(result)
        if let error { events.append(.item(.error, error)) }
        events.append(.result(outcome))
        return events
    }

    /// finished_reason, present only when a turn ended early, outranks status:
    /// agy reports a print timeout as SUCCESS and an interruption as ERROR.
    private static func outcome(_ result: [String: Any]) -> (RunOutcome, error: String?) {
        let status = result["status"] as? String
        let error = result["error"] as? String
        switch (result["finished_reason"] as? String ?? "", status) {
        case ("", "SUCCESS"): return (.succeeded, nil)
        case ("", "CANCELED"): return (.cancelled, nil)
        case ("", "INTERRUPTED"): return (.interrupted, nil)
        case ("", _): return (.failed(exitCode: 1), error ?? "Antigravity ended with status \(status ?? "missing").")
        case ("print_timeout", _): return (.timedOut, "Antigravity's print time limit expired. The answer is partial.")
        case ("interrupted", _): return (.interrupted, "Antigravity interrupted the turn. The answer is partial.")
        case ("error", _): return (.failed(exitCode: 1), error ?? "Antigravity ended the turn with an error.")
        case (let reason, _):
            return (.failed(exitCode: 1), "Antigravity ended the turn early (\(reason)). The answer may be incomplete.")
        }
    }
}
