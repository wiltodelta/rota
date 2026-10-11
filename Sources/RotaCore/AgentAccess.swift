import Foundation

/// Lets agent sessions manage routines: the `rota` command on the PATH, and
/// `rota mcp` added to each agent CLI as an MCP server named "rota". Each CLI
/// keeps its own MCP list; Rota changes it only through that CLI's `mcp add` and
/// `mcp remove`, when the user asks in Settings.
public enum AgentAccess {
    public static let serverName = "rota"

    /// Where Settings links the `rota` command: a folder login shells put on the PATH.
    public static func commandLink(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent(".local/bin/rota")
    }

    /// The helper inside the app bundle that both the link and the MCP entries run.
    public static func helper(in bundle: Bundle = .main) -> URL {
        bundle.bundleURL.appendingPathComponent("Contents/Helpers/rota")
    }

    public static func commandInstalled(link: URL = commandLink(), helper: URL = helper()) -> Bool {
        link.resolvingSymlinksInPath().path == helper.resolvingSymlinksInPath().path
    }

    /// Points `link` at `helper`, replacing a link that points elsewhere but never a real file.
    public static func installCommand(link: URL = commandLink(), helper: URL = helper()) throws {
        let files = FileManager.default
        try files.createDirectory(at: link.deletingLastPathComponent(), withIntermediateDirectories: true)
        if (try? files.destinationOfSymbolicLink(atPath: link.path)) != nil {
            try files.removeItem(at: link)
        } else if files.fileExists(atPath: link.path) {
            throw ControlError("\(link.path) is a file, not Rota's link; move it away first.")
        }
        try files.createSymbolicLink(at: link, withDestinationURL: helper)
    }

    /// The `mcp add` arguments of `harness`'s CLI for a server running `command mcp`.
    public static func addArguments(_ harness: Harness, command: String) -> [String] {
        switch harness {
        case .claude: return ["mcp", "add", "-s", "user", serverName, "--", command, "mcp"]
        case .codex: return ["mcp", "add", serverName, "--", command, "mcp"]
        case .grok: return ["mcp", "add", "-s", "user", serverName, command, "--", "mcp"]
        case .shell: return []
        }
    }

    public static func removeArguments(_ harness: Harness) -> [String] {
        switch harness {
        case .claude: return ["mcp", "remove", "-s", "user", serverName]
        case .codex: return ["mcp", "remove", serverName]
        case .grok: return ["mcp", "remove", "-s", "user", serverName]
        case .shell: return []
        }
    }

    /// Whether `harness`'s CLI lists the server. Blocks on the CLI: call it off the main thread.
    public static func isAdded(_ harness: Harness, executable: String) -> Bool {
        switch harness {
        case .claude, .codex:
            return ProcessLauncher.capture(executable, ["mcp", "get", serverName], in: NSTemporaryDirectory(),
                                           timeout: 20).0 == 0
        case .grok:
            let (status, output) = ProcessLauncher.capture(executable, ["mcp", "list", "--json"],
                                                           in: NSTemporaryDirectory(), timeout: 20, errors: false)
            return status == 0 && lists(serverName, in: output)
        case .shell:
            return false
        }
    }

    /// Whether a JSON listing names `name`, as a key or as a `name` field.
    static func lists(_ name: String, in json: String) -> Bool {
        guard let value = try? JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed])
        else { return false }
        func search(_ value: Any) -> Bool {
            if let object = value as? [String: Any] {
                return object.keys.contains(name) || object["name"] as? String == name
                    || object.values.contains(where: search)
            }
            return (value as? [Any])?.contains(where: search) ?? false
        }
        return search(value)
    }

    /// Runs `harness`'s CLI to add or remove the server and returns its own words on failure.
    public static func change(_ harness: Harness, add: Bool, executable: String,
                              command: String = commandLink().path) -> String? {
        let arguments = add ? addArguments(harness, command: command) : removeArguments(harness)
        let (status, output) = ProcessLauncher.capture(executable, arguments, in: NSTemporaryDirectory(), timeout: 30)
        return status == 0 ? nil : output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
