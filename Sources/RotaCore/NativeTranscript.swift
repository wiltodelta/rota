import Foundation

/// Reads only bytes appended after a native CLI takes over an existing session.
/// The native stores remain read-only. Terminal escape sequences never enter the chat.
struct NativeTranscript {
    enum Event: Equatable {
        case item(TranscriptItem.Kind, String)
        case chunk(String)
        case configuration(SessionConfiguration)
        case state(TerminalState)
    }

    let url: URL
    let harness: Harness
    private var offset: UInt64
    private var partial = Data()

    init(url: URL, harness: Harness) throws {
        self.url = url
        self.harness = harness
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        offset = try file.seekToEnd()
    }

    mutating func read() throws -> [Event] {
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        guard try file.seekToEnd() >= offset else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try file.seek(toOffset: offset)
        var events: [Event] = []
        while let data = try file.read(upToCount: 65_536), !data.isEmpty {
            offset += UInt64(data.count)
            partial.append(data)
            while let newline = partial.firstIndex(of: 10) {
                let line = Data(partial[..<newline])
                partial.removeSubrange(...newline)
                if !line.isEmpty { events += try Self.events(line, harness: harness) }
            }
        }
        return events
    }

    static func locate(_ harness: Harness, session: String) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        if harness == .claude { return ClaudeInteractiveRun.transcriptFile(session) }
        guard harness == .codex || harness == .grok else { return nil }
        let root = home.appendingPathComponent(harness == .codex ? ".codex/sessions" : ".grok/sessions")
        guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
                                                        options: [.skipsHiddenFiles]) else { return nil }
        for case let url as URL in files {
            if harness == .codex, url.lastPathComponent.hasSuffix("-\(session).jsonl") { return url }
            if harness == .grok, url.lastPathComponent == "updates.jsonl",
               url.deletingLastPathComponent().lastPathComponent == session { return url }
        }
        return nil
    }

    /// Grok keys session/load by its archived directory, which can differ from
    /// the routine's spelling when a native CLI resolves a symlink.
    static func grokDirectory(_ source: URL) -> String? {
        let group = source.deletingLastPathComponent().deletingLastPathComponent()
        if let recorded = try? String(contentsOf: group.appendingPathComponent(".cwd"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), recorded.hasPrefix("/") { return recorded }
        let decoded = group.lastPathComponent.removingPercentEncoding
        return decoded?.hasPrefix("/") == true ? decoded : nil
    }

    static func events(_ data: Data, harness: Harness) throws -> [Event] {
        guard let entry = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        switch harness {
        case .claude: return claude(data, entry: entry)
        case .codex: return codex(entry)
        case .grok: return grok(entry)
        case .antigravity, .shell: return []
        }
    }

    private static func claude(_ data: Data, entry: [String: Any]) -> [Event] {
        switch ClaudeTranscript.read(data) {
        case .user(let text), .queued(let text): return [.item(.user, text), .state(.working)]
        case .assistant(let model, let items):
            var events: [Event] = [.configuration(.init(model: model))]
            events += items.map { .item($0.kind, $0.text) }
            let message = entry["message"] as? [String: Any]
            if message?["stop_reason"] as? String == "end_turn" { events.append(.state(.waiting)) }
            if let effort = entry["perTurnEffort"] as? String {
                events.append(.configuration(.init(effort: effort)))
            }
            return events
        case .apiError(let text): return [.item(.error, text), .state(.waiting)]
        case .turnEnded: return [.state(.waiting)]
        case .other: return []
        }
    }

    private static func codex(_ entry: [String: Any]) -> [Event] {
        guard let payload = entry["payload"] as? [String: Any] else { return [] }
        switch entry["type"] as? String {
        case "turn_context":
            return [.configuration(.init(model: payload["model"] as? String, effort: payload["effort"] as? String))]
        case "event_msg": return codexEvent(payload)
        case "response_item": return codexItem(payload)
        default: return []
        }
    }

    private static func codexEvent(_ payload: [String: Any]) -> [Event] {
        switch payload["type"] as? String {
        case "task_started": return [.state(.working)]
        case "task_complete", "turn_aborted": return [.state(.waiting)]
        case "item_completed":
            guard let item = payload["item"] as? [String: Any], item["type"] as? String == "UserMessage"
            else { return [] }
            return text(item).map { [.item(.user, $0)] } ?? []
        default: return []
        }
    }

    private static func codexItem(_ payload: [String: Any]) -> [Event] {
        switch payload["type"] as? String {
        case "message" where payload["role"] as? String == "assistant":
            return text(payload).map { [.item(.agent, $0)] } ?? []
        case "function_call", "custom_tool_call":
            guard let name = payload["name"] as? String else { return [] }
            return [.item(.tool, name)]
        default: return []
        }
    }

    private static func grok(_ entry: [String: Any]) -> [Event] {
        guard let method = entry["method"] as? String,
              ["session/update", "_x.ai/session/update"].contains(method),
              let params = entry["params"] as? [String: Any],
              let update = params["update"] as? [String: Any] else { return [] }
        switch update["sessionUpdate"] as? String {
        case "user_message_chunk", "agent_message_chunk":
            guard let content = update["content"] as? [String: Any], content["type"] as? String == "text",
                  let text = content["text"] as? String else { return [] }
            if update["sessionUpdate"] as? String == "user_message_chunk" {
                let metadata = update["_meta"] as? [String: Any]
                return [.configuration(.init(model: metadata?["modelId"] as? String)),
                        .item(.user, text), .state(.working)]
            }
            return [.chunk(text)]
        case "config_option_update":
            return [.configuration(.acp(update))]
        case "turn_completed": return [.state(.waiting)]
        case "tool_call": return [.item(.tool, update["title"] as? String ?? "Tool")]
        default: return []
        }
    }

    private static func text(_ message: [String: Any]) -> String? {
        let parts = (message["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String } ?? []
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }
}
