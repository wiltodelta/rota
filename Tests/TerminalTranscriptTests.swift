@testable import RotaCore
import XCTest

final class TerminalTranscriptTests: XCTestCase {
    func testCheckpointSkipsHistoryAndWaitsForCompleteUTF8Line() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("updates.jsonl")
        let old = try JSONSerialization.data(withJSONObject: grok("agent_message_chunk", text: "Old answer"))
        try (old + Data([10])).write(to: url)
        var reader = try NativeTranscript(url: url, harness: .grok)
        XCTAssertEqual(try reader.read(), [])
        let line = try JSONSerialization.data(withJSONObject: grok("agent_message_chunk", text: "Привет"))
        let writer = try FileHandle(forWritingTo: url)
        defer { try? writer.close() }
        try writer.seekToEnd()
        // Split inside a Cyrillic UTF-8 sequence, before the terminating newline.
        let split = try XCTUnwrap(line.firstIndex(of: 0xD0)) + 1
        try writer.write(contentsOf: line.prefix(split))
        XCTAssertEqual(try reader.read(), [])
        try writer.write(contentsOf: line.suffix(from: split) + Data([10]))
        XCTAssertEqual(try reader.read(), [.chunk("Привет")])
        XCTAssertEqual(try reader.read(), [])
        try writer.truncate(atOffset: 0)
        XCTAssertThrowsError(try reader.read())
    }

    func testCodexUsesUserEventsAndAssistantItemsWithoutDuplicatingOrLeakingInstructions() throws {
        let ignored: [[String: Any]] = [
            ["type": "response_item", "payload": ["type": "message", "role": "user",
                "content": [["type": "input_text", "text": "Private injected instructions"]]]],
            ["type": "event_msg", "payload": ["type": "item_completed", "item": [
                "type": "AgentMessage", "content": [["type": "Text", "text": "Duplicate"]]]]]
        ]
        for entry in ignored { XCTAssertEqual(try events(entry, .codex), []) }
        XCTAssertEqual(try events(["type": "event_msg", "payload": ["type": "item_completed", "item": [
            "type": "UserMessage", "content": [["type": "text", "text": "Next question"]]]]], .codex),
                       [.item(.user, "Next question")])
        XCTAssertEqual(try events(["type": "response_item", "payload": ["type": "message", "role": "assistant",
            "content": [["type": "output_text", "text": "Answer"]]]], .codex), [.item(.agent, "Answer")])
        XCTAssertEqual(try events(["type": "event_msg", "payload": ["type": "task_started"]], .codex),
                       [.state(.working)])
        XCTAssertEqual(try events(["type": "event_msg", "payload": ["type": "task_complete",
            "last_agent_message": "Duplicate"]], .codex), [.state(.waiting)])
    }

    func testClaudeAndGrokTurnBoundaries() throws {
        XCTAssertEqual(try events(["type": "user", "message": ["content": "Next"]], .claude),
                       [.item(.user, "Next"), .state(.working)])
        XCTAssertEqual(try events(["type": "user", "isMeta": true, "message": ["content": "Hidden"]], .claude), [])
        let answer: [String: Any] = ["type": "assistant", "message": ["role": "assistant", "model": "sample",
            "content": [["type": "text", "text": "Answer"]], "stop_reason": "end_turn"]]
        XCTAssertEqual(try events(answer, .claude), [.configuration(.init(model: "sample")),
                                                   .item(.agent, "Answer"), .state(.waiting)])
        XCTAssertEqual(try events(grok("user_message_chunk", text: "Next"), .grok),
                       [.configuration(.init()), .item(.user, "Next"), .state(.working)])
        XCTAssertEqual(try events(grok("turn_completed", method: "_x.ai/session/update"), .grok), [.state(.waiting)])
        XCTAssertEqual(try events(grok("hook_execution", method: "_x.ai/session/update"), .grok), [])
    }

    func testGrokResumeUsesTheArchiveDirectoryIncludingLongPathGroups() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let group = folder.appendingPathComponent("%2Factual%2Fproject")
        let source = group.appendingPathComponent("session/updates.jsonl")
        try FileManager.default.createDirectory(at: group, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertEqual(NativeTranscript.grokDirectory(source), "/actual/project")
        try "/actual/long project\n".write(to: group.appendingPathComponent(".cwd"),
                                          atomically: true, encoding: .utf8)
        XCTAssertEqual(NativeTranscript.grokDirectory(source), "/actual/long project")
    }

    private func grok(_ type: String, text: String = "", method: String = "session/update") -> [String: Any] {
        ["method": method, "params": ["update": ["sessionUpdate": type,
            "content": ["type": "text", "text": text]]]]
    }

    private func events(_ entry: [String: Any], _ harness: Harness) throws -> [NativeTranscript.Event] {
        try NativeTranscript.events(JSONSerialization.data(withJSONObject: entry), harness: harness)
    }
}
