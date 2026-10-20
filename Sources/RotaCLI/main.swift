import AppKit
import Foundation
import RotaCore

// `rota`: manage Rota's routines from a terminal or an agent session, and
// `rota mcp`, the same as an MCP server. Every request goes to the running app
// over its control socket; the app is started in the background when closed.

let usage = """
    Usage: rota <command> [options]

      list                         routines, their schedules and state
      show <id>                    one routine
      add <id> --folder DIR --schedule "CRON" (--skill SKILL | --prompt TEXT)
          [--harness claude|codex|grok|shell] [--name NAME] [--model M] [--effort E]
          [--time-limit MIN] [--off]
      update <id> [the options of add] [--no-time-limit] [--default-model]
      on <id> | off <id>           turn a routine on or off
      run <id> | stop <id>         start a run now, or stop the running one
      remove <id>                  delete a routine and its sessions
      sessions <id> [--limit N]    recent sessions
      log <id> [--session ID] [--limit CHARS]
      send <id> [TEXT] [--session ID] [--attach FILE]...   message a session (the latest by default)
      session <id> [--session ID]  state, model, available actions and questions
      questions <id> [--session ID]   pending structured questions
      answer <id> --question ID --action ACTION [--values JSON] [--session ID]
                                   submit the user's explicit answer; values maps field ids to string arrays
      dismiss <id> [--session ID]  dismiss attention without answering questions
      mark-read <id> [--session ID]   mark a session as read
      delete-session <id> --session ID   delete a finished session and its local files; ask the user first
      tools                        discover commands and MCP schemas as JSON
      notify TEXT [--title T] [--needs-reply]
                                   a notification from Rota; inside a routine it opens that
                                   session, and --needs-reply marks it until you answer
      mcp                          serve these as MCP tools over stdio

    Add --json for the raw answer. Schedules are five-field cron in local time;
    a routine added here runs on its schedule unless --off is given.
    """

/// Starts Rota in the background when its socket does not answer, then waits for it.
func request(_ method: String, _ params: [String: Any] = [:]) throws -> Any {
    do {
        return try ControlClient.call(method, params)
    } catch let error as ControlError where error == .notRunning {
        try launchRota()
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.5)
            if let result = try? ControlClient.call(method, params) { return result }
        }
        return try ControlClient.call(method, params)
    }
}

func launchRota() throws {
    // This binary lives in Rota.app/Contents/Helpers; a symlink to it resolves there.
    let own = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let bundle = own.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let app = bundle.pathExtension == "app" ? bundle
        : NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.wiltodelta.rota")
    guard let app else { throw ControlError("Rota is not running and its app was not found.") }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = false
    // A data folder given to this command is the app's too, or it would open its usual one.
    if let directory = ProcessInfo.processInfo.environment["ROTA_DATA_DIR"] {
        configuration.environment = ["ROTA_DATA_DIR": directory]
    }
    let opened = DispatchSemaphore(value: 0)
    NSWorkspace.shared.openApplication(at: app, configuration: configuration) { _, _ in opened.signal() }
    _ = opened.wait(timeout: .now() + 20)
}

func line(_ routine: [String: Any]) -> String {
    let state = (routine["running"] as? Bool == true) ? "running" : (routine["enabled"] as? Bool == true ? "on" : "off")
    let parts = [routine["id"] as? String ?? "?", state, routine["harness"] as? String ?? "",
                 routine["scheduleText"] as? String ?? "", routine["model"] as? String]
    return parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "  ")
}

/// The control API's UTC timestamp in this Mac's time zone, as people read it.
func localTime(_ value: Any?) -> String {
    guard let text = value as? String, let date = ISO8601DateFormatter().date(from: text) else { return "" }
    return date.formatted(date: .abbreviated, time: .shortened)
}

/// "weekly-report  Running  Oct 11, 2026 at 2:31 PM  session 1E61…": a run started, stopped or messaged.
func sessionLine(_ session: [String: Any]) -> String {
    var parts = [session["routine"] as? String ?? "?", session["outcome"] as? String ?? "",
                 localTime(session["startedAt"]), "session \(session["session"] ?? "")"]
    if let question = session["needsReply"] as? String { parts.append("needs reply: \(question)") }
    return parts.filter { !$0.isEmpty }.joined(separator: "  ")
}

func printJSON(_ value: Any) {
    let data = (try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])) ?? Data()
    print(lossyUTF8(data))
}

/// A reply for people: a line per routine or session, the log as text, JSON otherwise.
func show(_ result: Any, for command: String) {
    switch result {
    case let routines as [[String: Any]] where command == "list":
        print(routines.isEmpty ? "No routines." : routines.map(line).joined(separator: "\n"))
    case let sessions as [[String: Any]] where command == "sessions":
        print(sessions.map { "\($0["session"] ?? "")  \(localTime($0["startedAt"]))  \($0["outcome"] ?? "")" }
            .joined(separator: "\n"))
    case let session as [String: Any] where command == "log":
        print(session["log"] as? String ?? "")
    case let routine as [String: Any] where routine["schedule"] != nil:
        print(line(routine))
    case let session as [String: Any] where session["session"] != nil && !["notify", "session"].contains(command):
        print(sessionLine(session))
    case let answer as [String: String] where answer.count == 1:
        // {"stopping": id} and {"deleted": id}.
        print(answer.map { "\($0.key.capitalized) \($0.value)" }[0])
    default:
        printJSON(result)
    }
}

func run(_ raw: [String]) throws {
    let arguments = try ControlCLI.Arguments(raw)
    guard let command = arguments.positional.first, command != "help", !arguments.flags.contains("help") else {
        return print(usage)
    }
    if command == "question-hook" { return try QuestionHook.run() }
    if command == "mcp" { return MCPServer().serve() }
    if command == "tools" {
        return printJSON(ControlInterface.tools.map { tool in
            MCPServer.schema(tool).merging(["command": tool.command, "method": tool.method.rawValue]) { $1 }
        })
    }
    let (method, params) = try ControlCLI.request(command, arguments, environment: ProcessInfo.processInfo.environment)
    let result = try request(method, params)
    if arguments.flags.contains("json") { printJSON(result) } else { show(result, for: command) }
}

do {
    try run(Array(CommandLine.arguments.dropFirst()))
} catch {
    FileHandle.standardError.write(Data("rota: \(error.localizedDescription)\n".utf8))
    exit(1)
}
