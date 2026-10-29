import Foundation

/// What other processes may ask the running app over `ControlServer`: the
/// `rota` command and the MCP server agents use. Every change goes through the
/// scheduler, the routines file's only writer.
extension Scheduler {
    private static let timestamp = ISO8601DateFormatter()

    public static var controlMethods: [String] { ControlMethod.allCases.map(\.rawValue) }

    public func control(_ method: String, _ params: [String: Any]) -> Result<Any, ControlError> {
        do {
            guard let operation = ControlMethod(rawValue: method),
                  let result = try routineCommand(operation, params)
                ?? sessionCommand(operation, params) ?? sessionStateCommand(operation, params)
                ?? questionCommand(method, params) else {
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

    private func routineCommand(_ method: ControlMethod, _ params: [String: Any]) throws -> Any? {
        switch method {
        case .routinesList: return routines.map(describe)
        case .routinesGet: return describe(try existing(params))
        case .routinesCreate: return describe(try create(params))
        case .routinesUpdate: return describe(try update(params))
        case .routinesSetEnabled: return describe(try enable(params))
        case .routinesRun: return try runNow(params)
        case .routinesStop: return try stopNow(params)
        case .routinesDelete: return try remove(params)
        default: return nil
        }
    }

    private func sessionCommand(_ method: ControlMethod, _ params: [String: Any]) throws -> Any? {
        switch method {
        case .sessionsList: return try sessions(params)
        case .sessionsRead: return try read(params)
        case .sessionsMessage: return try send(params)
        case .notify:
            let record = try notify(try value(params, "message", as: String.self),
                                    title: try optional(params, "title", as: String.self),
                                    session: try optional(params, "session", as: String.self),
                                    routineID: try optional(params, "routine", as: String.self),
                                    needsReply: try optional(params, "needsReply", as: Bool.self) ?? false)
            return record.map(describe) ?? ["notified": true]
        default: return nil
        }
    }

    private func sessionStateCommand(_ method: ControlMethod, _ params: [String: Any]) throws -> Any? {
        switch method {
        case .sessionsGet: return describe(try session(params))
        case .sessionsDelete:
            _ = try value(params, "session", as: String.self)
            let record = try session(params)
            guard deleteSession(record) else { throw ControlError(lastError ?? "Could not delete the session.") }
            return ["deleted": record.id.uuidString]
        case .sessionsMarkRead:
            let record = try session(params)
            markRead(record)
            return describe(current(record.id, routineID: record.routineID) ?? record)
        case .sessionsQuestions:
            return try questionList(session(params))
        case .sessionsAnswer:
            let record = try session(params)
            let id = try value(params, "question", as: String.self)
            let action = try value(params, "action", as: String.self)
            let values = try optional(params, "values", as: [String: [String]].self) ?? [:]
            try answerQuestion(id, on: record, answer: QuestionAnswer(action: action, values: values))
            return describe(current(record.id, routineID: record.routineID) ?? record)
        case .sessionsDismiss:
            let record = try session(params)
            guard record.questions?.isEmpty != false else {
                throw ControlError("Answer or cancel the pending questions before dismissing attention.")
            }
            dismissAttention(record)
            return describe(current(record.id, routineID: record.routineID) ?? record)
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
        guard save(routine) else { throw ControlError(lastError ?? "Could not save the routine.") }
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
        guard save(routine) else { throw ControlError(lastError ?? "Could not save the routine.") }
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
        guard setEnabled(try value(params, "enabled", as: Bool.self), for: routine.id) else {
            throw ControlError(lastError ?? "Could not save the routine.")
        }
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
        guard delete(routine.id) else { throw ControlError(lastError ?? "Could not delete the routine.") }
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

    func session(_ params: [String: Any]) throws -> RunRecord {
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

    private func questionList(_ record: RunRecord) throws -> Any {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(record.questions ?? []))
    }

    private func send(_ params: [String: Any]) throws -> [String: Any] {
        let record = try session(params)
        let text = try value(params, "text", as: String.self)
        guard canMessage(record) else {
            throw ControlError(record.harness.isAgent ? "That session cannot take a message now."
                               : "A shell session takes no messages.")
        }
        let paths = try optional(params, "attachments", as: [String].self) ?? []
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !paths.isEmpty else {
            throw ControlError("Give a message or attach a file.")
        }
        guard !record.hasBlockingQuestion else {
            throw ControlError("Answer the blocking question before sending a message.")
        }
        guard paths.isEmpty else { throw ControlError("Attachments require the asynchronous control request handler.") }
        guard message(text, to: record) else {
            throw ControlError(lastError ?? "The session did not accept the message.")
        }
        return describe(active[record.routineID] ?? record)
    }

    /// The last `characters` of a text file and whether anything came before them.
    static func tail(of path: String, characters: Int) -> (String, Bool) {
        guard let file = FileHandle(forReadingAtPath: path) else { return ("", false) }
        defer { try? file.close() }
        let size = (try? file.seekToEnd()) ?? 0
        // UTF-8 takes up to four bytes a character.
        let limit = max(characters, 0)
        let start = UInt64(limit) < size / 4 ? size - UInt64(limit) * 4 : 0
        try? file.seek(toOffset: start)
        let text = lossyUTF8(file.readDataToEndOfFile())
        return (String(text.suffix(limit)), start > 0 || text.count > limit)
    }

    func describe(_ record: RunRecord) -> [String: Any] {
        var json: [String: Any] = ["session": record.id.uuidString, "routine": record.routineID,
                                   "harness": record.harness.rawValue, "trigger": record.trigger.rawValue,
                                   "startedAt": Self.timestamp.string(from: record.startedAt),
                                   "outcome": record.outcome.title, "running": isActive(record)]
        if isActive(record), let state = record.terminalState { json["terminalState"] = state.rawValue }
        if let ended = record.endedAt { json["endedAt"] = Self.timestamp.string(from: ended) }
        json["model"] = record.reportedModel ?? record.model
        json["effort"] = record.reportedEffort ?? record.effort
        json["executablePath"] = record.executablePath
        json["cliVersion"] = record.cliVersion
        json["serverVersion"] = record.serverVersion
        json["compatibilityNotice"] = record.compatibilityNotice
        json["needsReconciliation"] = record.needsReconciliation == true
        if let mode = record.launchMode { json["launchMode"] = mode.name }
        json["unread"] = record.isUnread
        json["canMessage"] = canMessage(record) && !record.hasBlockingQuestion
        json["canDelete"] = canDelete(record)
        json["questions"] = try? questionList(record)
        if let attention = record.attention { json["needsReply"] = attention }
        return json
    }

    // MARK: Parameters

    func value<T>(_ params: [String: Any], _ key: String, as type: T.Type) throws -> T {
        guard let value = try optional(params, key, as: type) else { throw ControlError("Missing \(key).") }
        return value
    }

    func optional<T>(_ params: [String: Any], _ key: String, as type: T.Type) throws -> T? {
        guard let raw = params[key], !(raw is NSNull) else { return nil }
        if T.self == Bool.self, let number = raw as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
            return number.boolValue as? T
        }
        if T.self == Int.self, let number = raw as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
           NSNumber(value: number.intValue).compare(number) == .orderedSame {
            return number.intValue as? T
        }
        if let typed = raw as? T, T.self != Int.self, T.self != Bool.self { return typed }
        let expected = T.self == Int.self ? "a number (an integer in range)"
            : T.self == Bool.self ? "true or false" : "text"
        throw ControlError("\(key) should be \(expected).")
    }
}
