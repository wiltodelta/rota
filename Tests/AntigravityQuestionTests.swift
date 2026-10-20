import XCTest

@testable import RotaCore

final class AntigravityQuestionTests: XCTestCase {
    private let session = "00000000-0000-4000-8000-000000000001"

    // Native tool-call arguments observed in a generated questionnaire, including
    // agy's JSON string inside args. No model prose or reasoning is a fixture.
    private func record(step: Int = 1) throws -> Data {
        let fields: [[String: Any]] = [
            ["question": "Which color?", "options": ["Blue", "Green"], "is_multi_select": false],
            ["question": "Which fruit?", "options": ["Apple", "Pear", "Plum"], "is_multi_select": true],
        ]
        let args = QuestionRequest.json(fields)
        return try JSONSerialization.data(withJSONObject: [
            "type": "PLANNER_RESPONSE", "status": "DONE", "step_index": step,
            "tool_calls": [["name": "ask_question", "args": ["questions": args]]],
            "content": "This prose must not become a question.",
        ]) + Data([10])
    }

    private func workspace() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("rota-question-peer-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    func testNativeArchivePreservesChoicesAndDoesNotReplayPartialOrDuplicateRows() throws {
        let home = try workspace()
        defer { try? FileManager.default.removeItem(at: home) }
        var archive = try XCTUnwrap(AntigravityQuestionArchive(session: session, home: home))
        try FileManager.default.createDirectory(at: archive.file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let bytes = try record()
        try bytes.prefix(30).write(to: archive.file)
        XCTAssertTrue(try archive.read().isEmpty)
        XCTAssertThrowsError(try archive.read(final: true), "An ended source cannot silently retain a partial row")
        let writer = try FileHandle(forWritingTo: archive.file)
        defer { try? writer.close() }
        try writer.seekToEnd()
        try writer.write(contentsOf: bytes.dropFirst(30))
        let questions = try archive.read()
        let question = try XCTUnwrap(questions.first)
        XCTAssertEqual(questions.count, 1)
        XCTAssertEqual(question.fields.map(\.kind), [.choice, .multiple])
        XCTAssertEqual(question.fields.map(\.title), ["Which color?", "Which fruit?"])
        XCTAssertEqual(question.fields[1].options.map(\.id), ["Apple", "Pear", "Plum"])
        XCTAssertEqual(question.replyViaMessage, true)
        try writer.write(contentsOf: bytes)
        XCTAssertTrue(try archive.read().isEmpty, "Native row revisions must not ask twice")
        try question.validate(.init(values: ["0": ["Green"], "1": ["Apple", "Pear"]]))
    }

    func testContinuationReadsOnlyNewNativeCallsAndRejectsTruncation() throws {
        let home = try workspace()
        defer { try? FileManager.default.removeItem(at: home) }
        let original = try XCTUnwrap(AntigravityQuestionArchive(session: session, home: home))
        try FileManager.default.createDirectory(at: original.file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try record().write(to: original.file)
        var continued = try XCTUnwrap(AntigravityQuestionArchive(session: session, home: home, skipExisting: true))
        XCTAssertTrue(try continued.read().isEmpty)
        let writer = try FileHandle(forWritingTo: original.file)
        try writer.seekToEnd()
        try writer.write(contentsOf: record(step: 4))
        try writer.close()
        XCTAssertEqual(try continued.read().map(\.id), ["antigravity/\(session)/4/0"])
        try Data().write(to: original.file)
        XCTAssertThrowsError(try continued.read())
        XCTAssertNil(AntigravityQuestionArchive(session: "../other", home: home))
    }

    func testUnknownFormsAndPermissionToolsCannotInventApproval() throws {
        for tool in ["ask_question", "ask_permission", "ask_custom_permission"] {
            let question = try XCTUnwrap(QuestionRequest.antigravity(tool, arguments: [:], id: tool))
            XCTAssertTrue(question.actions.isEmpty)
            XCTAssertEqual(question.replyViaMessage, true)
            XCTAssertThrowsError(try question.validate(.init()))
            try question.validate(.init(action: "cancel"))
            try question.validate(.init(action: "decline"))
        }
        XCTAssertNil(QuestionRequest.antigravity("run_command", arguments: [:], id: "ordinary"))
        let text = try XCTUnwrap(QuestionRequest.antigravity("ask_question", arguments: [
            "questions": [["question": "Any notes?", "options": []]],
        ], id: "text"))
        XCTAssertEqual(text.fields.first?.kind, .text)
        try text.validate(.init(values: ["0": ["A custom answer"]]))
    }

    func testRunnerPublishesNativeQuestionDespiteOpaqueStreamEvent() throws {
        try checkRunner(native: record(), expectsQuestion: true)
    }

    func testRunnerReportsUnreadableQuestionSourcesInsteadOfSilentSuccess() throws {
        try checkRunner(native: nil, expectsQuestion: false)
        try checkRunner(native: Data("{broken}\n".utf8), expectsQuestion: false)
    }

    private func checkRunner(native: Data?, expectsQuestion: Bool) throws {
        let home = try workspace()
        defer { try? FileManager.default.removeItem(at: home) }
        let archive = try XCTUnwrap(AntigravityQuestionArchive(session: session, home: home))
        try FileManager.default.createDirectory(at: archive.file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let source = home.appendingPathComponent("native-row")
        try native?.write(to: source)
        let peer = home.appendingPathComponent("peer")
        let script = """
        #!/bin/zsh
        IFS= read -r message
        printf '%s\\n' '{"event":"init","conversation_id":"\(session)","init":{}}'
        \(native == nil ? ":" : "/bin/cat \(shellQuote(source.path)) >> \(shellQuote(archive.file.path))")
        printf '%s\\n' '{"event":"step_update","step_update":{"step_index":2,"step_type":"unknown","state":"DONE"}}'
        printf '%s\\n' '{"event":"result","result":{"status":"SUCCESS","response":"Waiting for explicit answers"}}'
        """
        try script.write(to: peer, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: peer.path)
        let spec = LaunchSpec(executable: peer.path, prompt: "Ask", arguments: [], workingDirectory: home.path,
                              environment: ["HOME": home.path], mode: .antigravityStream, timeout: 10,
                              log: home.appendingPathComponent("run.log"))
        let asked = expectsQuestion ? expectation(description: "Native metadata reaches the host") : nil
        let finished = expectation(description: "Headless turn ends with the question retained by the host")
        let control = try ProcessLauncher().launch(spec, events: .init(session: { _ in }, finished: {
            XCTAssertEqual($0, expectsQuestion ? .succeeded : .failed(exitCode: 1))
            finished.fulfill()
        }, question: { question, _ in
            XCTAssertTrue(expectsQuestion)
            XCTAssertEqual(question.fields.map(\.kind), [.choice, .multiple])
            XCTAssertEqual(question.replyViaMessage, true)
            asked?.fulfill()
        }))
        defer { control.stop() }
        wait(for: [asked, finished].compactMap { $0 }, timeout: 15)
        let text = try String(contentsOf: spec.log, encoding: .utf8)
        XCTAssertEqual(text.contains("native questions could not be read"), !expectsQuestion)
    }
}
