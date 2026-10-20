import Foundation
import RotaCore

/// `rota mcp`: Rota's routines as MCP tools over stdio, one JSON-RPC message
/// per line, for Claude Code, Codex and Grok Build. Each tool is one control
/// method of the running app.
struct MCPServer {
    func serve() {
        while let line = readLine(strippingNewline: true) {
            guard let message = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any],
                  let method = message["method"] as? String else { continue }
            // Notifications carry no id and get no answer.
            guard let id = message["id"] else { continue }
            let params = message["params"] as? [String: Any] ?? [:]
            let answer: [String: Any]
            switch method {
            case "initialize":
                answer = ["result": [
                    "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                    "capabilities": ["tools": [String: Any]()],
                    "serverInfo": ["name": "rota", "version": Self.version],
                    "instructions": "Rota is a Mac app that runs routines (prompts or shell commands) on a cron "
                        + "schedule on Claude Code, Codex, Grok Build or zsh. Use these tools to schedule, change, "
                        + "run and read them."
                ]]
            case "ping": answer = ["result": [String: Any]()]
            case "tools/list": answer = ["result": ["tools": ControlInterface.tools.map(Self.schema)]]
            case "tools/call": answer = ["result": call(params)]
            default: answer = ["error": ["code": -32601, "message": "Unknown method \(method)"]]
            }
            send(answer.merging(["jsonrpc": "2.0", "id": id]) { $1 })
        }
    }

    static var version: String {
        let own = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        let info = own.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Info.plist")
        return (NSDictionary(contentsOf: info)?["CFBundleShortVersionString"] as? String) ?? "dev"
    }

    static func schema(_ tool: ControlInterface.Tool) -> [String: Any] {
        ["name": tool.name, "description": tool.description,
         "inputSchema": ["type": "object", "properties": tool.properties, "required": tool.required]]
    }

    /// Runs a tool against the app; a refusal comes back as a tool error the model can read.
    func call(_ params: [String: Any]) -> [String: Any] {
        let name = params["name"] as? String ?? ""
        guard let tool = ControlInterface.tools.first(where: { $0.name == name }) else {
            return Self.text("Unknown tool \(name).", isError: true)
        }
        do {
            let arguments = ControlInterface.sessionArguments(params["arguments"] as? [String: Any] ?? [:],
                                                               method: tool.method,
                                                               environment: ProcessInfo.processInfo.environment)
            let result = try request(tool.method.rawValue, arguments)
            let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys,
                                                                                    .fragmentsAllowed])
            return Self.text(lossyUTF8(data), isError: false)
        } catch {
            return Self.text(error.localizedDescription, isError: true)
        }
    }

    static func text(_ text: String, isError: Bool) -> [String: Any] {
        ["content": [["type": "text", "text": text]], "isError": isError]
    }

    private func send(_ message: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: message) else { return }
        data.append(UInt8(ascii: "\n"))
        FileHandle.standardOutput.write(data)
    }
}
