import Foundation
import RotaCore

/// `rota mcp`: Rota's routines as MCP tools over stdio, one JSON-RPC message
/// per line, for Claude Code, Codex and Grok Build. Each tool is one control
/// method of the running app.
struct MCPServer {
    struct Tool {
        let name: String
        let method: String
        let description: String
        let properties: [String: [String: Any]]
        let required: [String]
    }

    private static func property(_ type: Any, _ description: String) -> [String: Any] {
        ["type": type, "description": description]
    }

    private static let id = property("string", "The routine's id, such as weekly-report.")
    private static let session = property("string", "A session id; the latest session when left out.")
    private static let fields: [String: [String: Any]] = [
        "id": id,
        "name": property("string", "A title for people; the id when left out."),
        "workingDirectory": property("string", "The project folder the routine runs in, an absolute path."),
        "schedule": property("string",
                             "Five-field cron in the Mac's local time, such as \"0 9 * * 1-5\" for weekdays at 9:00."),
        "harness": property("string", "Where it runs: claude (Claude Code), codex, grok (Grok Build) or shell "
                                + "(a zsh command).").merging(["enum": Harness.allCases.map(\.rawValue)]) { $1 },
        "prompt": property("string", "What the agent is asked each run, or the command for shell."),
        "skill": property("string",
                          "A project skill in .claude/skills/<skill>/SKILL.md; writes the usual prompt that runs it."),
        "model": property(["string", "null"], "A model the harness's CLI lists; null for its default."),
        "effort": property(["string", "null"],
                           "Reasoning effort, such as low, medium or high; null for the model's default."),
        "timeLimitMinutes": property(["integer", "null"], "Stop a run after this many minutes; null (the default) "
                                         + "lets it take as long as it needs."),
        "enabled": property("boolean", "Whether it runs on its schedule. New routines are on unless this is false.")
    ]

    static let tools: [Tool] = [
        Tool(name: "list_routines", method: "routines.list",
             description: "List Rota's scheduled routines with their schedules, harness, state and latest session.",
             properties: [:], required: []),
        Tool(name: "get_routine", method: "routines.get", description: "Show one routine.",
             properties: ["id": id], required: ["id"]),
        Tool(name: "create_routine", method: "routines.create",
             description: "Schedule a new routine in Rota. It runs unattended on its schedule with approvals bypassed, "
                + "and Rota notifies the user that an agent added it. Give a prompt or a skill.",
             properties: fields, required: ["id", "workingDirectory", "schedule"]),
        Tool(name: "update_routine", method: "routines.update",
             description: "Change a routine; only the fields given change.", properties: fields, required: ["id"]),
        Tool(name: "set_routine_enabled", method: "routines.setEnabled", description: "Turn a routine on or off.",
             properties: ["id": id, "enabled": fields["enabled"]!], required: ["id", "enabled"]),
        Tool(name: "run_routine", method: "routines.run", description: "Start a run of a routine now.",
             properties: ["id": id], required: ["id"]),
        Tool(name: "stop_routine", method: "routines.stop", description: "Stop a routine's running session.",
             properties: ["id": id], required: ["id"]),
        Tool(name: "delete_routine", method: "routines.delete",
             description: "Delete a routine and its session history. Ask the user first.",
             properties: ["id": id], required: ["id"]),
        Tool(name: "list_sessions", method: "sessions.list", description: "A routine's recent sessions, newest first.",
             properties: ["id": id, "limit": property("integer", "How many; 10 by default.")],
             required: ["id"]),
        Tool(name: "read_session", method: "sessions.read",
             description: "A session's chat log: [you] lines are the prompt and messages, -> lines tools, "
                + "the rest the agent.",
             properties: ["id": id, "session": session,
                          "limit": property("integer", "Characters from the end; 20000 by default.")],
             required: ["id"]),
        Tool(name: "notify_user", method: "notify",
             description: "Show the user a Mac notification from Rota. Inside a routine it opens this session; set "
                + "needsReply when the user has to answer or confirm something, and the session stays marked until "
                + "they reply in its chat.",
             properties: ["message": property("string", "What the user should know or decide, in a sentence or two."),
                          "title": property("string", "A short title; the routine's name when left out."),
                          "needsReply": property("boolean", "The session waits for the user's answer.")],
             required: ["message"]),
        Tool(name: "message_session", method: "sessions.message",
             description: "Send a message to a routine's session: it joins a running turn, or continues "
                + "a finished session.",
             properties: ["id": id, "session": session, "text": property("string", "The message.")],
             required: ["id", "text"])
    ]

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
            case "tools/list": answer = ["result": ["tools": Self.tools.map(Self.schema)]]
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

    static func schema(_ tool: Tool) -> [String: Any] {
        ["name": tool.name, "description": tool.description,
         "inputSchema": ["type": "object", "properties": tool.properties, "required": tool.required]]
    }

    /// Runs a tool against the app; a refusal comes back as a tool error the model can read.
    func call(_ params: [String: Any]) -> [String: Any] {
        let name = params["name"] as? String ?? ""
        guard let tool = Self.tools.first(where: { $0.name == name }) else {
            return Self.text("Unknown tool \(name).", isError: true)
        }
        do {
            var arguments = params["arguments"] as? [String: Any] ?? [:]
            // Started by an agent inside a routine, the server knows the session it serves: notify and
            // that routine's session tools default to it rather than to the routine's latest session.
            let environment = ProcessInfo.processInfo.environment
            if arguments["session"] == nil, let session = environment["ROTA_SESSION"],
               tool.method == "notify" ? arguments["routine"] == nil
                   : tool.method.hasPrefix("sessions.") && arguments["id"] as? String == environment["ROTA_ROUTINE"] {
                arguments["session"] = session
            }
            let result = try request(tool.method, arguments)
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
