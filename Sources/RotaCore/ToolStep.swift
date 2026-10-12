import Foundation

/// What a tool call line in the log does, by the tool's name, so a run of
/// calls can be summed up the way super.engineering's chat does it ("ran 6
/// commands, edited 3 files, read 2 files") instead of listing every call.
/// Names come from every harness: Claude's tool names, Codex's `$ command`,
/// `edit files` and `search …`, Grok's ACP titles.
public enum ToolStep: String, CaseIterable, Sendable {
    case read, edit, search, execute, fetch, other

    public static func kind(of line: String) -> ToolStep {
        if line.hasPrefix("$ ") { return .execute }
        let name = (line.split(separator: " ").first.map(String.init) ?? line).lowercased()
        switch name {
        case "bash", "run_terminal_command", "shell", "exec_command", "bashoutput", "killshell":
            return .execute
        case "read", "read_file", "view", "notebookread":
            return .read
        case "edit", "multiedit", "write", "notebookedit", "search_replace", "write_file", "create_file":
            return .edit
        case "grep", "glob", "ls", "list_dir", "toolsearch", "search", "grep_search", "file_search":
            return .search
        case "webfetch", "web_fetch", "websearch", "web_search":
            return .fetch
        default:
            return line.lowercased().hasPrefix("edit files") ? .edit : .other
        }
    }

    /// The kind most of `lines` are; a tie goes to the kind that changes more, as there.
    public static func dominant(_ lines: [String]) -> ToolStep {
        let counts = Dictionary(grouping: lines.map(kind(of:)), by: { $0 }).mapValues(\.count)
        var best = ToolStep.other
        var bestCount = 0
        for kind in [ToolStep.edit, .execute, .read, .search, .fetch, .other] where (counts[kind] ?? 0) > bestCount {
            best = kind
            bestCount = counts[kind] ?? 0
        }
        return best
    }

    /// "ran 2 commands, read 1 file": what a run of calls did, most common work first.
    public static func summary(_ lines: [String]) -> String {
        let counts = Dictionary(grouping: lines.map(kind(of:)), by: { $0 }).mapValues(\.count)
        let order: [ToolStep] = [.read, .search, .execute, .edit, .fetch, .other]
        return order.compactMap { kind in counts[kind].map { kind.phrase($0) } }.joined(separator: ", ")
    }

    private func phrase(_ count: Int) -> String {
        let many = count != 1
        switch self {
        case .read: return "read \(count) \(many ? "files" : "file")"
        case .search: return "\(count) \(many ? "searches" : "search")"
        case .execute: return "ran \(count) \(many ? "commands" : "command")"
        case .edit: return "edited \(count) \(many ? "files" : "file")"
        case .fetch: return "fetched \(count) \(many ? "pages" : "page")"
        case .other: return "used \(count) \(many ? "tools" : "tool")"
        }
    }
}
