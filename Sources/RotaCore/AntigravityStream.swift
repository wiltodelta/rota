import Foundation

/// The agy headless wire format, separate from Claude's `type`-based stream.
/// Result.response repeats streamed text, so it is used only when no text arrived.
struct AntigravityStream {
    enum Event: Equatable {
        case session(String)
        case configuration(SessionConfiguration)
        case text(String)
        case item(TranscriptItem.Kind, String)
        case result(RunOutcome)
    }

    private var hadText = false
    private var tools = Set<Int>()

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
        if step["step_type"] as? String == "agent_response", let delta = step["text_delta"] as? String {
            hadText = hadText || !delta.isEmpty
            return [.text(delta)]
        }
        guard step["step_type"] as? String == "tool", let index = step["step_index"] as? Int else { return [] }
        let info = step["tool_info"] as? [String: Any] ?? [:]
        var events: [Event] = []
        if tools.insert(index).inserted {
            let name = step["tool_name"] as? String ?? info["name"] as? String ?? "tool"
            let parameters = info["parameters"].map(QuestionRequest.json) ?? ""
            events.append(.item(.tool, name + (parameters.isEmpty ? "" : " " + parameters)))
        }
        if step["state"] as? String == "DONE" {
            if let output = info["output"] as? String, !output.isEmpty { events.append(.item(.output, output)) }
            if let error = info["error"] as? [String: Any], let message = error["message"] as? String {
                events.append(.item(.error, message))
            }
        }
        return events
    }

    private mutating func result(_ result: [String: Any]) -> [Event] {
        var events: [Event] = []
        if let id = result["conversation_id"] as? String, !id.isEmpty { events.append(.session(id)) }
        if !hadText, let response = result["response"] as? String, !response.isEmpty { events.append(.text(response)) }
        hadText = false
        let status = result["status"] as? String
        let outcome: RunOutcome
        switch status {
        case "SUCCESS": outcome = .succeeded
        case "CANCELED": outcome = .cancelled
        case "INTERRUPTED": outcome = .interrupted
        default:
            outcome = .failed(exitCode: 1)
            let error = result["error"] as? String ?? "Antigravity ended with status \(status ?? "missing")."
            events.append(.item(.error, error))
        }
        events.append(.result(outcome))
        return events
    }
}
