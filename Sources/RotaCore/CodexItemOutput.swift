import Foundation

/// Completed native items may carry results outside the usual MCP text blocks.
enum CodexItemOutput {
    struct Entry {
        var kind: TranscriptItem.Kind = .output
        var text: String
        var suffix: String
    }

    static func entries(_ item: [String: Any]) -> [Entry] {
        var entries: [Entry] = []
        if let text = item["aggregatedOutput"] as? String, !text.isEmpty {
            entries.append(.init(text: text, suffix: "/output"))
        }
        let result = item["result"] as? [String: Any]
        let content = result?["content"] as? [[String: Any]] ?? item["contentItems"] as? [[String: Any]] ?? []
        for (index, block) in content.enumerated() {
            if let text = ToolOutput.content([block]) {
                entries.append(.init(text: text, suffix: "/content/\(index)"))
            }
        }
        return entries + specialized(item)
    }

    private static func specialized(_ item: [String: Any]) -> [Entry] {
        switch item["type"] as? String {
        case "functionCallOutput":
            return ToolOutput.content(item["output"]).map { [.init(text: $0, suffix: "/output")] } ?? []
        case "fileChange": return fileChanges(item)
        case "imageView":
            return (item["path"] as? String).map {
                [.init(text: localImage($0, label: "Viewed image"), suffix: "/image")]
            } ?? []
        case "imageGeneration": return generatedImage(item)
        case "subAgentActivity":
            return activity(item).map { [.init(kind: .status, text: $0, suffix: "/activity")] } ?? []
        case "collabAgentToolCall": return collaborators(item)
        default: return []
        }
    }

    private static func fileChanges(_ item: [String: Any]) -> [Entry] {
        let parts = (item["changes"] as? [[String: Any]] ?? []).compactMap { change -> ToolOutput.Part? in
            guard let path = change["path"] as? String, let diff = change["diff"] as? String else { return nil }
            return .init(kind: .diff, text: diff, path: path)
        }
        return parts.isEmpty ? [] : [.init(text: ToolOutput(parts: parts).encoded, suffix: "/diff")]
    }

    private static func generatedImage(_ item: [String: Any]) -> [Entry] {
        var entries: [Entry] = []
        if let path = item["savedPath"] as? String, !path.isEmpty {
            entries.append(.init(text: localImage(path, label: "Generated image"), suffix: "/image"))
        } else if let data = item["result"] as? String, !data.isEmpty {
            let url = data.hasPrefix("data:") ? data : "data:image/png;base64," + data
            entries.append(.init(text: ToolOutput.image(url, label: "Generated image"), suffix: "/image"))
        }
        if let failure = item["failure"] as? [String: Any] {
            entries.append(.init(kind: .error, text: failure["message"] as? String
                ?? QuestionRequest.json(failure), suffix: "/error"))
        }
        return entries
    }

    private static func collaborators(_ item: [String: Any]) -> [Entry] {
        let states = item["agentsStates"] as? [String: [String: Any]] ?? [:]
        return states.keys.sorted().compactMap { id in
            guard let status = states[id]?["status"] as? String else { return nil }
            return .init(kind: .status, text: "Agent \(id): \(state(status))", suffix: "/agent/" + id)
        }
    }

    static func activity(_ item: [String: Any]) -> String? {
        guard let kind = item["kind"] as? String else { return nil }
        let label = item["agentPath"] as? String ?? item["agentThreadId"] as? String ?? "Subagent"
        let status: String
        switch kind {
        case "started": status = "working"
        case "interacted": return nil
        case "completed": status = "completed"
        case "interrupted": status = "interrupted"
        default: return nil
        }
        return "Agent \(label): \(status)"
    }

    private static func state(_ value: String) -> String {
        switch value {
        case "pendingInit", "running": return "working"
        case "errored": return "failed"
        default: return value
        }
    }

    private static func localImage(_ path: String, label: String) -> String {
        ToolOutput.image(URL(fileURLWithPath: path).absoluteString, label: label)
    }
}
