@testable import RotaCore
import XCTest

/// The interactive Claude run's pure parts: its transcript, its command line, and when Rota uses it.
final class ClaudeInteractiveTests: XCTestCase {
    private func entry(_ json: [String: Any]) -> ClaudeTranscript {
        ClaudeTranscript.read(try! JSONSerialization.data(withJSONObject: json))
    }

    /// Shapes as Claude Code 2.1.296 wrote them in a live interactive session on 2026-10-11.
    func testTranscriptEntries() {
        XCTAssertEqual(entry(["type": "user", "message": ["role": "user", "content": "Check the site"]]),
                       .user("Check the site"))
        XCTAssertEqual(entry(["type": "user", "message": ["role": "user", "content": [
            ["type": "tool_result", "tool_use_id": "t1", "content": "ok"]]]]), .other, "a tool result is not typed")
        XCTAssertEqual(entry(["type": "user", "isMeta": true, "message": ["content": "caveat"]]), .other)
        XCTAssertEqual(entry(["type": "user", "message": ["content": "<command-name>/exit</command-name>"]]), .other)
        XCTAssertEqual(entry(["type": "attachment", "attachment": ["type": "queued_command",
                                                                   "prompt": "Also say EXTRA"]]),
                       .queued("Also say EXTRA"))
        XCTAssertEqual(entry(["type": "attachment", "attachment": ["type": "skill_listing"]]), .other)
        XCTAssertEqual(entry(["type": "assistant", "message": ["model": "claude-haiku-5-5", "content": [
            ["type": "text", "text": "Looking."], ["type": "tool_use", "name": "Bash", "input": ["command": "ls"]]]]]),
                       .assistant(model: "claude-haiku-5-5", text: "Looking.\n-> Bash ls"))
        XCTAssertEqual(entry(["type": "assistant", "isApiErrorMessage": true, "message": [
            "model": "<synthetic>", "content": [["type": "text", "text": "API Error: overloaded"]]]]),
                       .apiError("API Error: overloaded"))
        XCTAssertEqual(entry(["type": "system", "subtype": "turn_duration", "durationMs": 4000]), .turnEnded)
        XCTAssertEqual(entry(["type": "system", "subtype": "stop_hook_summary"]), .other)
        XCTAssertEqual(ClaudeTranscript.read(Data("not json".utf8)), .other)
    }

    func testCommandLine() {
        let new = ClaudeInteractiveRun.arguments(session: "s1", resume: false, settings: "/c/s.json",
                                                 model: ["--model", "haiku"], prompt: "-start with a dash")
        XCTAssertEqual(new, ["--session-id", "s1", "--settings", "/c/s.json", "--permission-mode",
                             "bypassPermissions", "--model", "haiku", "--", "-start with a dash"])
        let resumed = ClaudeInteractiveRun.arguments(session: "s1", resume: true, settings: "/c/s.json", model: [],
                                                     prompt: "next")
        XCTAssertEqual(Array(resumed.prefix(2)), ["--resume", "s1"])
        let script = ClaudeInteractiveRun.scriptText(executable: "/bin/claude", arguments: ["--", "it's"],
                                                     directory: "/p q", exitFile: URL(fileURLWithPath: "/x/e"))
        XCTAssertEqual(script, """
            cd '/p q' || { print -r -- 1 > '/x/e'; exit 1 }
            '/bin/claude' '--' 'it'\\''s'
            print -r -- $? > '/x/e'
            """)
    }

    func testHookMarksTheSessionThroughTheRunsCommand() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = try ClaudeInteractiveRun.hookSettings(in: folder)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let notification = try XCTUnwrap((json["hooks"] as? [String: Any])?["Notification"] as? [[String: Any]])
        XCTAssertEqual(notification.first?["matcher"] as? String, "permission_prompt|elicitation_dialog")
        let command = try XCTUnwrap((notification.first?["hooks"] as? [[String: Any]])?.first?["command"] as? String)
        XCTAssertTrue(command.contains(#""$ROTA_CLI" notify --needs-reply"#), command)
    }

    func testTheTranscriptIsFoundInWhicheverProjectFolderHasIt() throws {
        let projects = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = projects.appendingPathComponent("-private-tmp-work")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: projects.appendingPathComponent("-other"),
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: projects) }
        try Data().write(to: folder.appendingPathComponent("abc.jsonl"))
        XCTAssertEqual(ClaudeInteractiveRun.transcriptFile("abc", projects: projects)?.lastPathComponent, "abc.jsonl")
        XCTAssertNil(ClaudeInteractiveRun.transcriptFile("missing", projects: projects))
    }

    func testTrustIsTheFolderOrItsRepository() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .resolvingSymlinksInPath()
        let repo = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("plain"),
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let settings = ClaudeUserSettings(trustedProjects: [repo.path])
        XCTAssertTrue(settings.trusts(repo.path))
        XCTAssertTrue(settings.trusts(repo.appendingPathComponent("sub").path))
        XCTAssertFalse(settings.trusts(root.appendingPathComponent("plain").path))
        let file = root.appendingPathComponent("claude.json")
        try JSONSerialization.data(withJSONObject: ["projects": [repo.path: ["hasTrustDialogAccepted": true],
                                                                 root.path: ["hasTrustDialogAccepted": false]]])
            .write(to: file)
        XCTAssertEqual(ClaudeUserSettings.read(file).trustedProjects, [repo.path])
    }
}
