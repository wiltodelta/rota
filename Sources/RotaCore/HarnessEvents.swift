import Foundation

/// JSON payloads remain content in the event journal, never application diagnostic logs.
enum EventContent {
    static func text(_ value: Any?) -> String? {
        guard let value, !(value is NSNull) else { return nil }
        if let text = value as? String { return text }
        guard JSONSerialization.isValidJSONObject(value),
              let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return nil }
        return lossyUTF8(data)
    }

    static func plan(_ value: Any?, textKey: String) -> [PlanStep] {
        (value as? [[String: Any]] ?? []).map {
            PlanStep(status: $0["status"] as? String, text: $0[textKey] as? String ?? "")
        }
    }
}

/// Claude stream-json and interactive JSONL share completed assistant and tool-result shapes.
final class ClaudeEventMapper {
    private var messageID = UUID().uuidString
    private struct ToolInput {
        var id: String
        var title: String
        var json: String = ""
    }
    private var toolInputs: [Int: ToolInput] = [:]

    func events(_ event: [String: Any]) -> [SessionEvent.Payload] {
        switch event["type"] as? String {
        case "assistant": return assistant(event)
        case "user": return results(event)
        case "stream_event": return stream(event["event"] as? [String: Any] ?? [:])
        default: return []
        }
    }

    private func assistant(_ event: [String: Any]) -> [SessionEvent.Payload] {
        guard let message = event["message"] as? [String: Any] else { return [] }
        messageID = message["id"] as? String ?? event["uuid"] as? String ?? messageID
        var events: [SessionEvent.Payload] = []
        if let model = message["model"] as? String, model != "<synthetic>" {
            events.append(.metadata(SessionMetadata(model: model)))
        }
        for (index, block) in (message["content"] as? [[String: Any]] ?? []).enumerated() {
            switch block["type"] as? String {
            case "text":
                events.append(.assistant(id: messageID + ":\(index)", text: block["text"] as? String ?? "",
                                         phase: nil))
            case "thinking":
                events.append(.assistant(id: messageID + ":\(index)", text: block["thinking"] as? String ?? "",
                                         phase: .work))
            case "tool_use":
                let name = block["name"] as? String ?? "tool"
                let input = block["input"] as? [String: Any]
                if name == "TodoWrite" {
                    events.append(.plan(EventContent.plan(input?["todos"], textKey: "content")))
                }
                events.append(.tool(id: block["id"] as? String ?? messageID + ":\(index)", title: name,
                                    input: EventContent.text(input), output: nil, status: "running"))
            default: break
            }
        }
        return events
    }

    private func results(_ event: [String: Any]) -> [SessionEvent.Payload] {
        let blocks = (event["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
        return blocks.compactMap { block in
            guard block["type"] as? String == "tool_result", let id = block["tool_use_id"] as? String else {
                return nil
            }
            return .tool(id: id, title: "", input: nil, output: EventContent.text(block["content"]),
                         status: block["is_error"] as? Bool == true ? "failed" : "completed")
        }
    }

    private func stream(_ event: [String: Any]) -> [SessionEvent.Payload] {
        switch event["type"] as? String {
        case "message_start":
            let message = event["message"] as? [String: Any] ?? [:]
            messageID = message["id"] as? String ?? UUID().uuidString
            toolInputs = [:]
            if let model = message["model"] as? String { return [.metadata(SessionMetadata(model: model))] }
        case "content_block_start":
            let block = event["content_block"] as? [String: Any] ?? [:]
            let index = event["index"] as? Int ?? 0
            if block["type"] as? String == "tool_use", let id = block["id"] as? String {
                let title = block["name"] as? String ?? "tool"
                toolInputs[index] = ToolInput(id: id, title: title)
                return [.tool(id: id, title: title, input: nil, output: nil, status: "running")]
            }
        case "content_block_delta":
            let index = event["index"] as? Int ?? 0
            let delta = event["delta"] as? [String: Any] ?? [:]
            if delta["type"] as? String == "input_json_delta" {
                toolInputs[index]?.json += delta["partial_json"] as? String ?? ""
            } else if let text = delta["text"] as? String ?? delta["thinking"] as? String {
                return [.delta(id: messageID + ":\(index)", text: text,
                               phase: delta["type"] as? String == "thinking_delta" ? .work : nil)]
            }
        case "content_block_stop":
            if let input = toolInputs[event["index"] as? Int ?? 0] {
                return [.tool(id: input.id, title: input.title, input: input.json, output: nil, status: nil)]
            }
        default: break
        }
        return []
    }
}

/// Pure mapping is shared by the live runner and protocol fixtures.
enum CodexEventMapper {
    static func events(_ method: String, _ params: [String: Any]) -> [SessionEvent.Payload] {
        switch method {
        case "item/agentMessage/delta":
            guard let id = params["itemId"] as? String, let text = params["delta"] as? String else { return [] }
            return [.delta(id: id, text: text, phase: nil)]
        case "item/reasoning/textDelta", "item/reasoning/summaryTextDelta":
            guard let id = params["itemId"] as? String, let text = params["delta"] as? String else { return [] }
            return [.delta(id: id + ":thinking", text: text, phase: .work)]
        case "turn/plan/updated": return [.plan(EventContent.plan(params["plan"], textKey: "step"))]
        case "item/started", "item/completed":
            return item(params["item"] as? [String: Any] ?? [:], completed: method == "item/completed")
        default: return []
        }
    }

    private static func item(_ item: [String: Any], completed: Bool) -> [SessionEvent.Payload] {
        guard let id = item["id"] as? String, let type = item["type"] as? String else { return [] }
        if type == "agentMessage" {
            let phase: MessagePhase? = switch item["phase"] as? String {
            case "commentary": .work
            case "partial_answer", "final_answer": .answer
            default: nil
            }
            return [.assistant(id: id, text: item["text"] as? String ?? "", phase: phase)]
        }
        guard let description = CodexDaemonRun.describe(started: item) else { return [] }
        let input: Any? = item["arguments"] ?? item["changes"] ?? item["command"] ?? item["query"]
        let output = item["aggregatedOutput"] ?? item["result"] ?? item["error"]
        let exit = item["exitCode"] as? Int
        let failed = exit.map { $0 != 0 } == true || item["error"] is [String: Any]
        let status = failed ? "failed" : item["status"] as? String ?? (completed ? "completed" : "running")
        let result = [EventContent.text(output), exit.map { "Exit code: \($0)" }]
            .compactMap { $0 }.joined(separator: "\n")
        return [.tool(id: id, title: String(description.dropFirst(3)), input: EventContent.text(input),
                      output: result.isEmpty ? nil : result, status: status)]
    }
}

final class GrokEventMapper {
    private var segment = 0
    private var thought = 0
    private var textOpen = false
    private var thoughtOpen = false

    func events(_ update: [String: Any]) -> [SessionEvent.Payload] {
        switch update["sessionUpdate"] as? String {
        case "agent_message_chunk":
            if !textOpen { segment += 1; textOpen = true }
            thoughtOpen = false
            guard let text = (update["content"] as? [String: Any])?["text"] as? String else { return [] }
            return [.delta(id: "assistant-\(segment)", text: text, phase: nil)]
        case "agent_thought_chunk":
            if !thoughtOpen { thought += 1; thoughtOpen = true }
            textOpen = false
            guard let text = (update["content"] as? [String: Any])?["text"] as? String else { return [] }
            return [.delta(id: "thinking-\(thought)", text: text, phase: .work)]
        case "tool_call", "tool_call_update":
            textOpen = false
            thoughtOpen = false
            guard let id = update["toolCallId"] as? String else { return [] }
            return [.tool(id: id, title: update["title"] as? String ?? "", input: EventContent.text(update["rawInput"]),
                          output: EventContent.text(update["rawOutput"] ?? update["content"]),
                          status: update["status"] as? String)]
        case "plan": return [.plan(EventContent.plan(update["entries"], textKey: "content"))]
        default: return []
        }
    }
}
