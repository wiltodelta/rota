import Foundation

public struct Routine: Codable, Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var workingDirectory: String
    public var schedule: String
    public var harness: Harness
    public var enabled: Bool
    public var prompt: String
    public var timeoutMinutes: Int
    /// The next slot the scheduler will fire; nil while disabled.
    public var nextFire: Date?

    public init(id: String, name: String, workingDirectory: String, schedule: String,
                harness: Harness = .claude, enabled: Bool = false, prompt: String,
                timeoutMinutes: Int = 60, nextFire: Date? = nil) {
        self.id = id
        self.name = name
        self.workingDirectory = workingDirectory
        self.schedule = schedule
        self.harness = harness
        self.enabled = enabled
        self.prompt = prompt
        self.timeoutMinutes = timeoutMinutes
        self.nextFire = nextFire
    }

    /// The handoff Claude Desktop stubs carry, for a routine created by hand.
    public static func defaultPrompt(skill: String, workingDirectory: String) -> String {
        """
        Invoke the `\(skill)` skill from this session's working directory, \
        `\(workingDirectory)`, and follow it exactly. Its canonical body is \
        `.claude/skills/\(skill)/SKILL.md` in the repository; read it there.
        """
    }

    /// The project skill this routine hands off to, when it follows the
    /// `.claude/skills/<id>/SKILL.md` convention.
    public var skillFile: URL {
        URL(fileURLWithPath: workingDirectory)
            .appendingPathComponent(".claude/skills/\(id)/SKILL.md")
    }
}

/// What a routine's skill depends on, read from the skill text.
public enum SkillRequirements {
    static let markers: [(Capability, [String])] = [
        (.chrome, ["mcp__claude-in-chrome__", "Claude in Chrome", "Chrome MCP"]),
        (.push, ["PushNotification"])
    ]

    public static func scan(_ text: String) -> Set<Capability> {
        Set(markers.filter { _, needles in needles.contains { text.contains($0) } }.map(\.0))
    }

    public static func scan(file: URL) -> Set<Capability> {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [] }
        return scan(text)
    }

    /// The capabilities `harness` cannot serve as the skill is written.
    public static func gaps(_ needs: Set<Capability>, on harness: Harness) -> [(Capability, CapabilitySupport)] {
        Capability.allCases.filter(needs.contains).compactMap { capability in
            let support = harness.support(for: capability)
            return support == .native ? nil : (capability, support)
        }
    }
}
