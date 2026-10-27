import Foundation

/// Native archive revisions are vendor-specific; framing stays shared with the other transcript readers.
struct AntigravityTranscript {
    private var completed = Set<Int>()

    mutating func read(_ row: [String: Any]) -> [NativeTranscript.Event] {
        guard row["status"] as? String == "DONE" else { return [] }
        if let step = row["step_index"] as? Int, !completed.insert(step).inserted { return [] }
        return Self.events(row)
    }

    static func events(_ entry: [String: Any]) -> [NativeTranscript.Event] {
        guard entry["status"] as? String == "DONE" else { return [] }
        let content = entry["content"] as? String
        switch entry["type"] as? String {
        case "USER_INPUT": return content.map { [.item(.user, userText($0)), .state(.working)] } ?? []
        case "PLANNER_RESPONSE":
            var events: [NativeTranscript.Event] = []
            if let thinking = entry["thinking"] as? String, !thinking.isEmpty {
                events.append(.item(.reasoning, thinking))
            }
            let calls = entry["tool_calls"] as? [[String: Any]] ?? []
            for call in calls {
                if let name = call["name"] as? String { events.append(.item(.tool, name)) }
            }
            if let content, !content.isEmpty { events.append(.item(.agent, content)) }
            if calls.isEmpty { events.append(.state(.waiting)) }
            return events
        case "GENERIC": return content.map { [.item(.output, $0)] } ?? []
        default: return []
        }
    }

    private static func userText(_ content: String) -> String {
        let prefix = "<USER_REQUEST>\n"
        guard content.hasPrefix(prefix), let end = content.range(of: "\n</USER_REQUEST>", options: .backwards)
        else { return content }
        return String(content[content.index(content.startIndex, offsetBy: prefix.count)..<end.lowerBound])
    }
}
