import Foundation

public struct Routine: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var workingDirectory: String
    public var schedule: String
    public var harness: Harness
    public var enabled: Bool
    public var prompt: String
    /// Stops a run that takes longer; nil lets every run take as long as it needs.
    public var timeLimitMinutes: Int?
    /// The model id to run on; nil leaves the harness's own default.
    public var model: String?
    /// The reasoning effort; nil leaves the model's default.
    public var effort: String?
    /// The next slot the scheduler will fire; nil while disabled.
    public var nextFire: Date?
    /// Stable source identity, independent of the editable display name and local id.
    public var importIdentity: String?

    public init(id: String, name: String, workingDirectory: String, schedule: String,
                harness: Harness = .claude, enabled: Bool = false, prompt: String,
                timeLimitMinutes: Int? = nil, nextFire: Date? = nil, model: String? = nil, effort: String? = nil) {
        self.id = id
        self.name = name
        self.workingDirectory = workingDirectory
        self.schedule = schedule
        self.harness = harness
        self.enabled = enabled
        self.prompt = prompt
        self.timeLimitMinutes = timeLimitMinutes
        self.nextFire = nextFire
        self.model = model
        self.effort = effort
    }

    /// 0.1 saved `timeoutMinutes`, 60 unless changed. Its 60 was a default
    /// nobody chose, so it loads as no limit; any other value was picked and stays.
    private enum LegacyKeys: String, CodingKey { case timeoutMinutes }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        workingDirectory = try values.decode(String.self, forKey: .workingDirectory)
        schedule = try values.decode(String.self, forKey: .schedule)
        harness = try values.decode(Harness.self, forKey: .harness)
        enabled = try values.decode(Bool.self, forKey: .enabled)
        prompt = try values.decode(String.self, forKey: .prompt)
        nextFire = try values.decodeIfPresent(Date.self, forKey: .nextFire)
        importIdentity = try values.decodeIfPresent(String.self, forKey: .importIdentity)
        model = try values.decodeIfPresent(String.self, forKey: .model)
        effort = try values.decodeIfPresent(String.self, forKey: .effort)
        let legacy = try decoder.container(keyedBy: LegacyKeys.self)
            .decodeIfPresent(Int.self, forKey: .timeoutMinutes)
        timeLimitMinutes = try values.decodeIfPresent(Int.self, forKey: .timeLimitMinutes)
            ?? legacy.flatMap { $0 == 60 ? nil : $0 }
    }

    /// The handoff Claude Desktop stubs carry, for a routine created by hand.
    public static func defaultPrompt(skill: String, workingDirectory: String) -> String {
        """
        Invoke the `\(skill)` skill from this session's working directory, \
        `\(workingDirectory)`, and follow it exactly. Its canonical body is \
        `.claude/skills/\(skill)/SKILL.md` in the repository; read it there.
        """
    }

    /// Lowercase letters, digits, - and _: an id names a file and a skill folder.
    public static func isValidID(_ id: String) -> Bool {
        let allowed = CharacterSet.lowercaseLetters.union(.decimalDigits).union(CharacterSet(charactersIn: "-_"))
        return !id.isEmpty && id.unicodeScalars.allSatisfy { $0.isASCII && allowed.contains($0) }
    }

    /// Why the routine cannot be saved, or nil. The window, the `rota` command
    /// and the MCP tools share it; `checkingID` is off for an existing routine,
    /// which keeps the id it was imported with.
    public func problem(checkingID: Bool = true) -> String? {
        if checkingID, id.isEmpty { return "Give the routine an id, such as weekly-report." }
        if checkingID, !Self.isValidID(id) {
            return "An id is lowercase letters, digits, - and _, such as weekly-report."
        }
        var isFolder: ObjCBool = false
        guard FileManager.default.fileExists(atPath: workingDirectory, isDirectory: &isFolder), isFolder.boolValue
        else {
            return workingDirectory.isEmpty ? "Choose the project folder."
                : "The project folder \(workingDirectory) does not exist."
        }
        do { _ = try CronSchedule(schedule) } catch {
            return "The schedule \"\(schedule)\": \(error.localizedDescription)"
        }
        guard !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return harness.isAgent ? "Give a prompt or a skill." : "Give the command."
        }
        if let limit = timeLimitMinutes, !(1...1440).contains(limit) {
            return "A time limit is 1 to 1440 minutes, or none."
        }
        return nil
    }
}
