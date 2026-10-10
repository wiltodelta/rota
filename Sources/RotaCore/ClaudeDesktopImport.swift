import Foundation

/// Reads the routines Claude Desktop schedules, read-only: Claude Desktop owns
/// that file and rewrites it wholesale, so Rota never writes to it.
public enum ClaudeDesktopImport {
    public struct Candidate: Identifiable, Equatable, Sendable {
        public var routine: Routine
        /// Still enabled in Claude Desktop, so importing it enabled would fire it twice.
        public var enabledInClaudeDesktop: Bool
        public var id: String { routine.id }
    }

    struct Registration: Decodable {
        var id: String
        var displayName: String?
        var cronExpression: String?
        var enabled: Bool?
        var filePath: String?
        var cwd: String?
    }

    struct File: Decodable {
        var scheduledTasks: [Registration]
    }

    /// The most recently written `scheduled-tasks.json` under Claude Desktop's sessions folder.
    public static func locate(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        let root = home.appendingPathComponent("Library/Application Support/Claude/claude-code-sessions")
        guard let walker = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        var newest: (URL, Date)?
        for case let url as URL in walker where url.lastPathComponent == "scheduled-tasks.json" {
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if newest == nil || modified > newest!.1 { newest = (url, modified) }
        }
        return newest?.0
    }

    public static func candidates(from file: URL) throws -> [Candidate] {
        let registrations = try JSONDecoder().decode(File.self, from: Data(contentsOf: file)).scheduledTasks
        return registrations.compactMap { registration in
            guard let cron = registration.cronExpression, let cwd = registration.cwd else { return nil }
            let prompt = registration.filePath.flatMap(stubPrompt(at:))
                ?? Routine.defaultPrompt(skill: registration.id, workingDirectory: cwd)
            let routine = Routine(id: registration.id, name: registration.displayName ?? registration.id,
                                  workingDirectory: cwd, schedule: cron, prompt: prompt)
            return Candidate(routine: routine, enabledInClaudeDesktop: registration.enabled ?? false)
        }
    }

    /// The body of a registered stub, without its frontmatter.
    static func stubPrompt(at path: String) -> String? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        return stripFrontmatter(text)
    }

    static func stripFrontmatter(_ text: String) -> String? {
        var body = Substring(text)
        if body.hasPrefix("---\n"), let end = body.dropFirst(4).range(of: "\n---") {
            body = body[end.upperBound...]
        }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
