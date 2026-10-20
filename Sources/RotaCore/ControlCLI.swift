import Foundation

/// CLI requests use the MCP catalog's method mapping, with terminal syntax translated here.
public enum ControlCLI {
    public struct Arguments {
        public var positional: [String] = []
        public var options: [String: String] = [:]
        public var attachments: [String] = []
        public var flags: Set<String> = []
        static let flagNames: Set<String> = ["json", "off", "no-time-limit", "default-model", "help", "needs-reply"]

        public init(_ raw: [String]) throws {
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
                        if name == "attach" { attachments.append(raw[index]) } else { options[name] = raw[index] }
                    }
                } else {
                    positional.append(word)
                }
                index += 1
            }
        }
    }

    /// The routine fields `add` and `update` take, as the control API names them.
    private static func routineFields(_ arguments: Arguments) -> [String: Any] {
        var fields: [String: Any] = [:]
        let names = [
            "name": "name", "folder": "workingDirectory", "schedule": "schedule", "harness": "harness",
            "prompt": "prompt", "skill": "skill", "model": "model", "effort": "effort",
        ]
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

    public static func request(
        _ command: String, _ arguments: Arguments,
        environment: [String: String] = [:]
    ) throws -> (String, [String: Any]) {
        guard let tool = ControlInterface.tools.first(where: { $0.command == (command == "off" ? "on" : command) })
        else {
            throw ControlError("Unknown command \(command). Run rota help.")
        }
        if tool.method == .routinesList { return (tool.method.rawValue, [:]) }
        if tool.method == .notify {
            let params = try notifyParams(arguments.positional.dropFirst(), arguments)
            return (tool.method.rawValue, ControlInterface.sessionArguments(params, method: tool.method,
                                                                           environment: environment))
        }
        guard let id = arguments.positional.dropFirst().first else {
            throw ControlError("\(command) needs a routine id.")
        }
        var params: [String: Any] = ["id": id]
        if let session = arguments.options["session"] { params["session"] = session }
        if let limit = arguments.options["limit"] {
            guard let number = Int(limit) else { throw ControlError("--limit needs an integer.") }
            params["limit"] = number
        }
        params.merge(try commandFields(tool.method, arguments)) { $1 }
        if tool.method == .sessionsDelete, params["session"] == nil {
            throw ControlError("delete-session needs an explicit --session ID.")
        }
        return (tool.method.rawValue, ControlInterface.sessionArguments(params, method: tool.method,
                                                                       environment: environment))
    }

    private static func commandFields(_ method: ControlMethod, _ arguments: Arguments) throws -> [String: Any] {
        var params: [String: Any] = [:]
        switch method {
        case .routinesCreate, .routinesUpdate: params.merge(routineFields(arguments)) { $1 }
        case .routinesSetEnabled: params["enabled"] = arguments.positional.first == "on"
        case .sessionsMessage:
            let text = arguments.positional.dropFirst(2).joined(separator: " ")
            guard !text.isEmpty || !arguments.attachments.isEmpty else {
                throw ControlError("send needs a message or --attach FILE.")
            }
            params["text"] = text
            params["attachments"] = arguments.attachments.map { ($0 as NSString).expandingTildeInPath }
        case .sessionsAnswer: return try answerFields(arguments)
        default: break
        }
        return params
    }

    private static func answerFields(_ arguments: Arguments) throws -> [String: Any] {
        var params: [String: Any] = [:]
        guard let question = arguments.options["question"], let action = arguments.options["action"] else {
            throw ControlError("answer needs --question ID and --action ACTION. Run rota questions first.")
        }
        params["question"] = question
        params["action"] = action
        if let values = arguments.options["values"] {
            guard let object = try JSONSerialization.jsonObject(with: Data(values.utf8)) as? [String: [String]] else {
                throw ControlError("--values must map field ids to arrays of strings.")
            }
            params["values"] = object
        }
        return params
    }

    /// A notification's text and where it comes from: the session Rota started this
    /// process in (ROTA_SESSION), unless --session or --routine names another.
    private static func notifyParams(_ words: ArraySlice<String>,
                                     _ arguments: Arguments) throws -> [String: Any] {
        let text = words.joined(separator: " ")
        guard !text.isEmpty else { throw ControlError("notify needs the message.") }
        var params: [String: Any] = ["message": text, "needsReply": arguments.flags.contains("needs-reply")]
        params["title"] = arguments.options["title"]
        if let routine = arguments.options["routine"] {
            params["routine"] = routine
        } else if let session = arguments.options["session"] {
            params["session"] = session
        }
        return params
    }

}
