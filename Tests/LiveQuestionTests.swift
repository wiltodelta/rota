import XCTest

@testable import RotaCore

/// Synthetic protocol checks, opt-in because they spend vendor quota and save native sessions.
final class LiveQuestionTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["ROTA_LIVE_QUESTIONS"] == "1")
        folder = URL(fileURLWithPath: "/tmp").appendingPathComponent(
            "rota-live-questions-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let folder { try? FileManager.default.removeItem(at: folder) }
    }

    func testGrokNativeQuestion() throws { try question(.grok) }
    func testCodexNativeQuestionInDefaultMode() throws { try question(.codex) }
    func testClaudeStreamNativeQuestionThroughBundledHook() throws { try question(.claude) }

    func testClaudeInteractiveNativeQuestionThroughBundledHook() throws {
        guard let directory = ProcessInfo.processInfo.environment["ROTA_INTERACTIVE_TEST_DIR"] else {
            throw XCTSkip("Set ROTA_INTERACTIVE_TEST_DIR to a trusted test workspace")
        }
        try XCTSkipUnless(ClaudeUserSettings.read().trusts(directory))
        try question(.claude, mode: .claudeInteractive, directory: directory)
    }

    private func questionPrompt(_ harness: Harness) -> String {
        let tool =
            harness == .claude ? "AskUserQuestion" : harness == .codex ? "request_user_input" : "ask_user_question"
        return
            "Protocol test. Do not read or write files, run commands, or call any other tools. "
            + "Call \(tool) exactly once. Ask exactly 'Which color?' with Blue and Green options, single select. "
            + "Use id color if supported. After receiving the answer, reply exactly 'Selected: Blue'."
    }

    private var cli: String {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Rota.app/Contents/Helpers/rota").path
    }

    private func question(_ harness: Harness, mode: LaunchMode? = nil, directory: String? = nil) throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: cli), "Build Rota.app first")
        nonisolated(unsafe) var questionsSeen = 0
        let finished = expectation(description: "agent received answer and finished")
        let answer = QuestionAnswer(values: ["color": ["Blue"], "Which color?": ["Blue"]])
        let payload = try JSONSerialization.jsonObject(with: JSONEncoder().encode(answer))
        let boxed = UncheckedSendable(payload)
        let server = ControlServer(socket: folder.appendingPathComponent("rota.sock")) { method, params in
            if method == "questions.create" {
                let question = params["question"] as? [String: Any]
                XCTAssertEqual((question?["fields"] as? [[String: Any]])?.first?["title"] as? String, "Which color?")
                questionsSeen += 1
                return .success(["question": "fixture"])
            }
            if method == "questions.poll" { return .success(boxed.value) }
            return .failure(ControlError("Unexpected method"))
        }
        try server.start()
        defer { server.stop() }
        let prompt = questionPrompt(harness)
        let log = folder.appendingPathComponent("session.log")
        let spec = LaunchSpec(
            executable: harness.defaultExecutable(), prompt: prompt,
            arguments: harness.arguments(settings: ClaudeUserSettings()),
            workingDirectory: directory ?? folder.path,
            environment: [
                "ROTA_CLI": cli, "ROTA_SESSION": UUID().uuidString,
                "ROTA_DATA_DIR": folder.path,
            ],
            mode: mode ?? harness.launchMode, timeout: 150, log: log)
        nonisolated(unsafe) var outcome: RunOutcome?
        nonisolated(unsafe) var session: String?
        let events = RunEvents(
            session: { session = $0 },
            finished: {
                outcome = $0
                finished.fulfill()
            },
            question: { question, reply in
                XCTAssertEqual(question.fields.first?.title, "Which color?")
                questionsSeen += 1
                reply(answer)
            })
        let control = try ProcessLauncher().launch(spec, events: events)
        defer { control.stop() }
        wait(for: [finished], timeout: 180)
        XCTAssertGreaterThan(questionsSeen, 0, "The standard question must reach the host")
        let text = try String(contentsOf: log, encoding: .utf8)
        XCTAssertEqual(outcome, .succeeded, text)
        XCTAssertTrue(text.contains("Selected: Blue"), text)
        print("Question test \(harness.rawValue): session \(session ?? "unknown"), cwd \(spec.workingDirectory)")
    }
}
