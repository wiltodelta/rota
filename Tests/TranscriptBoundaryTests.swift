import Foundation
@testable import RotaCore
import XCTest

final class TranscriptBoundaryTests: XCTestCase {
    private func fixture(_ mode: LaunchMode) throws -> (LaunchSpec, RunJournal) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let log = folder.appendingPathComponent("session.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let spec = LaunchSpec(executable: "/bin/false", prompt: "Inspect", arguments: [],
                              workingDirectory: folder.path, environment: ["HOME": folder.path],
                              mode: mode, timeout: nil, log: log)
        return (spec, RunJournal(output: try FileHandle(forWritingTo: log),
                                events: RunEvents(session: { _ in }, finished: { _ in }),
                                transcript: try TranscriptJournal(log: log, resuming: false, logSize: 0)))
    }

    private func snapshot(_ spec: LaunchSpec, _ journal: RunJournal) -> [TranscriptItem] {
        journal.finish(.succeeded)
        var reader = TranscriptReader()
        return reader.read(log: spec.log, finished: true).items.filter { $0.kind != .status }
    }

    func testClaudeConsecutiveTextBlocksAndMessagesStaySeparate() throws {
        let (spec, journal) = try fixture(.claudeStream)
        let run = ClaudeStreamRun(spec: spec, journal: journal)
        for text in ["First answer.", "Second answer."] {
            for event: [String: Any] in [
                ["type": "content_block_start", "index": 0, "content_block": ["type": "text", "text": ""]],
                ["type": "content_block_delta", "index": 0, "delta": ["type": "text_delta", "text": text]],
                ["type": "content_block_stop", "index": 0]
            ] {
                let data = try JSONSerialization.data(withJSONObject: ["type": "stream_event", "event": event])
                run.handle(try XCTUnwrap(String(data: data, encoding: .utf8)))
            }
            let completed = try JSONSerialization.data(withJSONObject: ["type": "assistant",
                "message": ["content": [["type": "text", "text": text]]]])
            run.handle(try XCTUnwrap(String(data: completed, encoding: .utf8)))
        }
        XCTAssertEqual(snapshot(spec, journal).map(\.text), ["First answer.", "Second answer."])
    }

    func testGrokTerminalKeepsDistinctStreamIdentities() throws {
        let (spec, journal) = try fixture(.grokACP)
        for (index, text) in ["First answer.", "Second answer."].enumerated() {
            let row: [String: Any] = ["method": "session/update", "params": [
                "sessionId": "session", "_meta": ["promptId": "prompt", "streamStartMs": index + 1],
                "update": ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": text]]]]
            // TerminalRun consumes these events. Exercise the actual reader and journal together.
            for event in try NativeTranscript.events(JSONSerialization.data(withJSONObject: row), harness: .grok) {
                if case .chunk(let chunk, let kind, let nativeID) = event {
                    journal.text(chunk, kind: kind, nativeID: nativeID)
                }
            }
        }
        XCTAssertEqual(snapshot(spec, journal).map(\.text), ["First answer.", "Second answer."])
    }

    func testAntigravityLateReasoningCannotSplitAWordOrMergeReplies() throws {
        let (spec, journal) = try fixture(.antigravityStream)
        let run = AntigravityRun(spec: spec, journal: journal)
        let session = UUID().uuidString
        func emit(_ value: [String: Any]) throws {
            run.handle(try JSONSerialization.data(withJSONObject: value))
        }
        func delta(_ text: String, step: Int, done: Bool) throws {
            try emit(["event": "step_update", "step_update": ["step_type": "agent_response",
                "step_index": step, "state": done ? "DONE" : "ACTIVE", "text_delta": text]])
        }
        try emit(["event": "init", "conversation_id": session, "init": [:]])
        try delta("оста", step: 1, done: false)
        let archive = try XCTUnwrap(AntigravityQuestionArchive(session: session,
            home: URL(fileURLWithPath: spec.workingDirectory)))
        try FileManager.default.createDirectory(at: archive.file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let row: [String: Any] = ["type": "PLANNER_RESPONSE", "status": "DONE", "step_index": 1,
                                  "thinking": "Exposed reasoning", "content": "остальных"]
        try (JSONSerialization.data(withJSONObject: row) + Data([10])).write(to: archive.file)
        try delta("льных", step: 1, done: false)
        try emit(["event": "step_update", "step_update": ["step_type": "agent_response",
            "step_index": 1, "state": "DONE"]])
        var reader = TranscriptReader()
        XCTAssertTrue(reader.read(log: spec.log, finished: false).items
            .first { $0.kind == .agent }?.isComplete == true)
        try delta("Next answer", step: 2, done: true)
        let items = snapshot(spec, journal)
        XCTAssertEqual(items.filter { $0.kind == .agent }.map(\.text), ["остальных", "Next answer"])
        XCTAssertEqual(items.filter { $0.kind == .reasoning }.map(\.text), ["Exposed reasoning"])
    }

    func testAntigravityToolReasoningAfterATextResponsePrecedesItsTool() throws {
        let (spec, journal) = try fixture(.antigravityStream)
        let run = AntigravityRun(spec: spec, journal: journal)
        let session = UUID().uuidString
        func emit(_ value: [String: Any]) throws { run.handle(try JSONSerialization.data(withJSONObject: value)) }
        try emit(["event": "init", "conversation_id": session, "init": [:]])
        try emit(["event": "step_update", "step_update": ["step_type": "agent_response", "step_index": 1,
            "state": "DONE", "text_delta": "First answer"]])
        let archive = try XCTUnwrap(AntigravityQuestionArchive(session: session,
            home: URL(fileURLWithPath: spec.workingDirectory)))
        try FileManager.default.createDirectory(at: archive.file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let row: [String: Any] = ["type": "PLANNER_RESPONSE", "status": "DONE", "step_index": 2,
                                  "thinking": "Inspecting next", "tool_calls": [["name": "Inspect"]]]
        try (JSONSerialization.data(withJSONObject: row) + Data([10])).write(to: archive.file)
        try emit(["event": "step_update", "step_update": ["step_type": "tool", "step_index": 3,
            "state": "ACTIVE", "tool_name": "Inspect"]])
        try emit(["event": "result", "result": ["status": "SUCCESS"]])
        XCTAssertEqual(snapshot(spec, journal).map(\.text), ["First answer", "Inspecting next", "Inspect"])
    }
}
