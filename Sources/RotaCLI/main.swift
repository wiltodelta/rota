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
      send <id> TEXT [--session ID]   message a session (the latest by default)
      notify TEXT [--title T] [--needs-reply]
                                   a notification from Rota; inside a routine it opens that
                                   session, and --needs-reply marks it until you answer
      mcp                          serve these as MCP tools over stdio

    Add --json for the raw answer. Schedules are five-field cron in local time;
    a routine added here runs on its schedule unless --off is given.
    """

struct Arguments {
    var positional: [String] = []
    var options: [String: String] = [:]
    var flags: Set<String> = []
    static let flagNames: Set<String> = ["json", "off", "no-time-limit", "default-model", "help", "needs-reply"]

    init(_ raw: [String]) throws {
        var index = 0
        while index < raw.count {
            let word = raw[index]
            if word.hasPrefix("--") {
                let name = String(word.dropFirst(2))
                if Self.flagNames.contains(name) {
                    flags.insert(name)
                } else {
                    index += 1
                    guard index < raw.count else { throw ControlError("--\(name) needs a value.") }
                    options[name] = raw[index]
                }
            } else {
                positional.append(word)
            }
            index += 1
        }
    }
}

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

/// The routine fields `add` and `update` take, as the control API names them.
func routineFields(_ arguments: Arguments) -> [String: Any] {
    var fields: [String: Any] = [:]
    let names = ["name": "name", "folder": "workingDirectory", "schedule": "schedule", "harness": "harness",
                 "prompt": "prompt", "skill": "skill", "model": "model", "effort": "effort"]
    for (option, field) in names { if let value = arguments.options[option] { fields[field] = value } }
    if let limit = arguments.options["time-limit"] { fields["timeLimitMinutes"] = Int(limit) ?? limit }
    if arguments.flags.contains("no-time-limit") { fields["timeLimitMinutes"] = NSNull() }
    if arguments.flags.contains("default-model") {
        fields["model"] = NSNull()
        fields["effort"] = NSNull()
    }
    if arguments.flags.contains("off") { fields["enabled"] = false }
    return fields
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

/// The control method and parameters a command asks for.
func requestFor(_ command: String, _ arguments: Arguments) throws -> (String, [String: Any]) {
    switch command {
    case "list": return ("routines.list", [:])
    case "notify": return ("notify", try notifyParams(arguments.positional.dropFirst(), arguments))
    default: return try routineRequest(command, arguments)
    }
}

/// The commands that name a routine by its id.
func routineRequest(_ command: String, _ arguments: Arguments) throws -> (String, [String: Any]) {
    guard let id = arguments.positional.dropFirst().first else {
        throw ControlError("\(command) needs a routine id.")
    }
    var params: [String: Any] = ["id": id]
    if let session = arguments.options["session"] { params["session"] = session }
    if let limit = arguments.options["limit"].flatMap(Int.init) { params["limit"] = limit }
    let plain = ["show": "routines.get", "run": "routines.run", "stop": "routines.stop", "remove": "routines.delete",
                 "sessions": "sessions.list", "log": "sessions.read"]
    if let method = plain[command] { return (method, params) }
    switch command {
    case "add", "update":
        let method = command == "add" ? "routines.create" : "routines.update"
        return (method, routineFields(arguments).merging(params) { $1 })
    case "on", "off": return ("routines.setEnabled", params.merging(["enabled": command == "on"]) { $1 })
    case "send":
        guard arguments.positional.count >= 3 else { throw ControlError("send needs a routine id and the text.") }
        let text = arguments.positional.dropFirst(2).joined(separator: " ")
        return ("sessions.message", params.merging(["text": text]) { $1 })
    default: throw ControlError("Unknown command \(command).\n\n\(usage)")
    }
}

/// A notification's text and where it comes from: the session Rota started this
/// process in (ROTA_SESSION), unless --session or --routine names another.
func notifyParams(_ words: ArraySlice<String>, _ arguments: Arguments) throws -> [String: Any] {
    let text = words.joined(separator: " ")
    guard !text.isEmpty else { throw ControlError("notify needs the message.") }
    let environment = ProcessInfo.processInfo.environment
    var params: [String: Any] = ["message": text, "needsReply": arguments.flags.contains("needs-reply")]
    params["title"] = arguments.options["title"]
    if let routine = arguments.options["routine"] {
        params["routine"] = routine
    } else if let session = arguments.options["session"] ?? environment["ROTA_SESSION"] {
        params["session"] = session
    }
    return params
}

/// A reply for people: a line per routine or session, the log as text, JSON otherwise.
func show(_ result: Any, for command: String) {
    switch result {
    case let routines as [[String: Any]] where command == "list":
        print(routines.isEmpty ? "No routines." : routines.map(line).joined(separator: "\n"))
    case let sessions as [[String: Any]]:
        print(sessions.map { "\($0["session"] ?? "")  \(localTime($0["startedAt"]))  \($0["outcome"] ?? "")" }
            .joined(separator: "\n"))
    case let session as [String: Any] where command == "log":
        print(session["log"] as? String ?? "")
    case let routine as [String: Any] where routine["schedule"] != nil:
        print(line(routine))
    case let session as [String: Any] where session["session"] != nil && command != "notify":
        print(sessionLine(session))
    case let answer as [String: String] where answer.count == 1:
        // {"stopping": id} and {"deleted": id}.
        print(answer.map { "\($0.key.capitalized) \($0.value)" }[0])
    default:
        printJSON(result)
    }
}

func run(_ raw: [String]) throws {
    let arguments = try Arguments(raw)
    guard let command = arguments.positional.first, command != "help", !arguments.flags.contains("help") else {
        return print(usage)
    }
    if command == "mcp" { return MCPServer().serve() }
    let (method, params) = try requestFor(command, arguments)
    let result = try request(method, params)
    if arguments.flags.contains("json") { printJSON(result) } else { show(result, for: command) }
}

do {
    try run(Array(CommandLine.arguments.dropFirst()))
} catch {
    FileHandle.standardError.write(Data("rota: \(error.localizedDescription)\n".utf8))
    exit(1)
}
