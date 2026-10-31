import Foundation

/// Activity summaries never import a child's messages into the parent's answers.
enum SubagentStatus {
    static func grok(_ update: [String: Any]) -> String? {
        guard let id = update["subagent_id"] as? String else { return nil }
        switch update["sessionUpdate"] as? String {
        case "subagent_spawned": return "Agent \(id): working"
        case "subagent_finished":
            let status = update["status"] as? String ?? "finished"
            return "Agent \(id): " + (status == "error" ? "failed" : status)
        default: return nil
        }
    }
}
