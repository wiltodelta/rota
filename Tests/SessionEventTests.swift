@testable import RotaCore
import XCTest

final class SessionEventTests: XCTestCase {
    private func event(_ payload: SessionEvent.Payload, turn: String = "turn-1") -> SessionEvent {
        SessionEvent(turnID: turn, payload: payload)
    }

    func testTextPrefixesCannotInventToolsOrUsersAndSteeringStaysInItsTurn() {
        var transcript = SessionTranscript()
        transcript.apply(event(.user(id: "u1", text: "Start", delivery: .accepted)))
        transcript.apply(event(.assistant(id: "a1", text: "-> a quotation\n[you] a quotation", phase: .work)))
        transcript.apply(event(.user(id: "u2", text: "Change direction", delivery: .pending)))
        transcript.apply(event(.assistant(id: "a2", text: "Final answer", phase: .answer)))
        let turns = TranscriptTurn.group(transcript.items)
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns[0].prompt?.text, "Start")
        XCTAssertEqual(turns[0].work.map(\.kind), [.agent, .user])
        XCTAssertEqual(turns[0].answer.map(\.text), ["Final answer"])
        XCTAssertEqual(turns[0].toolCount, 0)
    }

    func testLocalUserRowCannotConfirmDeliveryAndDuplicateTextsHaveIndependentIDs() {
        var transcript = SessionTranscript()
        transcript.apply(event(.user(id: "u1", text: "Same text", delivery: .pending)))
        transcript.apply(event(.user(id: "u2", text: "Same text", delivery: .pending)))
        XCTAssertEqual(transcript.items.map(\.delivery), [.pending, .pending])
        transcript.apply(event(.delivery(id: "u2", state: .failed("Turn changed"))))
        transcript.apply(event(.delivery(id: "u1", state: .accepted)))
        XCTAssertEqual(transcript.items.map(\.delivery), [.accepted, .failed("Turn changed")])
        XCTAssertEqual(transcript.items.map(\.sourceID), ["u1", "u2"])
    }

    func testStreamingSnapshotReplacesDeltasAndToolUpdatesKeepIdentityAndInput() {
        var transcript = SessionTranscript()
        transcript.apply(event(.delta(id: "a1", text: "Hel", phase: nil)))
        transcript.apply(event(.delta(id: "a1", text: "lo", phase: nil)))
        XCTAssertEqual(transcript.items.map(\.text), ["Hello"])
        transcript.apply(event(.assistant(id: "a1", text: "Hello", phase: .answer)))
        transcript.apply(event(.tool(id: "t1", title: "Read", input: "file.txt", output: nil, status: "running")))
        let toolID = transcript.items[1].id
        transcript.apply(event(.tool(id: "t1", title: "", input: nil, output: "Permission denied", status: "failed")))
        XCTAssertEqual(transcript.items.count, 2)
        XCTAssertEqual(transcript.items[0].text, "Hello", "a final snapshot is not appended to its deltas")
        XCTAssertEqual(transcript.items[0].phase, .answer, "later tools do not relabel an explicit final answer")
        XCTAssertEqual(transcript.items[1].id, toolID)
        XCTAssertEqual(transcript.items[1].tool?.input, "file.txt")
        XCTAssertEqual(transcript.items[1].tool?.output, "Permission denied")
        XCTAssertEqual(transcript.items[1].tool?.status, "failed")
    }

    func testModelMetadataDoesNotRewriteEarlierResponsesAndTurnsStaySeparate() {
        var transcript = SessionTranscript()
        transcript.apply(event(.metadata(SessionMetadata(model: "model-a"))))
        transcript.apply(event(.assistant(id: "a1", text: "First", phase: .answer)))
        transcript.apply(event(.metadata(SessionMetadata(model: "model-b"))))
        transcript.apply(event(.assistant(id: "a2", text: "Second", phase: .answer)))
        transcript.apply(event(.assistant(id: "a1", text: "Third", phase: .answer), turn: "turn-2"))
        XCTAssertEqual(transcript.items.map(\.model), ["model-a", "model-b", nil])
        XCTAssertEqual(TranscriptTurn.group(transcript.items).count, 2)
    }

    func testFinishDoesNotClaimPendingWritesWereRejected() {
        var transcript = SessionTranscript()
        transcript.apply(event(.user(id: "u1", text: "Pending", delivery: .pending)))
        transcript.apply(event(.user(id: "u2", text: "Sent", delivery: .written)))
        transcript.apply(event(.user(id: "u3", text: "Rejected", delivery: .failed("No"))))
        transcript.apply(event(.finished(.cancelled)))
        XCTAssertEqual(transcript.items.prefix(3).map(\.delivery), [
            .unconfirmed("The session ended before delivery was confirmed."), .written, .failed("No")
        ])
    }

    func testIncrementalReaderUsesProducerEncodingAndWaitsForIncompleteFinalLine() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let first = try JSONEncoder().encode(event(.delta(id: "a1", text: "Привет 𠀀", phase: nil)))
        let second = try JSONEncoder().encode(event(.delta(id: "a1", text: " world", phase: nil)))
        try (first + Data("\n".utf8) + second.prefix(second.count / 2)).write(to: url)
        let reader = SessionEventReader()
        XCTAssertTrue(try reader.read(from: url))
        XCTAssertEqual(reader.transcript.items.first?.text, "Привет 𠀀")
        let output = try FileHandle(forWritingTo: url)
        try output.seekToEnd()
        try output.write(contentsOf: second.suffix(second.count - second.count / 2) + Data("\n".utf8))
        try output.close()
        XCTAssertTrue(try reader.read(from: url))
        XCTAssertEqual(reader.transcript.items.first?.text, "Привет 𠀀 world")
        XCTAssertTrue(try reader.read(from: url))
        XCTAssertEqual(reader.transcript.items.count, 1, "reading an unchanged file must not replay events")
    }

    func testCorruptCompleteEventRaisesRatherThanReturningPartialHistory() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("{broken}\n".utf8).write(to: url)
        XCTAssertThrowsError(try SessionEventReader().read(from: url))
    }

    func testJournalExposesStreamedEventsBeforeTheReadableLogFlushes() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("session.log")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let output = try FileHandle(forWritingTo: url)
        let spec = LaunchSpec(executable: "/bin/echo", prompt: "Test", arguments: [], workingDirectory: folder.path,
                              environment: [:], mode: .grokACP, timeout: nil, log: url)
        let journal = try RunJournal(output: output, events: RunEvents(session: { _ in }, finished: { _ in }),
                                     spec: spec, legacy: nil)
        journal.text("First chunk")
        let reader = SessionEventReader()
        XCTAssertTrue(try reader.read(from: SessionEventReader.file(for: url)))
        XCTAssertEqual(reader.transcript.items.last?.text, "First chunk")
        XCTAssertEqual(try Data(contentsOf: url).count, 0, "the event stream, not the buffered log, supplies the UI")
        journal.delivery(spec.messageID, .failed("Rejected"))
        XCTAssertTrue(try reader.read(from: SessionEventReader.file(for: url)))
        XCTAssertEqual(reader.transcript.items.first?.delivery, .failed("Rejected"))
        journal.finish(.succeeded)
    }
}

final class HarnessEventMapperTests: XCTestCase {
    func testClaudePartialMessageAndSnapshotShareIDsAndToolResultsArePreserved() {
        let mapper = ClaudeEventMapper()
        var transcript = SessionTranscript()
        let frames: [[String: Any]] = [
            ["type": "stream_event", "event": ["type": "message_start", "message": ["id": "a1", "model": "m1"]]],
            ["type": "stream_event", "event": ["type": "content_block_delta", "index": 0,
                                               "delta": ["type": "text_delta", "text": "Hello"]]],
            ["type": "assistant", "message": ["id": "a1", "model": "m1", "content": [
                ["type": "text", "text": "Hello"], ["type": "tool_use", "id": "t1", "name": "Read",
                                                      "input": ["file_path": "sample.txt"]]]]],
            ["type": "user", "message": ["content": [["type": "tool_result", "tool_use_id": "t1",
                                                       "content": "Denied", "is_error": true]]]]
        ]
        for frame in frames {
            for payload in mapper.events(frame) { transcript.apply(SessionEvent(turnID: "turn", payload: payload)) }
        }
        XCTAssertEqual(transcript.items.count, 2)
        XCTAssertEqual(transcript.items[0].text, "Hello")
        XCTAssertEqual(transcript.items[0].model, "m1")
        XCTAssertEqual(transcript.items[1].tool?.output, "Denied")
        XCTAssertEqual(transcript.items[1].tool?.status, "failed")
    }

    func testCodexDeltaAndCompletedSnapshotAndPhaseComeThroughTheRealMapper() {
        var transcript = SessionTranscript()
        let notifications: [(String, [String: Any])] = [
            ("item/started", ["item": ["id": "a1", "type": "agentMessage", "text": "", "phase": "commentary"]]),
            ("item/agentMessage/delta", ["itemId": "a1", "delta": "Checking"]),
            ("item/completed", ["item": ["id": "a1", "type": "agentMessage", "text": "Checking",
                                         "phase": "commentary"]]),
            ("item/completed", ["item": ["id": "t1", "type": "commandExecution", "command": "false",
                                          "aggregatedOutput": "Failed", "status": "failed"]])
        ]
        for (method, params) in notifications {
            for payload in CodexEventMapper.events(method, params) {
                transcript.apply(SessionEvent(turnID: "turn", payload: payload))
            }
        }
        XCTAssertEqual(transcript.items.count, 2)
        XCTAssertEqual(transcript.items[0].text, "Checking")
        XCTAssertEqual(transcript.items[0].phase, .work)
        XCTAssertEqual(transcript.items[1].tool?.output, "Failed")
    }

    func testCodexNonzeroExitIsAFailureEvenWhenTheExecutionItemCompleted() {
        let events = CodexEventMapper.events("item/completed", ["item": [
            "id": "t1", "type": "commandExecution", "command": "false", "status": "completed",
            "exitCode": 3, "aggregatedOutput": "Failed"
        ]])
        var transcript = SessionTranscript()
        for payload in events { transcript.apply(SessionEvent(turnID: "turn", payload: payload)) }
        XCTAssertEqual(transcript.items.first?.tool?.status, "failed")
        XCTAssertTrue(transcript.items.first?.tool?.output?.contains("Exit code: 3") == true)
    }

    func testGrokToolBoundaryCreatesNewAssistantSegmentAndUpdatesKeepToolID() {
        let mapper = GrokEventMapper()
        var transcript = SessionTranscript()
        for update: [String: Any] in [
            ["sessionUpdate": "agent_message_chunk", "content": ["text": "Before"]],
            ["sessionUpdate": "tool_call", "toolCallId": "t1", "title": "Read", "rawInput": ["path": "sample.txt"]],
            ["sessionUpdate": "tool_call_update", "toolCallId": "t1", "status": "completed", "rawOutput": "Output"],
            ["sessionUpdate": "agent_message_chunk", "content": ["text": "After"]]
        ] {
            for payload in mapper.events(update) { transcript.apply(SessionEvent(turnID: "turn", payload: payload)) }
        }
        XCTAssertEqual(transcript.items.map(\.kind), [.agent, .tool, .agent])
        XCTAssertEqual(transcript.items[1].tool?.output, "Output")
        let turn = TranscriptTurn.group(transcript.items)[0]
        XCTAssertEqual(turn.work.first?.text, "Before")
        XCTAssertEqual(turn.answer.first?.text, "After")
    }
}
