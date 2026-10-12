import Foundation

/// The switches in the user's `~/.claude.json` that an interactive Claude Code
/// applies by itself and `claude -p` does not, so Rota passes them on and a
/// routine runs with what the user turned on, nothing more.
///
/// Chrome: `claudeInChromeDefaultEnabled` (`/chrome` > "Enabled by default");
/// print mode reads it only through `--chrome`.
///
/// Computer use is loaded only by an interactive session: Claude Code 2.1.296
/// adds its built-in server behind `isInteractive()`, drops one configured
/// under the reserved name `computer-use`, and the same server
/// (`claude --computer-use-mcp`) added under another name lists its tools but
/// answers every call "not wired to a session" (checked 2026-10-11). So Claude
/// routines run interactively (`ClaudeInteractiveRun`) where the folder is trusted.
public struct ClaudeUserSettings: Equatable, Sendable {
    public var chromeByDefault = false
    /// The folders whose trust dialog the user accepted, `projects[…].hasTrustDialogAccepted`.
    public var trustedProjects: Set<String> = []

    public init(chromeByDefault: Bool = false, trustedProjects: Set<String> = []) {
        self.chromeByDefault = chromeByDefault
        self.trustedProjects = trustedProjects
    }

    /// Whether an interactive Claude starts in `directory` without its trust
    /// dialog, which nobody is there to answer: the folder or its repository
    /// was trusted in Claude Code. Rota never answers that dialog or sets the
    /// flag itself; an untrusted folder runs in print mode, which skips the dialog.
    public func trusts(_ directory: String) -> Bool {
        var url = URL(fileURLWithPath: directory).standardizedFileURL.resolvingSymlinksInPath()
        if trustedProjects.contains(url.path) || trustedProjects.contains(directory) { return true }
        while url.path != "/" {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) {
                return trustedProjects.contains(url.path)
            }
            url.deleteLastPathComponent()
        }
        return false
    }

    public static var standardFile: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude.json")
    }

    /// Reads `file`; a missing or unreadable file turns nothing on.
    public static func read(_ file: URL = standardFile) -> ClaudeUserSettings {
        guard let data = try? Data(contentsOf: file),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            return ClaudeUserSettings()
        }
        let projects = json["projects"] as? [String: [String: Any]] ?? [:]
        let trusted = projects.filter { $0.value["hasTrustDialogAccepted"] as? Bool == true }.keys
        return ClaudeUserSettings(chromeByDefault: json["claudeInChromeDefaultEnabled"] as? Bool == true,
                                  trustedProjects: Set(trusted))
    }
}
