import Foundation

/// A tool a routine's skill may depend on that not every harness has.
public enum Capability: String, CaseIterable, Codable, Sendable {
    case chrome
    case push

    public var title: String {
        switch self {
        case .chrome: return "Chrome"
        case .push: return "Phone push"
        }
    }
}

public enum CapabilitySupport: Equatable, Sendable {
    case native
    /// The harness has the capability under different tool names, so a skill
    /// written against Claude's names needs a binding before it works there.
    case differentTools(String)
    case missing
}

/// How a run is started and watched. Each keeps the run open to the user while it works.
public enum LaunchMode: Equatable, Sendable {
    /// `claude -p` with stream-json in and out; Rota writes into the session.
    case claudeStream
    /// A thread on Codex's shared app-server daemon; Rota steers it with `turn/steer`.
    case codexDaemon
    /// A session on Grok's shared leader over ACP; Rota sends it prompts.
    case grokACP
    /// A detached `screen` session the user attaches to with `screen -r`.
    case screen
}

/// What a routine runs on: an agent CLI, or a plain shell command.
public enum Harness: String, CaseIterable, Codable, Identifiable, Sendable {
    case claude
    case codex
    case grok
    case shell

    public var id: String { rawValue }

    /// The harnesses that run an agent CLI, as opposed to a shell command.
    public static let agents = allCases.filter(\.isAgent)

    /// The CLI's name: the agent's own, or the shell that runs a command.
    public var commandName: String { self == .shell ? "zsh" : rawValue }

    public var title: String {
        switch self {
        case .claude: return "Claude Code"
        case .codex: return "Codex"
        case .grok: return "Grok Build"
        case .shell: return "Shell"
        }
    }

    public var isAgent: Bool { self != .shell }

    /// Where the CLI installs itself, used until the user sets another path.
    public func defaultExecutable(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        switch self {
        case .claude, .grok: return home.appendingPathComponent(".local/bin/\(commandName)").path
        case .codex: return "/opt/homebrew/bin/\(commandName)"
        case .shell: return "/bin/\(commandName)"
        }
    }

    public func support(for capability: Capability) -> CapabilitySupport {
        switch (self, capability) {
        case (.claude, _):
            return .native
        case (.codex, .chrome):
            return .differentTools("Codex drives Chrome through its own plugin, not mcp__claude-in-chrome__ tools.")
        case (.codex, .push), (.grok, _), (.shell, _):
            return .missing
        }
    }

    public var launchMode: LaunchMode {
        switch self {
        case .claude: return .claudeStream
        case .codex: return .codexDaemon
        case .grok: return .grokACP
        case .shell: return .screen
        }
    }

    /// The `claude` arguments; the other harnesses are driven over their protocols
    /// and take none. Every agent runs with approvals bypassed, the
    /// `bypassPermissions` mode Claude Desktop routines use: nobody is there to
    /// answer a prompt. The prompt itself goes in on stdin.
    public func arguments(needs: Set<Capability>, resume: String? = nil) -> [String] {
        guard self == .claude else { return [] }
        return ClaudeStreamRun.arguments(chrome: needs.contains(.chrome), resume: resume)
    }

    /// `claude` ignores the Chrome default in settings when started from a script;
    /// this variable turns it on.
    public func environment(needs: Set<Capability>) -> [String: String] {
        self == .claude && needs.contains(.chrome) ? ["CLAUDE_CODE_ENABLE_CFC": "1"] : [:]
    }

    /// The terminal command that opens session `session`, if the harness has one
    /// in that state: the executable (nil for the harness's own) and its arguments.
    /// While an agent runs, Rota holds its session and talks to it in the chat;
    /// afterwards the terminal app resumes it. A shell session exists only while it runs.
    public func terminal(session: String, running: Bool) -> (executable: String?, arguments: [String])? {
        switch (self, running) {
        case (.claude, false): return (nil, ["--resume", session])
        case (.codex, false): return (nil, ["resume", session])
        case (.grok, false): return (nil, ["--resume", session])
        case (.shell, true): return (ScreenRun.screen, ["-r", session])
        case (.claude, true), (.codex, true), (.grok, true), (.shell, false): return nil
        }
    }

    /// Whether Rota's chat field can message the session: every agent can, running
    /// or finished; a shell command takes input only in its terminal.
    public var takesMessages: Bool { self != .shell }
}
