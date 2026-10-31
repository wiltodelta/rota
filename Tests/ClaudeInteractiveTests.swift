@testable import RotaCore
import XCTest

/// The interactive Claude run's pure parts: its transcript, its command line, and when Rota uses it.
final class ClaudeInteractiveTests: XCTestCase {
    private func entry(_ json: [String: Any]) -> ClaudeTranscript {
        // A fixture that does not serialize reads as nothing, and its assertion fails.
        ClaudeTranscript.read((try? JSONSerialization.data(withJSONObject: json)) ?? Data())
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
                       .assistant(model: "claude-haiku-5-5", items: [
                        TranscriptItem(id: 0, kind: .agent, text: "Looking."),
                        TranscriptItem(id: 1, kind: .tool, text: "Bash ls")]))
        XCTAssertEqual(entry(["type": "assistant", "isApiErrorMessage": true, "message": [
            "model": "<synthetic>", "content": [["type": "text", "text": "API Error: overloaded"]]]]),
                       .apiError("API Error: overloaded"))
        XCTAssertEqual(entry(["type": "system", "subtype": "turn_duration", "durationMs": 4000]), .turnEnded)
        XCTAssertEqual(entry(["type": "system", "subtype": "stop_hook_summary"]), .other)
        XCTAssertEqual(ClaudeTranscript.read(Data("not json".utf8)), .other)
    }

    /// Shapes as Claude Code 2.1.310 wrote them in interactive sessions in October 2026.
    func testBackgroundTasksStartAndEnd() {
        XCTAssertEqual(entry(["type": "user", "toolUseResult": ["backgroundTaskId": "b1", "stdout": ""],
                              "message": ["content": [["type": "tool_result", "content": "running"]]]]),
                       .background("b1", running: true))
        XCTAssertEqual(entry(["type": "user", "toolUseResult": ["isAsync": true, "status": "async_launched",
                                                                "agentId": "a1", "description": "Review"]]),
                       .background("a1", running: true))
        XCTAssertEqual(entry(["type": "user", "toolUseResult": [
            "message": "Successfully stopped task: b1 (sleep 60)", "task_id": "b1", "task_type": "local_bash"]]),
                       .background("b1", running: false))
        let notice = "<task-notification>\n<task-id>a1</task-id>\n<task-id>a2</task-id>\n"
            + "<status>completed</status>\n</task-notification>"
        XCTAssertEqual(TranscriptService.taskIDs(notice), ["a1", "a2"])
        XCTAssertEqual(entry(["type": "user", "origin": ["kind": "task-notification"],
                              "message": ["content": notice]]), .service(notice))
        XCTAssertEqual(entry(["type": "attachment", "attachment": ["type": "queued_command", "prompt": notice]]),
                       .service(notice), "a notification queued mid-turn is not a typed message")
    }

    func testScreenPIDComesFromTheMatchingSessionOnly() {
        let list = "There are screens on:\n\t63754.rota-claude-060c03c9\t(Detached)\n"
            + "\t811.rota-claude-060c03c9x\t(Detached)\n2 Sockets in /tmp/.screen.\n"
        XCTAssertEqual(ScreenRun.pid("rota-claude-060c03c9", in: list), 63754)
        XCTAssertNil(ScreenRun.pid("rota-claude-ffffffff", in: list))
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

    func testDialogHookAppendsClaudesPayloadToTheRunsFile() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = try ClaudeRunSettings.hooks(in: folder)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        let notification = try XCTUnwrap((json["hooks"] as? [String: Any])?["Notification"] as? [[String: Any]])
        XCTAssertEqual(notification.first?["matcher"] as? String,
                       "permission_prompt|elicitation_dialog|elicitation_url_dialog|agent_needs_input")
        let command = try XCTUnwrap((notification.first?["hooks"] as? [[String: Any]])?.first?["command"] as? String)
        let payload = #"{"hook_event_name":"Notification","message":"Claude needs your permission"}"#
        let dialogs = folder.appendingPathComponent("run.dialog")
        func run(_ environment: [String: String]) throws -> Int32 {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", command]
            process.environment = environment
            let input = Pipe()
            process.standardInput = input
            try process.run()
            // Without a destination the hook exits immediately and never reads stdin.
            if environment["ROTA_SESSION_DIALOG"] != nil {
                try input.fileHandleForWriting.write(contentsOf: Data(payload.utf8))
            }
            try input.fileHandleForWriting.close()
            process.waitUntilExit()
            return process.terminationStatus
        }
        XCTAssertEqual(try run([:]), 0, "print mode sets no file, and the hook does nothing")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dialogs.path))
        for _ in 0..<2 { XCTAssertEqual(try run(["ROTA_SESSION_DIALOG": dialogs.path]), 0) }
        XCTAssertEqual(try String(contentsOf: dialogs, encoding: .utf8), payload + "\n" + payload + "\n")
    }

    /// Bytes as `screen` 4.00.03 hardcopied Claude Code 2.1.311's permission dialog on
    /// 2026-10-27: `─` reads as NUL, `╌` as `L`, `❯` as `o`, `·` as 0x14; the path is neutral.
    private func screen(_ lines: [String]) -> Data {
        Data(lines.joined(separator: "\n").utf8.map { $0 == UInt8(ascii: "~") ? 0x14 : $0 }
             + [0x0A] + [UInt8](repeating: 0, count: 80))
    }

    private let permissionDialog = [
        "o Run touch probe-file.txt", "", " Bash command", " Create empty probe file",
        String(repeating: "L", count: 80), " touch probe-file.txt", String(repeating: "L", count: 80),
        " Do you want to proceed?", " o 1. Yes", "   2. Yes, and always allow access to",
        "      /tmp/work from this project",
        "   3. Yes, and switch to auto mode ~ auto mode handles these prompts for you", "   4. No", "",
        " Esc to cancel ~ Tab to amend"]

    func testDialogIsReadOffTheScreen() throws {
        let dialog = try XCTUnwrap(ClaudeDialog.read(screen: screen(permissionDialog)))
        XCTAssertEqual(dialog.prompt, ["Do you want to proceed?"])
        XCTAssertEqual(dialog.options, ["Yes", "Yes, and always allow access to /tmp/work from this project",
                                        "Yes, and switch to auto mode auto mode handles these prompts for you", "No"])
        XCTAssertEqual(dialog.key(for: "No"), "4")
        XCTAssertEqual(dialog.key(for: "cancel"), "\u{1B}")
        XCTAssertNil(dialog.key(for: "Maybe"))
        let question = ClaudeDialog.question(for: dialog, title: "Claude needs your permission", tool: "Bash\n{}")
        XCTAssertEqual(question.detail, "Do you want to proceed?")
        XCTAssertEqual(question.context, "Bash\n{}")
        XCTAssertEqual(question.actions.map(\.id), dialog.options)
        XCTAssertNoThrow(try question.validate(QuestionAnswer(action: "Yes")))
    }

    func testANumberedAnswerIsNotADialog() {
        let answer = ["Steps:", "  1. Build", "  2. Test", "", "o ", "  ? for shortcuts"]
        XCTAssertNil(ClaudeDialog.read(screen: screen(answer)), "no option is marked as selected")
        let passed = permissionDialog + ["", "o Done.", "", "  1. Build", "  2. Test", "", "o ", "  status"]
        XCTAssertNil(ClaudeDialog.read(screen: screen(passed)), "a dialog Claude has left scrolls up")
        XCTAssertNil(ClaudeDialog.read(screen: screen(Array(permissionDialog.prefix(9)) + ["", "o ", "a", "b", "c"])),
                     "one option is no choice")
        XCTAssertNil(ClaudeDialog.read(screen: screen([" o 1. Yes", "   3. No"])), "options number from 1 in order")
    }

    func testDialogFileLines() throws {
        XCTAssertEqual(ClaudeDialog.event(#"{"hook_event_name":"Notification","message":"Session paused"}"#),
                       .shown(message: "Session paused"))
        XCTAssertEqual(ClaudeDialog.event(#"{"hook_event_name":"Stop"}"#), nil)
        XCTAssertEqual(ClaudeDialog.event("not json"), nil)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        ClaudeDialog.appendQuestionMarker(open: true, to: file.path)
        ClaudeDialog.appendQuestionMarker(open: false, to: file.path)
        ClaudeDialog.appendQuestionMarker(open: true, to: nil)
        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.map { ClaudeDialog.event($0) },
                       [.question(pid: getpid(), open: true), .question(pid: getpid(), open: false)])
    }

    func testToolCallsStartAndEnd() {
        let started = ClaudeTranscript.toolCalls(["type": "assistant", "message": ["content": [
            ["type": "text", "text": "Opening."],
            ["type": "tool_use", "id": "t1", "name": "mcp__computer-use__request_access",
             "input": ["apps": ["Calculator"]]]]]])
        XCTAssertEqual(started.started.map(\.name), ["mcp__computer-use__request_access"])
        XCTAssertEqual(started.started.first?.input["apps"] as? [String], ["Calculator"])
        XCTAssertEqual(ClaudeTranscript.toolCalls(["type": "user", "message": ["content": [
            ["type": "tool_result", "tool_use_id": "t1", "content": "granted"]]]]).ended, ["t1"])
        XCTAssertTrue(ClaudeTranscript.toolCalls(["type": "system"]).started.isEmpty)
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
        for folder in [".git", "sub"] {
            try FileManager.default.createDirectory(at: repo.appendingPathComponent(folder),
                                                    withIntermediateDirectories: true)
        }
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
