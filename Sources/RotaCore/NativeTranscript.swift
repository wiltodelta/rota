import Foundation

/// Reads only bytes appended after a native CLI takes over an existing session.
/// The native stores remain read-only. Terminal escape sequences never enter the chat.
struct NativeTranscript {
    enum Event: Equatable {
        case item(TranscriptItem.Kind, String)
        case chunk(String, kind: TranscriptItem.Kind = .agent, nativeID: String? = nil)
        case configuration(SessionConfiguration)
        case state(TerminalState)
    }

    private(set) var url: URL
    let since: Date?
    private let home: URL
    private var awaitingExpansion: Bool
    let harness: Harness
    private var offset: UInt64
    private var partial = Data()
    private var antigravityDecoder = AntigravityTranscript()
    private var primed = false

    init(url: URL, harness: Harness, offset: UInt64? = nil, since: Date? = nil,
         home: URL = FileManager.default.homeDirectoryForCurrentUser) throws {
        self.url = url
        self.harness = harness
        self.home = home
        awaitingExpansion = harness == .codex && url.pathExtension == "zst"
        self.since = since ?? (awaitingExpansion ? Date() : nil)
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        self.offset = try offset ?? (awaitingExpansion ? 0 : file.seekToEnd())
    }

    /// Revisions after a checkpoint may repeat a step already finalized before the host stopped.
    private mutating func rememberAntigravity(_ file: FileHandle, through end: UInt64) throws {
        try file.seek(toOffset: 0)
        var remaining = end
        var pending = Data()
        while remaining > 0, let bytes = try file.read(upToCount: Int(min(remaining, 65_536))), !bytes.isEmpty {
            remaining -= UInt64(bytes.count)
            pending.append(bytes)
            while let newline = pending.firstIndex(of: 10) {
                let row = Data(pending[..<newline])
                pending.removeSubrange(...newline)
                if !row.isEmpty, let value = try JSONSerialization.jsonObject(with: row) as? [String: Any] {
                    _ = antigravityDecoder.read(value)
                }
            }
        }
    }

    var checkpoint: UInt64 { offset - UInt64(partial.count) }

    mutating func read(receive: (([Event], String) -> Void)? = nil) throws -> [Event] {
        if awaitingExpansion {
            let expanded = url.deletingPathExtension()
            let session = String(expanded.deletingPathExtension().lastPathComponent.suffix(36))
            guard let source = FileManager.default.fileExists(atPath: expanded.path) ? expanded
                : Self.locate(.codex, session: session, home: home, includeCompressed: false) else { return [] }
            url = source
            awaitingExpansion = false
        }
        if harness == .codex, !FileManager.default.fileExists(atPath: url.path) {
            let session = String(url.deletingPathExtension().lastPathComponent.suffix(36))
            if let moved = Self.locate(.codex, session: session, home: home, includeCompressed: false) { url = moved }
        }
        let file = try FileHandle(forReadingFrom: url)
        defer { try? file.close() }
        // TerminalRun reads on its queue; do not scan an archive during its main-actor launch.
        if harness == .antigravity, !primed {
            try rememberAntigravity(file, through: offset)
            primed = true
        }
        guard try file.seekToEnd() >= offset else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try file.seek(toOffset: offset)
        var events: [Event] = []
        while let data = try file.read(upToCount: 65_536), !data.isEmpty {
            offset += UInt64(data.count)
            partial.append(data)
            while let newline = partial.firstIndex(of: 10) {
                let start = offset - UInt64(partial.count)
                let line = Data(partial[..<newline])
                partial.removeSubrange(...newline)
                if !line.isEmpty {
                    let decoded = try decode(line)
                    if let receive { receive(decoded, url.lastPathComponent + "/\(start)") } else { events += decoded }
                }
            }
        }
        return events
    }

    private mutating func decode(_ data: Data) throws -> [Event] {
        if harness == .codex, let since {
            guard let row = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let stamp = row["timestamp"] as? String,
                  let date = try? Date(stamp, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)),
                  date >= since else { return [] }
            return Self.codex(row)
        }
        guard harness == .antigravity else { return try Self.events(data, harness: harness) }
        guard let row = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        return antigravityDecoder.read(row)
    }

    static func locate(_ harness: Harness, session: String) -> URL? {
        locate(harness, session: session, home: FileManager.default.homeDirectoryForCurrentUser)
    }

    static func locate(_ harness: Harness, session: String,
                       home: URL,
                       includeCompressed: Bool = true) -> URL? {
        if harness == .claude { return ClaudeInteractiveRun.transcriptFile(session) }
        if harness == .antigravity { return AntigravityQuestionArchive(session: session)?.file }
        guard harness == .codex || harness == .grok else { return nil }
        return locateStore(harness, session: session, home: home, includeCompressed: includeCompressed)
    }

    private static func locateStore(_ harness: Harness, session: String, home: URL,
                                    includeCompressed: Bool) -> URL? {
        let paths = harness == .codex ? [".codex/sessions", ".codex/archived_sessions"] : [".grok/sessions"]
        var compressed: URL?
        for path in paths {
            let root = home.appendingPathComponent(path)
            guard let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil,
                                                            options: [.skipsHiddenFiles]) else { continue }
            for case let url as URL in files {
                if matches(url, harness: harness, session: session) { return url }
                if harness == .codex, includeCompressed,
                   url.lastPathComponent.hasSuffix("-\(session).jsonl.zst") { compressed = url }
            }
        }
        return compressed
    }

    private static func matches(_ url: URL, harness: Harness, session: String) -> Bool {
        if harness == .codex { return url.lastPathComponent.hasSuffix("-\(session).jsonl") }
        return url.lastPathComponent == "updates.jsonl" && url.deletingLastPathComponent().lastPathComponent == session
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
        case .antigravity: return AntigravityTranscript.events(entry)
        case .shell: return []
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
        case .service(let text): return [.item(.status, text)]
        case .apiError(let text): return [.item(.error, text), .state(.waiting)]
        case .turnEnded: return [.state(.waiting)]
        case .background, .other: return StreamJSONFormatter.items(data).map { .item($0.kind, $0.text) }
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
        case "reasoning":
            return (payload["summary"] as? [[String: Any]] ?? []).compactMap { block in
                (block["text"] as? String).map { .item(.reasoning, $0) }
            }
        case "function_call_output", "custom_tool_call_output":
            return ToolOutput.content(payload["output"]).map { [.item(.output, $0)] } ?? []
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
        case "user_message_chunk", "agent_message_chunk", "agent_thought_chunk":
            guard let content = update["content"] as? [String: Any], content["type"] as? String == "text",
                  let text = content["text"] as? String else { return [] }
            if update["sessionUpdate"] as? String == "user_message_chunk" {
                let metadata = update["_meta"] as? [String: Any]
                return [.configuration(.init(model: metadata?["modelId"] as? String)),
                        .item(.user, text), .state(.working)]
            }
            let thought = update["sessionUpdate"] as? String == "agent_thought_chunk"
            let nativeID = GrokACPRun.textID(params: params, session: params["sessionId"] as? String,
                                           kind: thought ? .reasoning : .agent)
            return [.chunk(text, kind: thought ? .reasoning : .agent, nativeID: nativeID)]
        case "subagent_spawned", "subagent_finished":
            return SubagentStatus.grok(update).map { [.item(.status, $0)] } ?? []
        case "config_option_update":
            return [.configuration(.acp(update))]
        case "turn_completed": return [.state(.waiting)]
        case "tool_call", "tool_call_update":
            var events: [Event] = []
            if update["sessionUpdate"] as? String == "tool_call" {
                events.append(.item(.tool, update["title"] as? String ?? "Tool"))
            }
            events += (update["content"] as? [[String: Any]] ?? []).compactMap { block in
                GrokToolOutput.text(block).map { .item(.output, $0) }
            }
            return events
        default: return []
        }
    }

    private static func text(_ message: [String: Any]) -> String? {
        let parts = (message["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String } ?? []
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

}
