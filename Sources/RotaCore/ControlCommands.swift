import Foundation

/// What other processes may ask the running app over `ControlServer`: the
/// `rota` command and the MCP server agents use. Every change goes through the
/// scheduler, the routines file's only writer.
extension Scheduler {
    private static let timestamp = ISO8601DateFormatter()

    public static let controlMethods = [
        "routines.list", "routines.get", "routines.create", "routines.update", "routines.setEnabled",
        "routines.run", "routines.stop", "routines.delete", "sessions.list", "sessions.read", "sessions.message",
        "sessions.dismiss", "notify", "questions.create", "questions.poll"
    ]

    public func control(_ method: String, _ params: [String: Any]) -> Result<Any, ControlError> {
        do {
            guard let result = try routineCommand(method, params)
                ?? sessionCommand(method, params) ?? questionCommand(method, params) else {
                let known = Self.controlMethods.joined(separator: ", ")
                throw ControlError("Unknown method \(method). Known: \(known).")
            }
            return .success(result)
        } catch let error as ControlError {
            return .failure(error)
        } catch {
            return .failure(ControlError(error.localizedDescription))
        }
    }

    private func routineCommand(_ method: String, _ params: [String: Any]) throws -> Any? {
        switch method {
        case "routines.list": return routines.map(describe)
        case "routines.get": return describe(try existing(params))
        case "routines.create": return describe(try create(params))
        case "routines.update": return describe(try update(params))
        case "routines.setEnabled": return describe(try enable(params))
        case "routines.run": return try runNow(params)
        case "routines.stop": return try stopNow(params)
        case "routines.delete": return try remove(params)
        default: return nil
        }
    }

    private func sessionCommand(_ method: String, _ params: [String: Any]) throws -> Any? {
        switch method {
        case "sessions.list": return try sessions(params)
        case "sessions.read": return try read(params)
        case "sessions.message": return try send(params)
        case "sessions.dismiss":
            let record = try session(params)
            dismissAttention(record)
            return describe(current(record.id, routineID: record.routineID) ?? record)
        case "notify":
            let record = try notify(try value(params, "message", as: String.self),
                                    title: try optional(params, "title", as: String.self),
                                    session: try optional(params, "session", as: String.self),
                                    routineID: try optional(params, "routine", as: String.self),
                                    needsReply: try optional(params, "needsReply", as: Bool.self) ?? false)
            return record.map(describe) ?? ["notified": true]
        default: return nil
        }
    }

    // MARK: Routines

    private func existing(_ params: [String: Any]) throws -> Routine {
        let id = try value(params, "id", as: String.self)
        guard let routine = routine(id) else { throw ControlError("No routine \(id).") }
        return routine
    }

    private func create(_ params: [String: Any]) throws -> Routine {
        let id = try value(params, "id", as: String.self)
        guard routine(id) == nil else { throw ControlError("A routine \(id) exists; update it instead.") }
        // Like a routine made in the window, it runs on its schedule from the start.
        var routine = Routine(id: id, name: id, workingDirectory: "", schedule: "", harness: .claude,
                              enabled: true, prompt: "")
        try apply(params, to: &routine)
        try validate(routine)
        save(routine)
        notifier?.routineAdded(routine)
        return self.routine(id) ?? routine
    }

    private func update(_ params: [String: Any]) throws -> Routine {
        var routine = try existing(params)
        let harness = routine.harness
        try apply(params, to: &routine)
        if routine.harness != harness, params["model"] == nil, params["effort"] == nil {
            // Model ids belong to the harness they came from.
            routine.model = nil
            routine.effort = nil
        }
        try validate(routine, checkingID: false)
        save(routine)
        return self.routine(routine.id) ?? routine
    }

    /// Copies the fields `params` names onto `routine`. `folder` is
    /// `workingDirectory`, and `skill` writes the usual prompt for a project skill.
    private func apply(_ params: [String: Any], to routine: inout Routine) throws {
        let texts: [(String, WritableKeyPath<Routine, String>)] = [("name", \.name), ("schedule", \.schedule),
                                                                   ("prompt", \.prompt)]
        for (key, path) in texts {
            if let text = try optional(params, key, as: String.self) { routine[keyPath: path] = text }
        }
        if let folder = try optional(params, "workingDirectory", as: String.self)
            ?? optional(params, "folder", as: String.self) {
            routine.workingDirectory = (folder as NSString).expandingTildeInPath
        }
        if let harness = try optional(params, "harness", as: String.self) {
            guard let value = Harness(rawValue: harness) else {
                throw ControlError("Unknown harness \(harness). Use one of \(Harness.allCases.map(\.rawValue)).")
            }
            routine.harness = value
        }
        if let skill = try optional(params, "skill", as: String.self) {
            routine.prompt = Routine.defaultPrompt(skill: skill, workingDirectory: routine.workingDirectory)
        }
        if params.keys.contains("model") { routine.model = try optional(params, "model", as: String.self) }
        if params.keys.contains("effort") { routine.effort = try optional(params, "effort", as: String.self) }
        if params.keys.contains("timeLimitMinutes") {
            routine.timeLimitMinutes = try optional(params, "timeLimitMinutes", as: Int.self)
        }
        if let enabled = try optional(params, "enabled", as: Bool.self) { routine.enabled = enabled }
    }

    private func validate(_ routine: Routine, checkingID: Bool = true) throws {
        if let problem = routine.problem(checkingID: checkingID) { throw ControlError(problem) }
    }

    private func enable(_ params: [String: Any]) throws -> Routine {
        let routine = try existing(params)
        setEnabled(try value(params, "enabled", as: Bool.self), for: routine.id)
        return try existing(params)
    }

    private func stopNow(_ params: [String: Any]) throws -> [String: Any] {
        let routine = try existing(params)
        guard active[routine.id] != nil else { throw ControlError("\(routine.id) is not running.") }
        stop(routine.id)
        return ["stopping": routine.id]
    }

    private func remove(_ params: [String: Any]) throws -> [String: Any] {
        let routine = try existing(params)
        delete(routine.id)
        return ["deleted": routine.id]
    }

    private func runNow(_ params: [String: Any]) throws -> [String: Any] {
        let routine = try existing(params)
        guard active[routine.id] == nil else { throw ControlError("\(routine.id) is already running.") }
        run(routine, trigger: .manual)
        guard let record = active[routine.id] else {
            throw ControlError(lastError ?? "\(routine.id) did not start; see its latest session.")
        }
        return describe(record)
    }

    /// A routine as JSON, with what a caller wants to know about it now.
    func describe(_ routine: Routine) -> [String: Any] {
        var json = (try? JSONSerialization.jsonObject(with: JSONFile.encoder.encode(routine))) as? [String: Any] ?? [:]
        json["scheduleText"] = ScheduleText.describe(routine.schedule) ?? routine.schedule
        json["running"] = active[routine.id] != nil
        if let last = history.records(for: routine.id).first(where: { !$0.isSkip }) {
            json["lastSession"] = describe(last)
        }
        return json
    }

    // MARK: Sessions

    private func sessions(_ params: [String: Any]) throws -> [[String: Any]] {
        let routine = try existing(params)
        let limit = try optional(params, "limit", as: Int.self) ?? 10
        return history.records(for: routine.id).filter { !$0.isSkip }.prefix(max(limit, 1)).map(describe)
    }

    private func session(_ params: [String: Any]) throws -> RunRecord {
        let routine = try existing(params)
        if let id = try optional(params, "session", as: String.self) {
            guard let record = current(id, routineID: routine.id) else {
                throw ControlError("No session \(id) of \(routine.id).")
            }
            return record
        }
        guard let latest = active[routine.id] ?? history.records(for: routine.id).first(where: { !$0.isSkip }) else {
            throw ControlError("\(routine.id) has no sessions.")
        }
        return latest
    }

    /// The session's chat log, its last `limit` characters (20,000 by default).
    private func read(_ params: [String: Any]) throws -> [String: Any] {
        let record = try session(params)
        let limit = try optional(params, "limit", as: Int.self) ?? 20_000
        // Only the end is read: a long session's log can be megabytes, and this runs on the main thread.
        let (log, cut) = record.logPath.map { Self.tail(of: $0, characters: max(limit, 1)) } ?? ("", false)
        var json = describe(record)
        json["log"] = log
        json["truncated"] = cut
        return json
    }

    private func send(_ params: [String: Any]) throws -> [String: Any] {
        let record = try session(params)
        let text = try value(params, "text", as: String.self)
        guard canMessage(record) else {
            throw ControlError(record.harness.isAgent ? "That session cannot take a message now."
                               : "A shell session takes no messages.")
        }
        message(text, to: record)
        return describe(active[record.routineID] ?? record)
    }

    /// The last `characters` of a text file and whether anything came before them.
    static func tail(of path: String, characters: Int) -> (String, Bool) {
        guard let file = FileHandle(forReadingAtPath: path) else { return ("", false) }
        defer { try? file.close() }
        let size = (try? file.seekToEnd()) ?? 0
        // UTF-8 takes up to four bytes a character.
        let start = size > UInt64(characters * 4) ? size - UInt64(characters * 4) : 0
        try? file.seek(toOffset: start)
        let text = lossyUTF8(file.readDataToEndOfFile())
        return (String(text.suffix(characters)), start > 0 || text.count > characters)
    }

    func describe(_ record: RunRecord) -> [String: Any] {
        var json: [String: Any] = ["session": record.id.uuidString, "routine": record.routineID,
                                   "harness": record.harness.rawValue, "trigger": record.trigger.rawValue,
                                   "startedAt": Self.timestamp.string(from: record.startedAt),
                                   "outcome": record.outcome.title, "running": isActive(record)]
        if isActive(record), let state = record.terminalState { json["terminalState"] = state.rawValue }
        if let ended = record.endedAt { json["endedAt"] = Self.timestamp.string(from: ended) }
        if let attention = record.attention { json["needsReply"] = attention }
        return json
    }

    // MARK: Parameters

    private func value<T>(_ params: [String: Any], _ key: String, as type: T.Type) throws -> T {
        guard let value = try optional(params, key, as: type) else { throw ControlError("Missing \(key).") }
        return value
    }

    private func optional<T>(_ params: [String: Any], _ key: String, as type: T.Type) throws -> T? {
        guard let raw = params[key], !(raw is NSNull) else { return nil }
        if T.self == Bool.self, let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
            return number.boolValue as? T
        }
        if T.self == Int.self, let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() {
            return number.intValue as? T
        }
        if T.self == String.self, let text = raw as? String { return text as? T }
        let expected = T.self == Int.self ? "a number" : T.self == Bool.self ? "true or false" : "text"
        throw ControlError("\(key) should be \(expected).")
    }
}
