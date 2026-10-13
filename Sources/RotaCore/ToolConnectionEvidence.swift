import Foundation

/// A provider's tool result, rather than its prose, establishes a native browser connection.
public struct ToolConnectionEvidence: Equatable, Sendable {
    public var chrome = false
    public var browser = false
    public var failure: String?

    public init(items: [TranscriptItem]) {
        for item in items {
            guard let tool = item.tool, let output = tool.output, !output.isEmpty else { continue }
            let title = tool.title.lowercased()
            let input = tool.input?.lowercased() ?? ""
            let chromeTool = title.hasPrefix("mcp__claude-in-chrome__")
            let cuaTool = title.contains("cua_repl") || (title == "js" && input.contains("cua."))
            guard chromeTool || cuaTool else { continue }
            if tool.status == "failed" || tool.status == "error" {
                failure = "The native browser tool returned an error. Open the check log for details."
                continue
            }
            guard tool.status == "completed" || tool.status == "success" else { continue }
            // Tool discovery and documentation do not prove the browser is connected.
            let chromeRead = chromeTool && title.contains("list_connected_browsers")
                && Self.hasLocalBrowser(output)
            let browserRead = cuaTool && (input.contains("listtabs") || input.contains("gettab")
                                         || input.contains("gettabs") || input.contains("createbrowsertab"))
            guard chromeRead || browserRead else { continue }
            let json = output.data(using: .utf8).flatMap {
                try? JSONSerialization.jsonObject(with: $0)
            } as? [String: Any]
            if json?["isError"] as? Bool == true { continue }
            browser = true
            let metadata = json?["_meta"] as? [String: Any]
            let surface = metadata?["codex/toolSurface"] as? [String: Any]
            let nativeChrome = surface?["kind"] as? String == "browserUse"
                && surface?["browserFamily"] as? String == "chrome"
            if chromeRead || nativeChrome { chrome = true }
        }
    }
    private static func hasLocalBrowser(_ output: String) -> Bool {
        guard let data = output.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) else { return false }
        return containsLocalBrowser(value)
    }

    private static func containsLocalBrowser(_ value: Any) -> Bool {
        if let rows = value as? [Any] { return rows.contains(where: containsLocalBrowser) }
        guard let row = value as? [String: Any] else { return false }
        if let id = row["deviceId"] as? String, UUID(uuidString: id) != nil,
           row["isLocal"] as? Bool == true, row["connectedAt"] is NSNumber { return true }
        if let text = row["text"] as? String { return hasLocalBrowser(text) }
        return false
    }

}
