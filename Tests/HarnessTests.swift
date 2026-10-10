@testable import RotaCore
import XCTest

final class HarnessTests: XCTestCase {
    func testClaudeStreamArguments() {
        let plain = Harness.claude.arguments(needs: [])
        XCTAssertEqual(plain, ["-p", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
                               "--permission-mode", "bypassPermissions"])
        XCTAssertTrue(Harness.claude.environment(needs: []).isEmpty)
        XCTAssertEqual(Harness.claude.arguments(needs: [.chrome]).last, "--chrome")
        XCTAssertEqual(Array(Harness.claude.arguments(needs: [], resume: "s1").suffix(2)), ["--resume", "s1"])
        XCTAssertEqual(Harness.claude.environment(needs: [.chrome]), ["CLAUDE_CODE_ENABLE_CFC": "1"])
    }

    func testOnlyClaudeTakesCommandLineArguments() {
        for harness in [Harness.codex, .grok, .shell] {
            XCTAssertTrue(harness.arguments(needs: [.chrome]).isEmpty)
        }
        XCTAssertEqual(Harness.allCases.map(\.launchMode), [.claudeStream, .codexDaemon, .grokACP, .screen])
    }

    func testStreamJSONUserMessage() throws {
        let line = ClaudeStreamRun.userMessage("hi \"there\"")
        XCTAssertEqual(line.last, UInt8(ascii: "\n"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: line.dropLast()) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "user")
        let message = try XCTUnwrap(object["message"] as? [String: Any])
        let content = try XCTUnwrap(message["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["text"] as? String, "hi \"there\"")
    }

    func testTerminalCommandsWhileRunningAndAfter() {
        XCTAssertNil(Harness.claude.terminal(session: "s1", running: true), "Rota holds a running session")
        XCTAssertEqual(Harness.claude.terminal(session: "s1", running: false)?.arguments, ["--resume", "s1"])
        XCTAssertNil(Harness.codex.terminal(session: "t1", running: true))
        XCTAssertEqual(Harness.codex.terminal(session: "t1", running: false)?.arguments, ["resume", "t1"])
        XCTAssertNil(Harness.grok.terminal(session: "g1", running: true))
        XCTAssertEqual(Harness.grok.terminal(session: "g1", running: false)?.arguments, ["--resume", "g1"])
        XCTAssertEqual(Harness.shell.terminal(session: "rota-1", running: true)?.executable, "/usr/bin/screen")
        XCTAssertNil(Harness.shell.terminal(session: "rota-1", running: false))
    }

    func testWhoTakesMessagesInRota() {
        XCTAssertTrue(Harness.claude.takesMessages)
        XCTAssertTrue(Harness.codex.takesMessages)
        XCTAssertTrue(Harness.grok.takesMessages)
        XCTAssertFalse(Harness.shell.takesMessages)
    }

    func testScanFindsEachMarker() {
        XCTAssertEqual(SkillRequirements.scan("call mcp__claude-in-chrome__navigate"), [.chrome])
        XCTAssertEqual(SkillRequirements.scan("open it in Claude in Chrome"), [.chrome])
        XCTAssertEqual(SkillRequirements.scan("the Chrome MCP tab"), [.chrome])
        XCTAssertEqual(SkillRequirements.scan("then PushNotification"), [.push])
        XCTAssertEqual(SkillRequirements.scan("read the repo with Playwright"), [])
    }

    func testGapsPerHarness() {
        let both: Set<Capability> = [.chrome, .push]
        XCTAssertTrue(SkillRequirements.gaps(both, on: .claude).isEmpty)
        let codex = SkillRequirements.gaps(both, on: .codex)
        XCTAssertEqual(codex.map(\.0), [.chrome, .push])
        if case .differentTools = codex[0].1 {} else { XCTFail("Codex has Chrome under other tool names") }
        XCTAssertEqual(codex[1].1, .missing)
        XCTAssertEqual(SkillRequirements.gaps(both, on: .grok).map(\.1), [.missing, .missing])
        XCTAssertEqual(SkillRequirements.gaps(both, on: .shell).map(\.1), [.missing, .missing])
        XCTAssertTrue(SkillRequirements.gaps([], on: .grok).isEmpty)
    }

    func testDefaultExecutablesLiveUnderHome() {
        let home = URL(fileURLWithPath: "/Users/someone")
        XCTAssertEqual(Harness.claude.defaultExecutable(home: home), "/Users/someone/.local/bin/claude")
        XCTAssertEqual(Harness.grok.defaultExecutable(home: home), "/Users/someone/.local/bin/grok")
    }
}

final class TranscriptTests: XCTestCase {
    /// Only the header lines runners write are dropped; text that merely looks like one stays.
    func testTextThatLooksLikeAHeaderIsKept() {
        let agent = Transcript.parse("note: the report is late")
        XCTAssertEqual(agent.map(\.kind), [.agent])
        let output = Transcript.parse("$ make\nbuilt", shell: true)
        XCTAssertEqual(output.map(\.text), ["$ make\nbuilt"])
    }

    func testLogBecomesChatItems() {
        let log = """
            [you] Run the weekly check.
            [you] Then report.
            [codex thread 01a1]
            Starting.
            -> $ ls
            Found three files.
            They look fine.

            Second message.
            [rota: Succeeded after 20 s]
            [error] quota low
            """
        let items = Transcript.parse(log)
        XCTAssertEqual(items.map(\.kind), [.user, .agent, .tool, .agent, .agent, .status, .error])
        XCTAssertEqual(items[0].text, "Run the weekly check.\nThen report.")
        XCTAssertEqual(items[3].text, "Found three files.\nThey look fine.")
        XCTAssertEqual(items[5].text, "Succeeded after 20 s")
        XCTAssertEqual(items.map(\.id), Array(0..<7))
    }

    func testDurationsReadInMinutes() {
        XCTAssertEqual(Transcript.readableDurations("Succeeded after 412 s"), "Succeeded after 6 min 52 s")
        XCTAssertEqual(Transcript.readableDurations("Succeeded after 120 s"), "Succeeded after 2 min")
        XCTAssertEqual(Transcript.readableDurations("Succeeded after 3700 s"), "Succeeded after 1 h 1 min")
        XCTAssertEqual(Transcript.readableDurations("Succeeded after 9 s"), "Succeeded after 9 s")
        XCTAssertEqual(Transcript.parse("[result: success, 4 s, 2 turns]").first?.text, "success, 4 s, 2 turns")
    }

    func testUserLinesRoundTrip() {
        let message = "line one\nline two"
        XCTAssertEqual(Transcript.parse(Transcript.userLines(message)).map(\.text), [message])
    }

    func testShellOutputIsOneBlock() {
        let items = Transcript.parse("[you] make test\nok 1\nok 2\n[rota: Succeeded after 1 s]", shell: true)
        XCTAssertEqual(items.map(\.kind), [.user, .output, .status])
        XCTAssertEqual(items[1].text, "ok 1\nok 2")
    }
}

final class StreamJSONFormatterTests: XCTestCase {
    func testSessionStart() {
        XCTAssertEqual(StreamJSONFormatter.format(#"{"type":"system","subtype":"init","model":"m1"}"#),
                       "[session started, m1]")
        XCTAssertNil(StreamJSONFormatter.format(#"{"type":"system","subtype":"hook"}"#))
    }

    func testAssistantTextAndToolUse() {
        let line = #"""
        {"type":"assistant","message":{"content":[{"type":"text","text":"Reading"},\#
        {"type":"tool_use","name":"Bash","input":{"command":"ls\n-la"}}]}}
        """#
        XCTAssertEqual(StreamJSONFormatter.format(line), "Reading\n-> Bash ls -la")
    }

    func testResult() {
        let line = #"{"type":"result","subtype":"success","duration_ms":12400,"num_turns":3,"result":"Done."}"#
        XCTAssertEqual(StreamJSONFormatter.format(line), "[result: success, 12 s, 3 turns]\nDone.")
    }

    func testUserEventsAreDroppedAndNonJSONPassesThrough() {
        XCTAssertNil(StreamJSONFormatter.format(#"{"type":"user","message":{}}"#))
        XCTAssertEqual(StreamJSONFormatter.format("zsh: command not found"), "zsh: command not found")
        XCTAssertNil(StreamJSONFormatter.format("   "))
    }
}
