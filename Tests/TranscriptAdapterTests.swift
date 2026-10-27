import Foundation
@testable import RotaCore
import XCTest

final class TranscriptAdapterTests: XCTestCase {
    private func fixture(_ mode: LaunchMode, finished: @escaping (RunOutcome) -> Void = { _ in }) throws
        -> (LaunchSpec, RunJournal) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let log = folder.appendingPathComponent("session.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let spec = LaunchSpec(executable: "/bin/false", prompt: "Inspect", arguments: [],
                              workingDirectory: folder.path, environment: [:], mode: mode, timeout: nil, log: log)
        let journal = RunJournal(output: try FileHandle(forWritingTo: log),
            events: RunEvents(session: { _ in }, finished: finished),
            transcript: try TranscriptJournal(log: log, resuming: false, logSize: 0))
        return (spec, journal)
    }

    private func snapshot(_ spec: LaunchSpec, journal: RunJournal) -> [TranscriptItem] {
        journal.finish(.succeeded)
        var reader = TranscriptReader()
        let result = reader.read(log: spec.log, finished: true)
        XCTAssertTrue(result.structured)
        XCTAssertNil(result.problem)
        return result.items.filter { $0.kind != .status }
    }

    func testClaudePartialReasoningDoesNotSuppressCompletedAnswer() throws {
        let (spec, journal) = try fixture(.claudeStream)
        let run = ClaudeStreamRun(spec: spec, journal: journal)
        run.handle(#"{"type":"stream_event","event":{"delta":{"thinking":"Visible reasoning"}}}"#)
        run.handle(#"""
            {"type":"assistant","message":{"content":[
              {"type":"thinking","thinking":"Visible reasoning"},
              {"type":"text","text":"Completed answer"}]}}
            """#)
        let items = snapshot(spec, journal: journal)
        XCTAssertEqual(items.map(\.kind), [.reasoning, .agent])
        XCTAssertEqual(items.map(\.text), ["Visible reasoning", "Completed answer"])
    }

    func testClaudePartialAnswerDoesNotSuppressCompletedReasoning() throws {
        let (spec, journal) = try fixture(.claudeStream)
        let run = ClaudeStreamRun(spec: spec, journal: journal)
        run.handle(#"{"type":"stream_event","event":{"delta":{"text":"Answer"}}}"#)
        run.handle(#"""
            {"type":"assistant","message":{"content":[
              {"type":"text","text":"Answer"},
              {"type":"thinking","thinking":"Exposed note"}]}}
            """#)
        let items = snapshot(spec, journal: journal)
        XCTAssertEqual(items.map(\.kind), [.agent, .reasoning])
        XCTAssertEqual(items.map(\.text), ["Answer", "Exposed note"])
    }

    func testEmptyClaudeDeltasDoNotSuppressCompletedText() throws {
        let (spec, journal) = try fixture(.claudeStream)
        let run = ClaudeStreamRun(spec: spec, journal: journal)
        run.handle(#"{"type":"stream_event","event":{"delta":{"text":""}}}"#)
        run.handle(#"{"type":"stream_event","event":{"delta":{"thinking":""}}}"#)
        run.handle(#"""
            {"type":"assistant","message":{"content":[
              {"type":"thinking","thinking":"Reasoning"},{"type":"text","text":"Answer"}]}}
            """#)
        let items = snapshot(spec, journal: journal)
        XCTAssertEqual(items.map(\.kind), [.reasoning, .agent])
        XCTAssertEqual(items.map(\.text), ["Reasoning", "Answer"])
    }

    func testGrokTerminalContinuationPreservesToolResults() throws {
        let data = Data(#"""
            {"method":"session/update","params":{"update":{"sessionUpdate":"tool_call_update",
              "toolCallId":"call","status":"completed","content":[
                {"type":"content","content":{"type":"text","text":"Tool output"}},
                {"type":"diff","path":"example.txt","oldText":"before","newText":"after"}]}}}
            """#.utf8)
        let events = try NativeTranscript.events(data, harness: .grok)
        XCTAssertTrue(events.contains(.item(.output, "Tool output")))
        XCTAssertTrue(events.contains(.item(.output, "example.txt\nBefore:\nbefore\nAfter:\nafter")))
    }

    func testGrokNewJournalKeepsThoughtsToolTextAndDiffs() throws {
        let ended = expectation(description: "synthetic Grok turn ended")
        let (spec, journal) = try fixture(.grokACP, finished: { _ in ended.fulfill() })
        let transport = HarnessPeer()
        transport.receive = { request in
            switch request["method"] as? String {
            case "initialize": transport.reply(request)
            case "session/new": transport.reply(request, result: ["sessionId": "session"])
            case "session/prompt":
                func emit(_ update: [String: Any], eventID: String = "other") {
                    transport.deliver(["method": "session/update",
                                       "params": ["sessionId": "session", "update": update,
                                                  "_meta": ["eventId": eventID]]])
                }
                emit(["sessionUpdate": "agent_thought_chunk", "content": ["type": "text", "text": "Reasoning"]])
                emit(["sessionUpdate": "tool_call", "toolCallId": "call", "title": "Inspect"])
                emit(["sessionUpdate": "tool_call_update", "toolCallId": "call", "status": "in_progress",
                      "content": [["type": "content", "content": ["type": "text", "text": "Initial output"]]]],
                     eventID: "progress")
                let completed: [String: Any] = [
                    "sessionUpdate": "tool_call_update", "toolCallId": "call", "status": "completed", "content": [
                    ["type": "content", "content": ["type": "text", "text": "Output"]],
                    ["type": "diff", "path": "example.txt", "oldText": "before", "newText": "after"]]]
                emit(completed, eventID: "completed")
                emit(completed, eventID: "completed")
                emit(["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": "Answer"]])
                transport.reply(request, result: ["stopReason": "end_turn"])
            default: break
            }
        }
        let run = GrokACPRun.start(spec, journal: journal, transport: transport)
        wait(for: [ended], timeout: 2)
        withExtendedLifetime(run) {}
        let items = snapshot(spec, journal: journal).filter { $0.kind != .user }
        XCTAssertEqual(items.map(\.kind), [.reasoning, .tool, .output, .output, .output, .agent])
        XCTAssertEqual(items.map(\.text), ["Reasoning", "Inspect", "Initial output", "Output",
                                          "example.txt\nBefore:\nbefore\nAfter:\nafter", "Answer"])
    }

    func testCodexNewJournalKeepsReasoningAnswerAndToolResultsOnce() throws {
        let (spec, journal) = try fixture(.codexDaemon)
        let run = CodexDaemonRun(spec: spec, journal: journal, peer: JSONRPCPeer(transport: HarnessPeer()))
        run.threadStarted(.success(["thread": ["id": "thread"]]))
        func emit(_ method: String, _ values: [String: Any]) {
            run.handle(method, values.merging(["threadId": "thread"]) { _, new in new })
        }
        emit("item/reasoning/summaryTextDelta", ["itemId": "thought", "delta": "Reasoning", "summaryIndex": 0])
        emit("item/completed", ["item": ["id": "thought", "type": "reasoning", "summary": ["Reasoning"]]])
        emit("item/started", ["item": ["id": "call", "type": "commandExecution", "command": "inspect"]])
        let output: [String: Any] = ["item": ["id": "call", "type": "commandExecution", "aggregatedOutput": "Output"]]
        emit("item/completed", output)
        emit("item/completed", output)
        emit("item/agentMessage/delta", ["itemId": "answer", "delta": "Answer"])
        emit("item/completed", ["item": ["id": "answer", "type": "agentMessage", "text": "Answer"]])
        let items = snapshot(spec, journal: journal)
        XCTAssertEqual(items.map(\.kind), [.reasoning, .tool, .output, .agent])
        XCTAssertEqual(items.map(\.text), ["Reasoning", "$ inspect", "Output", "Answer"])
    }

    func testInteractiveClaudeNewJournalKeepsReasoningAndToolResults() throws {
        let (spec, journal) = try fixture(.claudeInteractive)
        let run = ClaudeInteractiveRun(spec: spec, journal: journal, session: "synthetic",
                                       folder: spec.log.deletingLastPathComponent())
        for row in [
            #"""
            {"type":"assistant","message":{"content":[
              {"type":"thinking","thinking":"Reasoning"},{"type":"tool_use","name":"Inspect"}]}}
            """#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","content":"Output"}]}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"Answer"}]}}"#
        ] { run.handle(entry: Data(row.utf8)) }
        let items = snapshot(spec, journal: journal)
        XCTAssertEqual(items.map(\.kind), [.reasoning, .tool, .output, .agent])
        XCTAssertEqual(items.map(\.text), ["Reasoning", "Inspect", "Output", "Answer"])
    }

    func testAntigravityNewJournalReadsExposedReasoningFromItsArchive() throws {
        let ended = expectation(description: "synthetic Antigravity turn ended")
        var (spec, journal) = try fixture(.antigravityStream, finished: { _ in ended.fulfill() })
        let home = spec.log.deletingLastPathComponent()
        let session = UUID().uuidString
        let archive = try XCTUnwrap(AntigravityQuestionArchive(session: session, home: home))
        try FileManager.default.createDirectory(at: archive.file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let native = #"{"type":"PLANNER_RESPONSE","status":"DONE","step_index":1,"thinking":"Reasoning"}"# + "\n"
        try native.write(to: archive.file, atomically: true, encoding: .utf8)
        let peer = home.appendingPathComponent("peer")
        let script = """
        #!/bin/zsh
        IFS= read -r message
        printf '%s\\n' '{"event":"init","conversation_id":"\(session)","init":{}}'
        printf '%s\\n' '{"event":"step_update","step_update":{"step_type":"tool","step_index":2,"state":"ACTIVE","tool_name":"Inspect"}}'
        printf '%s\\n' '{"event":"step_update","step_update":{"step_type":"tool","step_index":2,"state":"DONE","tool_info":{"output":"Output"}}}'
        printf '%s\\n' '{"event":"result","result":{"status":"SUCCESS","response":"Answer"}}'
        """
        try script.write(to: peer, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: peer.path)
        spec.executable = peer.path
        spec.environment["HOME"] = home.path
        let run = try AntigravityRun.start(spec, journal: journal)
        defer { run.stop() }
        wait(for: [ended], timeout: 5)
        let items = snapshot(spec, journal: journal)
        XCTAssertEqual(items.map(\.kind), [.reasoning, .tool, .output, .agent],
                       "Already archived reasoning must be read before the following tool activity")
        XCTAssertEqual(items.filter { $0.kind == .reasoning }.map(\.text), ["Reasoning"])
        XCTAssertEqual(items.filter { $0.kind == .output }.map(\.text), ["Output"])
        XCTAssertEqual(items.filter { $0.kind == .agent }.map(\.text), ["Answer"])
    }
}
