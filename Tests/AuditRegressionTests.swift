import Darwin
@testable import RotaCore
import XCTest

final class AuditRegressionTests: XCTestCase {
    func testForeignCodexEventsCannotWriteOrFinishTheSession() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = folder.appendingPathComponent("session.log")
        XCTAssertTrue(FileManager.default.createFile(atPath: log.path, contents: nil))
        let journal = RunJournal(output: try FileHandle(forWritingTo: log),
            events: RunEvents(session: { _ in }, finished: { _ in }),
            transcript: try TranscriptJournal(log: log, resuming: false, logSize: 0))
        let spec = LaunchSpec(executable: "/bin/false", prompt: "", arguments: [], workingDirectory: folder.path,
                              environment: [:], mode: .codexDaemon, timeout: nil, log: log, resume: "owned-thread")
        let runner = CodexDaemonRun(spec: spec, journal: journal)
        for thread in ["foreign-thread", "owned-child", ""] {
            runner.handle("item/started", ["threadId": thread,
                "item": ["type": "commandExecution", "command": "foreign"]])
            runner.handle("item/completed", ["threadId": thread, "item": ["type": "agentMessage", "text": "foreign"]])
            runner.handle("turn/plan/updated", ["threadId": thread, "plan": [["step": "foreign", "status": "pending"]]])
            runner.handle("turn/completed", ["threadId": thread, "turn": ["id": "foreign-turn", "status": "completed"]])
            XCTAssertFalse(journal.isFinished, "An unrelated turn must not finish this run")
        }
        runner.handle("item/completed", ["threadId": "owned-thread", "item": ["type": "agentMessage", "text": "owned"]])
        journal.finish(.succeeded)
        var reader = TranscriptReader()
        let snapshot = reader.read(log: log, finished: true)
        XCTAssertEqual(snapshot.items.filter { $0.kind != .status }.map(\.text), ["owned"])
    }

    func testPreviewSkipsOnlyTheLeadingMaintenanceReport() {
        let record = RunRecord(routineID: "example", trigger: .manual, harness: .antigravity,
                               startedAt: Date(), outcome: .succeeded)
        let report = "pre-commit: 1) maintain.sh - " + String(repeating: "passed ", count: 400)
        for body in [report, "`" + report + "`", "**pre-commit:** " + String(report.dropFirst(11))] {
            let snapshot = TranscriptSnapshot(items: [.init(id: 0, kind: .agent,
                text: body + "\n\nThe rotation is complete. Three entries were updated.")])
            XCTAssertEqual(SessionPreview.text(for: record, snapshot: snapshot),
                           "The rotation is complete. Three entries were updated.")
        }
    }

    func testServiceMessagesDoNotOpenHumanTurns() {
        let service = "<task-notification><task-id>example</task-id><result>Checked</result></task-notification>"
        let items = [TranscriptItem(id: 0, kind: .user, text: "Check the example"),
                     TranscriptItem(id: 1, kind: .user, text: service),
                     TranscriptItem(id: 2, kind: .agent, text: "Done")]
        let turns = TranscriptTurn.group(items)
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns.first?.prompt?.text, "Check the example")
        XCTAssertTrue(turns.first?.notes.contains { $0.text == service } == true)
    }
    func testRotaQuestionReceiptsRemainReadableWithoutChangingTransportText() throws {
        let question = AgentQuestion(id: "synthetic-id", title: "Example", fields: [
            .init(id: "choice", title: "Which example?"),
        ])
        let text = QuestionReceipt.message(question, answer: .init(values: ["choice": ["Blue"]]))
        let receipt = try XCTUnwrap(QuestionReceipt.decode(text))
        XCTAssertEqual(receipt.summary, "Blue")
        XCTAssertEqual(receipt.questions.first?.question, "Which example?")
        XCTAssertNil(QuestionReceipt.decode("Ordinary JSON: " + text))
        XCTAssertNil(QuestionReceipt.decode("Answer to your question id:\n{}"))
    }

    func testServiceDetectionKeepsOrdinaryMarkupAndQuotedMessagesHuman() throws {
        for text in ["<hello>world</hello>", "Look at <task-notification>example</task-notification>",
                     "<task-notification><result>No task ID</result></task-notification>",
                     "A user wrote [Request interrupted by user for tool use]"] {
            XCTAssertNil(TranscriptService.title(text))
            XCTAssertEqual(TranscriptItem(id: 9, kind: .user, text: text).presented.kind, .user)
        }
        let text = "<task-notification><task-id>example</task-id><result>Done</result></task-notification>"
        let data = try JSONSerialization.data(withJSONObject: ["type": "user", "message": [
            "content": [["type": "text", "text": text]]]])
        XCTAssertEqual(ClaudeTranscript.read(data), .service(text))
        XCTAssertEqual(StreamJSONFormatter.items(data).first?.kind, .status)
        XCTAssertEqual(try NativeTranscript.events(data, harness: .claude), [.item(.status, text)])
    }

    func testForeignCodexRequestsAreNeitherPresentedNorAnswered() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = folder.appendingPathComponent("session.log")
        XCTAssertTrue(FileManager.default.createFile(atPath: log.path, contents: nil))
        let asked = expectation(description: "only the owned request is presented")
        let resolved = expectation(description: "only the owned resolution is delivered")
        let journal = RunJournal(output: try FileHandle(forWritingTo: log), events: RunEvents(
            session: { _ in }, finished: { _ in }, question: { question, _ in
                XCTAssertEqual(question.id, "owned-request")
                asked.fulfill()
            }, questionResolved: { id in
                XCTAssertEqual(id, "owned-request")
                resolved.fulfill()
            }))
        let spec = LaunchSpec(executable: "/bin/false", prompt: "", arguments: [], workingDirectory: folder.path,
                              environment: [:], mode: .codexDaemon, timeout: nil, log: log, resume: "owned-thread")
        let runner = CodexDaemonRun(spec: spec, journal: journal)
        for thread in ["foreign-thread", "owned-child", "", "owned-thread"] {
            let owned = thread == "owned-thread"
            let id = owned ? "owned-request" : "foreign-request"
            runner.handleRequest(id, method: "item/tool/requestUserInput", params: [
                "threadId": thread, "questions": [["id": "example", "question": "Which example?"]],
            ]) { _ in XCTFail("No unanswered request should receive an RPC response") }
            runner.handle("serverRequest/resolved", ["threadId": thread, "requestId": id])
        }
        wait(for: [asked, resolved], timeout: 2)
        journal.finish(.cancelled)
    }

    /// A print-mode Claude run on a temporary log, driven by handing it stream-json lines.
    private func claudeStreamRun(finished: @escaping (RunOutcome) -> Void = { _ in }) throws
        -> (runner: ClaudeStreamRun, journal: RunJournal, log: URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let log = folder.appendingPathComponent("session.log")
        XCTAssertTrue(FileManager.default.createFile(atPath: log.path, contents: nil))
        let journal = RunJournal(output: try FileHandle(forWritingTo: log),
                                 events: RunEvents(session: { _ in }, finished: finished))
        let spec = LaunchSpec(executable: "/bin/false", prompt: "Example", arguments: [],
                              workingDirectory: folder.path, environment: [:], mode: .claudeStream,
                              timeout: nil, log: log)
        return (ClaudeStreamRun(spec: spec, journal: journal), journal, log)
    }

    func testClaudeExitWithoutAResultIsInterruptedEvenAtExitZero() throws {
        let (runner, journal, log) = try claudeStreamRun()
        runner.exited(status: 0)
        XCTAssertTrue(journal.isFinished)
        XCTAssertTrue(try String(contentsOf: log, encoding: .utf8).contains("Interrupted after"))
    }

    func testClaudeResultWithBackgroundTasksRunningKeepsTheRunOpen() throws {
        let (runner, journal, log) = try claudeStreamRun()
        // The order claude -p 2.1.310 emitted on 2026-10-26 around a background command.
        runner.handle(#"{"type":"system","subtype":"background_tasks_changed","tasks":[{"task_id":"b1"}]}"#)
        runner.handle(#"{"type":"result","subtype":"success","result":"STARTED"}"#)
        XCTAssertFalse(journal.isFinished, "Claude starts another turn when the task finishes")
        runner.handle(#"{"type":"system","subtype":"background_tasks_changed","tasks":[]}"#)
        runner.handle(#"{"type":"result","subtype":"success","result":"DONE"}"#)
        XCTAssertTrue(journal.isFinished)
        let text = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(text.contains("Waiting for 1 background task"), text)
        XCTAssertTrue(text.contains("Completed after"), text)
    }

    /// The task finished while Claude wrote STARTED: its answer came in a turn after the result (live, 2026-10-26).
    private func finishWhileAnswering(_ runner: ClaudeStreamRun) {
        runner.handle(#"{"type":"system","subtype":"init","session_id":"s1"}"#)
        runner.handle(#"{"type":"system","subtype":"background_tasks_changed","tasks":[{"task_id":"b1"}]}"#)
        runner.handle(#"{"type":"system","subtype":"task_notification","task_id":"b1","status":"completed"}"#)
        runner.handle(#"{"type":"system","subtype":"background_tasks_changed","tasks":[]}"#)
        runner.handle(#"{"type":"result","subtype":"success","result":"STARTED"}"#)
    }

    func testClaudeNotifiedTurnWaitsForTheTurnTheNotificationStarts() throws {
        let (runner, journal, _) = try claudeStreamRun()
        runner.settle = 3600
        finishWhileAnswering(runner)
        XCTAssertFalse(journal.isFinished)
        runner.handle(#"{"type":"system","subtype":"init","session_id":"s1"}"#)
        runner.handle(#"{"type":"result","subtype":"success","result":"DONE"}"#)
        XCTAssertTrue(journal.isFinished)
    }

    func testClaudeNotifiedTurnEndsWhenNoTurnFollows() throws {
        let ended = expectation(description: "finished")
        let (runner, journal, _) = try claudeStreamRun { _ in ended.fulfill() }
        runner.settle = 0
        finishWhileAnswering(runner)
        XCTAssertFalse(journal.isFinished)
        wait(for: [ended], timeout: 5)
    }

    /// A tool result after the notification means a later request in the same turn carried it.
    func testClaudeNotificationAnsweredInTheTurnEndsTheRunAtItsResult() throws {
        let (runner, journal, _) = try claudeStreamRun()
        runner.settle = 3600
        runner.handle(#"{"type":"system","subtype":"background_tasks_changed","tasks":[{"task_id":"b1"}]}"#)
        runner.handle(#"{"type":"system","subtype":"task_notification","task_id":"b1","status":"completed"}"#)
        runner.handle(#"{"type":"system","subtype":"background_tasks_changed","tasks":[]}"#)
        runner.handle(#"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"ok"}]}}"#)
        runner.handle(#"{"type":"result","subtype":"success","result":"DONE"}"#)
        XCTAssertTrue(journal.isFinished)
    }

    func testClaudeAmbientTasksDoNotHoldTheRun() throws {
        let (runner, journal, _) = try claudeStreamRun()
        runner.handle(#"{"type":"system","subtype":"background_tasks_changed","#
            + #""tasks":[{"task_id":"m1","ambient":true}]}"#)
        runner.handle(#"{"type":"result","subtype":"success","result":"Watching"}"#)
        XCTAssertTrue(journal.isFinished)
    }

    func testClaudeFailedResultEndsTheRunDespiteBackgroundTasks() throws {
        let (runner, journal, _) = try claudeStreamRun()
        runner.handle(#"{"type":"system","subtype":"background_tasks_changed","tasks":[{"task_id":"b1"}]}"#)
        runner.handle(#"{"type":"result","subtype":"error_during_execution","is_error":true}"#)
        XCTAssertTrue(journal.isFinished)
    }

    func testDisconnectedTransportsCannotTerminateTheHostWithSIGPIPE() throws {
        for webSocket in [false, true] {
            let input = Pipe()
            let output = Pipe()
            try input.fileHandleForReading.close()
            let transport: MessageTransport = webSocket
                ? WebSocketTransport(input: input.fileHandleForWriting, output: output.fileHandleForReading)
                : LineTransport(input: input.fileHandleForWriting, output: output.fileHandleForReading)
            XCTAssertEqual(fcntl(input.fileHandleForWriting.fileDescriptor, F_GETNOSIGPIPE), 1)
            XCTAssertThrowsError(try input.fileHandleForWriting.write(contentsOf: Data("closed peer".utf8)))
            transport.send(Data("{}".utf8))
            transport.close()
            output.fileHandleForReading.readabilityHandler = nil
        }
    }

}
