import Foundation

/// Turns `claude -p --output-format stream-json` events into a readable log,
/// so a run can be watched while it happens instead of only at its end.
public enum StreamJSONFormatter {
    public static func format(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        guard let data = trimmed.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = event["type"] as? String else { return trimmed }
        switch type {
        case "system":
            guard event["subtype"] as? String == "init" else { return nil }
            let model = event["model"] as? String ?? "unknown model"
            return "[session started, \(model)]"
        case "assistant":
            return assistantText(event)
        case "result":
            return resultText(event)
        default:
            return nil
        }
    }

    /// Only known assistant blocks cross the adapter boundary. Unknown neighbors
    /// never suppress supported text, and tool argument schemas remain optional.
    static func items(_ data: Data) -> [TranscriptItem] {
        guard let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              event["type"] as? String == "assistant" else { return [] }
        return assistantItems(event)
    }

    private static func assistantText(_ event: [String: Any]) -> String? {
        let parts = assistantItems(event).map { RunJournal.readable($0.kind, $0.text) }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    static func assistantItems(_ event: [String: Any]) -> [TranscriptItem] {
        guard let message = event["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else { return [] }
        return content.enumerated().compactMap { index, item in
            switch item["type"] as? String {
            case "text":
                return (item["text"] as? String).map { TranscriptItem(id: index, kind: .agent, text: $0) }
            case "tool_use":
                if item["name"] as? String == "TodoWrite",
                   let todos = (item["input"] as? [String: Any])?["todos"] as? [[String: Any]] {
                    let steps = todos.map {
                        PlanStep(status: $0["status"] as? String, text: $0["content"] as? String ?? "")
                    }
                    return TranscriptItem(id: index, kind: .plan, text: PlanStep.body(steps))
                }
                return TranscriptItem(id: index, kind: .tool,
                                      text: (item["name"] as? String ?? "tool") + toolDetail(item["input"]))
            default:
                return nil
            }
        }
    }

    private static func toolDetail(_ input: Any?) -> String {
        guard let input = input as? [String: Any] else { return "" }
        for key in ["command", "file_path", "url", "pattern", "skill", "description"] {
            if let value = input[key] as? String {
                let flat = value.replacingOccurrences(of: "\n", with: " ")
                return " " + (flat.count > 160 ? String(flat.prefix(160)) + "..." : flat)
            }
        }
        return ""
    }

    private static func resultText(_ event: [String: Any]) -> String {
        let subtype = event["subtype"] as? String ?? "done"
        var line = "[result: \(subtype)"
        if let millis = event["duration_ms"] as? Double {
            line += String(format: ", %.0f s", millis / 1000)
        }
        if let turns = event["num_turns"] as? Int { line += ", \(turns) turns" }
        line += "]"
        if let result = event["result"] as? String, !result.isEmpty { line += "\n" + result }
        return line
    }
}
