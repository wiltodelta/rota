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
    func testGrokMultipleSelection() throws { try question(.grok, multiple: true) }
    func testClaudeMultipleSelection() throws { try question(.claude, multiple: true) }
    func testCodexNativeQuestionInDefaultMode() throws { try question(.codex) }
    func testClaudeStreamNativeQuestionThroughBundledHook() throws { try question(.claude) }

    @MainActor
    func testAntigravityQuestionAndLaterAnswerThroughScheduler() throws {
        let executable = Harness.antigravity.defaultExecutable()
        let model = try XCTUnwrap(ModelCatalog.models(for: .antigravity, executable: executable)
            .first { !$0.isDefault && !$0.efforts.isEmpty })
        let scheduler = Scheduler(location: StorageLocation(root: folder, logs: folder.appendingPathComponent("Logs")),
                                  launcher: ProcessLauncher())
        scheduler.executable = { _ in executable }
        let routine = Routine(id: "native-question-probe", name: "Native question probe", workingDirectory: folder.path,
                              schedule: "0 10 * * *", harness: .antigravity, prompt:
            "Protocol test. Do not read or write files, execute commands, or use tools other than ask_question. "
                + "Call ask_question exactly once with two questions: 'Which color?' with Blue and Green, "
                + "single select; 'Which fruit?' with Apple, Pear, Plum, multiple select. "
                + "Do not select for the user. End after the tool returns. When the user later supplies "
                + "explicit answers, repeat those answers exactly without calling tools.",
                              timeLimitMinutes: 2, model: model.id, effort: model.efforts.first)
        scheduler.save(routine)
        let first = expectation(description: "question turn ended")
        let second = expectation(description: "explicit answer turn ended")
        let notifier = QuestionRunObserver()
        var completions = 0
        notifier.onEnd = { record in
            XCTAssertEqual(record.outcome, .succeeded)
            completions += 1
            (completions == 1 ? first : second).fulfill()
        }
        scheduler.notifier = notifier
        defer { scheduler.stopAll() }
        scheduler.run(routine, trigger: .manual)
        wait(for: [first], timeout: 150)
        let record = try XCTUnwrap(scheduler.history.records(for: routine.id).first)
        print("Antigravity question test session: \(record.sessionID ?? "unknown"), cwd \(folder.path)")
        let question = try XCTUnwrap(record.nextQuestion)
        XCTAssertEqual(question.fields.map(\.kind), [.choice, .multiple])
        XCTAssertEqual(question.fields.map(\.title), ["Which color?", "Which fruit?"])
        let custom = "color-" + UUID().uuidString.prefix(8)
        try scheduler.answerQuestion(question.id, on: record,
                                     answer: .init(values: ["0": [custom], "1": ["Pear", "Plum"]]))
        wait(for: [second], timeout: 150)
        let finished = try XCTUnwrap(scheduler.current(record.id))
        XCTAssertEqual(finished.sessionID, record.sessionID)
        XCTAssertTrue(finished.questions?.isEmpty != false, "Old native calls must not reappear on continuation")
        let path = try XCTUnwrap(finished.logPath)
        var reader = TranscriptReader()
        let snapshot = reader.read(log: URL(fileURLWithPath: path), finished: true)
        XCTAssertFalse(snapshot.items.contains { $0.text.contains("native questions could not be read") })
        let answer = try XCTUnwrap(snapshot.items.last { $0.kind == .agent }?.text)
        XCTAssertTrue(answer.contains(custom), answer)
        XCTAssertTrue(answer.contains("Pear") && answer.contains("Plum"), answer)
    }

    func testClaudeInteractiveNativeQuestionThroughBundledHook() throws {
        guard let directory = ProcessInfo.processInfo.environment["ROTA_INTERACTIVE_TEST_DIR"] else {
            throw XCTSkip("Set ROTA_INTERACTIVE_TEST_DIR to a trusted test workspace")
        }
        try XCTSkipUnless(ClaudeUserSettings.read().trusts(directory))
        try question(.claude, mode: .claudeInteractive, directory: directory)
    }

    /// A dialog no hook answers reaches the chat and takes the chosen option's number.
    /// Rota runs bypass permissions; the wrapper asks in `default` mode and drops the
    /// `PermissionRequest` hook, so a real permission dialog waits on the screen alone.
    func testClaudeInteractiveTerminalDialogReachesTheChat() throws {
        try terminalDialog(keepHook: false)
    }

    /// Claude draws its permission dialog while the `PermissionRequest` hook waits for the
    /// chat, and notifies about it: that dialog must not reach the chat a second time.
    func testClaudeInteractivePermissionDialogIsAskedOnce() throws {
        try terminalDialog(keepHook: true)
    }

    private func terminalDialog(keepHook: Bool) throws {
        guard let directory = ProcessInfo.processInfo.environment["ROTA_INTERACTIVE_TEST_DIR"] else {
            throw XCTSkip("Set ROTA_INTERACTIVE_TEST_DIR to a trusted test workspace")
        }
        try XCTSkipUnless(ClaudeUserSettings.read().trusts(directory))
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: cli), "Build Rota.app first")
        let wrapper = try dialogWrapper(keepHook: keepHook)
        let file = "rota-dialog-\(UUID().uuidString.prefix(8)).txt"
        defer { try? FileManager.default.removeItem(atPath: directory + "/" + file) }
        let server = try slowQuestionServer()
        defer { server.stop() }
        let finished = expectation(description: "the session ended")
        nonisolated(unsafe) var dialogs: [AgentQuestion] = []
        nonisolated(unsafe) var session: String?
        let spec = LaunchSpec(
            executable: wrapper.path,
            prompt: "Run exactly this shell command with the Bash tool: touch \(file) . "
                + "Run nothing else. If it is refused, reply REFUSED.",
            arguments: [], workingDirectory: directory,
            environment: ["ROTA_CLI": cli, "ROTA_SESSION": UUID().uuidString, "ROTA_DATA_DIR": folder.path],
            mode: .claudeInteractive, timeout: 150, log: folder.appendingPathComponent("session.log"))
        let events = RunEvents(
            session: { session = $0 }, finished: { _ in finished.fulfill() },
            question: { question, reply in
                dialogs.append(question)
                reply(QuestionAnswer(action: question.actions.last?.id ?? "cancel"))
            })
        let control = try ProcessLauncher().launch(spec, events: events)
        defer { control.stop() }
        wait(for: [finished], timeout: 180)
        let log = try String(contentsOf: spec.log, encoding: .utf8)
        if keepHook {
            XCTAssertTrue(dialogs.isEmpty, "\(dialogs) \(log)")
        } else {
            XCTAssertEqual(dialogs.count, 1, log)
            XCTAssertEqual(dialogs.first?.actions.last?.label, "No")
            XCTAssertTrue(dialogs.first?.detail.contains("touch \(file)") == true, dialogs.first?.detail ?? "")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory + "/" + file), log)
        XCTAssertTrue(log.contains("REFUSED"), log)
        print("Dialog test (hook kept: \(keepHook)): session \(session ?? "unknown"), cwd \(directory)")
    }

    /// `claude` in `default` mode, optionally without Rota's `PermissionRequest` hook.
    private func dialogWrapper(keepHook: Bool) throws -> URL {
        let wrapper = folder.appendingPathComponent("claude")
        try """
            #!/bin/zsh
            args=()
            for a in "$@"; do [[ $a == bypassPermissions ]] && a=default; args+=("$a"); done
            \(keepHook ? "" : #"/usr/bin/plutil -remove hooks.PermissionRequest "${args[${args[(i)--settings]}+1]}""#)
            exec \(Harness.claude.defaultExecutable()) "${args[@]}"
            """.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        return wrapper
    }

    /// A hook's question stays open long enough for Claude's notification, then is declined.
    private func slowQuestionServer() throws -> ControlServer {
        nonisolated(unsafe) var opened = Date.distantFuture
        let server = ControlServer(socket: folder.appendingPathComponent("rota.sock")) { method, _ in
            if method == "questions.create" {
                opened = Date()
                return .success(["question": "hook"])
            }
            if method == "questions.poll" {
                return .success(Date().timeIntervalSince(opened) < 20 ? ["pending": true] : ["action": "decline"])
            }
            return .failure(ControlError("Unexpected method"))
        }
        try server.start()
        return server
    }

    func testCodexAsyncQuestionsReachTheHostAndAcceptALaterTurn() throws {
        let log = folder.appendingPathComponent("async.log")
        let firstFinished = expectation(description: "async question turn finished")
        nonisolated(unsafe) var session: String?
        nonisolated(unsafe) var seen: AgentQuestion?
        let prompt = "Protocol test. Do not read or write files or run commands. "
            + "Call request_user_input_async once with two questions: 'Which color?' with Blue and Green options, "
            + "and 'Any notes?' with no options. Then end your turn. "
            + "When the user later answers, repeat their chosen color and notes exactly."
        var spec = LaunchSpec(executable: Harness.codex.defaultExecutable(), prompt: prompt, arguments: [],
                              workingDirectory: folder.path, environment: [:], mode: .codexDaemon,
                              timeout: 150, log: log)
        let first = try ProcessLauncher().launch(spec, events: RunEvents(
            session: { session = $0 }, finished: { outcome in
                XCTAssertEqual(outcome, .succeeded)
                firstFinished.fulfill()
            }, question: { question, _ in seen = question }))
        defer { first.stop() }
        wait(for: [firstFinished], timeout: 180)
        let question = try XCTUnwrap(seen, "Async question metadata must reach the host")
        XCTAssertEqual(question.replyViaMessage, true)
        XCTAssertEqual(question.fields.map(\.title), ["Which color?", "Any notes?"])
        XCTAssertEqual(question.fields.first?.options.map(\.label), ["Blue", "Green"])
        let note = "note-" + UUID().uuidString.prefix(8)
        spec.resume = try XCTUnwrap(session)
        spec.prompt = QuestionReceipt.message(question, answer: .init(values: ["0": ["Green"], "1": [note]]))
        nonisolated(unsafe) var reasked: [String] = []
        let secondFinished = expectation(description: "answer consumed in continued session")
        let second = try ProcessLauncher().launch(spec, events: RunEvents(
            session: { _ in }, finished: { outcome in
                XCTAssertEqual(outcome, .succeeded)
                secondFinished.fulfill()
            }, question: { question, _ in reasked.append(question.id) }))
        defer { second.stop() }
        wait(for: [secondFinished], timeout: 180)
        // The next resume replays the question and its answer from the thread's history.
        spec.prompt = "Reply with OK only."
        let thirdFinished = expectation(description: "history with the answer restored")
        let third = try ProcessLauncher().launch(spec, events: RunEvents(
            session: { _ in }, finished: { outcome in
                XCTAssertEqual(outcome, .succeeded)
                thirdFinished.fulfill()
            }, question: { question, _ in reasked.append(question.id) }))
        defer { third.stop() }
        wait(for: [thirdFinished], timeout: 180)
        XCTAssertEqual(reasked, [], "an answered async question must not come back on resume")
        let text = try String(contentsOf: log, encoding: .utf8)
        // A user log entry cannot satisfy the assertions against the actual assistant transcript.
        let transcript = Transcript.parse(text, shell: false)
        XCTAssertTrue(transcript.contains { item in
            item.kind == .agent && item.text.contains(note) && item.text.contains("Green")
        })
        print("Question test codex async: session \(session ?? "unknown"), cwd \(folder.path)")
    }

    private func questionPrompt(_ harness: Harness, multiple: Bool) -> String {
        let tool =
            harness == .claude ? "AskUserQuestion" : harness == .codex ? "request_user_input" : "ask_user_question"
        return
            "Protocol test. Do not read or write files, run commands, or call any other tools. "
            + "Call \(tool) exactly once. Ask exactly 'Which color?' with Blue and Green options. "
            + (multiple ? "Enable multiple selection. " : "Use single selection. ")
            + "Use id color if supported. After receiving the answer, "
            + "reply with 'Selected: ' followed by the actual answers joined by comma and space."
    }

    private var cli: String {
        URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Rota.app/Contents/Helpers/rota").path
    }

    private func questionServer(_ answer: QuestionAnswer, multiple: Bool,
                                received: @escaping @Sendable () -> Void) throws -> ControlServer {
        let boxed = UncheckedSendable(try JSONSerialization.jsonObject(with: JSONEncoder().encode(answer)))
        let server = ControlServer(socket: folder.appendingPathComponent("rota.sock")) { method, params in
            if method == "questions.create" {
                let question = params["question"] as? [String: Any]
                let field = (question?["fields"] as? [[String: Any]])?.first
                XCTAssertEqual(field?["title"] as? String, "Which color?")
                XCTAssertEqual(field?["kind"] as? String, multiple ? "multiple" : "choice")
                received()
                return .success(["question": "fixture"])
            }
            if method == "questions.poll" { return .success(boxed.value) }
            return .failure(ControlError("Unexpected method"))
        }
        try server.start()
        return server
    }

    private func question(_ harness: Harness, mode: LaunchMode? = nil, directory: String? = nil,
                          multiple: Bool = false) throws {
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: cli), "Build Rota.app first")
        nonisolated(unsafe) var questionsSeen = 0
        let finished = expectation(description: "agent received answer and finished")
        let selected = multiple ? ["Blue", "Green"] : ["Blue"]
        let answer = QuestionAnswer(values: ["color": selected, "Which color?": selected])
        let server = try questionServer(answer, multiple: multiple) { questionsSeen += 1 }
        defer { server.stop() }
        let log = folder.appendingPathComponent("session.log")
        let spec = LaunchSpec(
            executable: harness.defaultExecutable(), prompt: questionPrompt(harness, multiple: multiple),
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
                XCTAssertEqual(question.fields.first?.kind, multiple ? .multiple : .choice)
                questionsSeen += 1
                reply(answer)
            })
        let control = try ProcessLauncher().launch(spec, events: events)
        defer { control.stop() }
        wait(for: [finished], timeout: 180)
        XCTAssertGreaterThan(questionsSeen, 0, "The standard question must reach the host")
        let text = try String(contentsOf: log, encoding: .utf8)
        XCTAssertEqual(outcome, .succeeded, text)
        XCTAssertTrue(text.contains("Selected: " + selected.joined(separator: ", ")), text)
        print("Question test \(harness.rawValue): session \(session ?? "unknown"), cwd \(spec.workingDirectory)")
    }
}

@MainActor
private final class QuestionRunObserver: RunNotifying {
    var onEnd: (RunRecord) -> Void = { _ in }
    func runEnded(_ record: RunRecord, routine: Routine) { onEnd(record) }
    func routinePaused(_ routine: Routine, failures: Int) {}
}
