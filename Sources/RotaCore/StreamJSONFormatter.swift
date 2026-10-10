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

    private static func assistantText(_ event: [String: Any]) -> String? {
        guard let message = event["message"] as? [String: Any],
              let content = message["content"] as? [[String: Any]] else { return nil }
        let parts: [String] = content.compactMap { item in
            switch item["type"] as? String {
            case "text":
                return item["text"] as? String
            case "tool_use":
                return "-> \(item["name"] as? String ?? "tool")\(toolDetail(item["input"]))"
            default:
                return nil
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
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
