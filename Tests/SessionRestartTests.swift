@testable import RotaCore
import XCTest

@MainActor
final class SessionRestartTests: XCTestCase {
    private var directory: URL!
    private var scheduler: Scheduler!
    private var launcher: RestartLauncher!
    private var routine: Routine!
    private var source: RunRecord!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("rota-restart-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        launcher = RestartLauncher()
        scheduler = Scheduler(location: StorageLocation(root: directory, logs: directory), launcher: launcher)
        scheduler.executable = { "/synthetic/\($0.commandName)" }
        scheduler.claudeSettings = { ClaudeUserSettings() }
        routine = Routine(id: "restart", name: "Restart test", workingDirectory: directory.path,
                          schedule: "0 15 * * *", harness: .codex, prompt: "Edited routine prompt")
        routine.model = "source-provider-model"
        routine.effort = "high"
        scheduler.save(routine)
        let log = directory.appendingPathComponent("source.log")
        let body = "[you] Original task\nAlready finished step one.\n[you] Now do step two\n"
            + "[error] You've hit your weekly limit\n"
        try Data(body.utf8).write(to: log)
        source = RunRecord(routineID: routine.id, trigger: .scheduled, harness: .codex,
                           startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                           endedAt: Date(timeIntervalSince1970: 1_700_000_001),
                           outcome: .failed(exitCode: 1), logPath: log.path)
        source.sessionID = "source-native-session"
        source.model = routine.model
        scheduler.saveRecord(source)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testRestartAcrossEveryAgentKeepsRoutineAndOriginalHistory() async throws {
        for harness in Harness.agents {
            var original = try XCTUnwrap(source)
            original.harness = harness == .codex ? .claude : .codex
            scheduler.saveRecord(original)
            let before = scheduler.routine(routine.id)
            let restarted = await scheduler.restart(original, with: harness)
            let next = try XCTUnwrap(restarted)
            let spec = try XCTUnwrap(launcher.specs.last)
            XCTAssertNotEqual(next.id, original.id)
            XCTAssertEqual(next.harness, harness)
            XCTAssertEqual(next.trigger, .manual)
            XCTAssertEqual(spec.mode, harness.launchMode)
            XCTAssertEqual(spec.workingDirectory, directory.path)
            XCTAssertNil(spec.resume)
            XCTAssertNil(spec.model)
            XCTAssertNil(spec.effort)
            XCTAssertTrue(spec.prompt.contains("Original task"))
            XCTAssertTrue(spec.prompt.contains("Already finished step one."))
            XCTAssertTrue(spec.prompt.contains("Now do step two"))
            XCTAssertFalse(spec.prompt.contains("Edited routine prompt"))
            XCTAssertEqual(scheduler.routine(routine.id), before)
            XCTAssertEqual(scheduler.current(original.id, routineID: routine.id), original)
            launcher.events.last?.finished(.succeeded)
        }
    }

    func testRepeatedRestartsCarryTheRootRequestInsteadOfNestedHandoffs() async throws {
        let first = await scheduler.restart(source, with: .grok)
        let restarted = try XCTUnwrap(first)
        let handoff = try XCTUnwrap(launcher.specs.last?.prompt)
        let log = try XCTUnwrap(restarted.logPath)
        try FileManager.default.createDirectory(at: URL(fileURLWithPath: log).deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data((Transcript.userLines(handoff) + "\nContinued step two.\n").utf8)
            .write(to: URL(fileURLWithPath: log))
        launcher.events.last?.finished(.succeeded)
        let second = await scheduler.restart(restarted, with: .antigravity)
        XCTAssertEqual(second?.originalRequest, "Original task")
        let nextPrompt = try XCTUnwrap(launcher.specs.last?.prompt)
        XCTAssertTrue(nextPrompt.contains("Continued step two."))
        XCTAssertEqual(nextPrompt.components(separatedBy: "Continue this task in a new harness session.").count, 2)
    }

    func testRestartUsesTheInteractiveClaudePreference() async throws {
        scheduler.claudeInteractive = { true }
        let folder = directory.path
        scheduler.claudeSettings = { ClaudeUserSettings(trustedProjects: [folder]) }
        let next = await scheduler.restart(source, with: .claude)
        XCTAssertNotNil(next)
        XCTAssertEqual(launcher.specs.last?.mode, .claudeInteractive)
    }

    func testRestartAllowsAnotherSessionButRejectsShellAndTheSameHarness() async throws {
        let same = await scheduler.restart(source, with: source.harness)
        let shell = await scheduler.restart(source, with: .shell)
        XCTAssertNil(same)
        XCTAssertNil(shell)
        scheduler.run(routine, trigger: .manual)
        let overlap = await scheduler.restart(source, with: .claude)
        XCTAssertNotNil(overlap)
        XCTAssertEqual(launcher.specs.count, 2)
        XCTAssertEqual(scheduler.active.count, 2)
        launcher.events.last?.finished(.succeeded)
        var shellSource = try XCTUnwrap(source)
        shellSource.harness = .shell
        scheduler.saveRecord(shellSource)
        let fromShell = await scheduler.restart(shellSource, with: .claude)
        XCTAssertNil(fromShell)
        XCTAssertEqual(launcher.specs.count, 2)
    }

    func testShellSessionStartsAnAgentDiscussionOfItsOutput() async throws {
        let log = directory.appendingPathComponent("shell.log")
        let body = Transcript.userLines("./backup.sh --verbose") + "\ncopied 12 files\n```\ndisk full\n"
            + "[result: failed with exit code 3 after 4 s]\n"
        try Data(body.utf8).write(to: log)
        var shell = try XCTUnwrap(source)
        shell.harness = .shell
        shell.sessionID = "rota-shell-screen"
        shell.outcome = .failed(exitCode: 3)
        shell.logPath = log.path
        scheduler.saveRecord(shell)
        XCTAssertTrue(scheduler.canDiscuss(shell))
        XCTAssertFalse(scheduler.canDiscuss(try XCTUnwrap(source)))
        let started = await scheduler.discuss(shell, with: .codex, model: "codex-model", effort: "high",
                                              message: "Why is the disk full?")
        let discussion = try XCTUnwrap(started)
        let spec = try XCTUnwrap(launcher.specs.last)
        XCTAssertEqual(launcher.specs.count, 1)
        XCTAssertEqual(discussion.harness, .codex)
        XCTAssertEqual(discussion.discussedSessionID, shell.id)
        XCTAssertEqual(scheduler.discussions(of: shell).map(\.id), [discussion.id])
        XCTAssertNil(discussion.originalRequest)
        XCTAssertEqual(spec.model, "codex-model")
        XCTAssertEqual(spec.effort, "high")
        XCTAssertEqual(discussion.model, "codex-model")
        XCTAssertEqual(discussion.effort, "high")
        XCTAssertEqual(spec.workingDirectory, directory.path)
        // The chat shows the user's words; the run's context travels as an attached file.
        let message = ChatMessage.decode(spec.prompt)
        XCTAssertTrue(message.text.hasPrefix("Why is the disk full?\n\nAbout a run of the Rota routine"))
        XCTAssertTrue(message.text.contains("(Failed (exit 3))"))
        let attached = try XCTUnwrap(message.attachments.first)
        XCTAssertEqual(message.attachments.count, 1)
        XCTAssertEqual(attached.name, "run-context.md")
        XCTAssertTrue(attached.path.hasPrefix(try XCTUnwrap(discussion.logPath)))
        let context = try String(contentsOf: attached.url, encoding: .utf8)
        XCTAssertTrue(context.contains(#"Rota routine "Restart test" (id restart)"#))
        XCTAssertTrue(context.contains("rota update restart --prompt"))
        XCTAssertTrue(context.contains("Command:\n./backup.sh --verbose"))
        XCTAssertTrue(context.contains("Result: Failed (exit 3)"))
        XCTAssertTrue(context.contains("[output]\ncopied 12 files\n```\ndisk full"))
        XCTAssertTrue(context.contains(log.path))
        XCTAssertFalse(spec.prompt.contains("Continue this task"))
        XCTAssertFalse(message.text.contains("copied 12 files"))
        XCTAssertEqual(scheduler.current(shell.id, routineID: routine.id), shell)
        launcher.events.last?.finished(.succeeded)
        var running = shell
        running.outcome = .running
        scheduler.saveRecord(running)
        XCTAssertFalse(scheduler.canDiscuss(running))
    }

    func testRestartRejectsUnknownNativeStateAndStaleRunningRecord() async throws {
        scheduler.survivingSessions[source.id] = source
        let reserved = await scheduler.restart(source, with: .claude)
        XCTAssertNil(reserved)
        scheduler.survivingSessions = [:]
        var running = try XCTUnwrap(source)
        running.outcome = .running
        scheduler.saveRecord(running)
        let stale = await scheduler.restart(source, with: .claude)
        XCTAssertNil(stale)
        XCTAssertTrue(launcher.specs.isEmpty)
    }

    func testMissingContextAndLaunchFailureDoNotSelectANewSession() async throws {
        launcher.shouldFail = true
        let failed = await scheduler.restart(source, with: .claude)
        XCTAssertNil(failed)
        XCTAssertNil(scheduler.activeRecord(for: routine.id))
        let failedRecord = try XCTUnwrap(scheduler.records(for: routine.id).first { $0.id != source.id })
        guard case .launchFailed = failedRecord.outcome else { return XCTFail("Expected launch failure") }
        var missing = try XCTUnwrap(source)
        missing.logPath = directory.appendingPathComponent("missing.log").path
        scheduler.saveRecord(missing)
        let unreadable = await scheduler.restart(missing, with: .grok)
        XCTAssertNil(unreadable)
        XCTAssertNotNil(scheduler.lastError)
    }

    func testUsageLimitOnlyUsesTheLatestAgentTurn() {
        for error in ["You've hit your weekly limit · resets 10pm", "You’ve hit your limit",
                      "Rate limit exceeded", "rate_limit_exceeded", "RESOURCE_EXHAUSTED",
                      "insufficient_quota", "You exceeded your current quota", "HTTP 429 Too Many Requests"] {
            XCTAssertTrue(SessionRestart.hitUsageLimit(in: Transcript.parse("[you] task\n[error] " + error)), error)
        }
        XCTAssertTrue(SessionRestart.hitUsageLimit(in: Transcript.parse("[you] task\nYou've hit your weekly limit")))
        XCTAssertFalse(SessionRestart.hitUsageLimit(in: Transcript.parse("[you] Explain rate_limit_exceeded")))
        XCTAssertFalse(SessionRestart.hitUsageLimit(in: Transcript.parse("-> rate_limit_exceeded")))
        XCTAssertFalse(SessionRestart.hitUsageLimit(in: Transcript.parse("[error] HTTP 401 Unauthorized")))
        let recovered = "[you] task\n[error] quota exceeded\n[you] retry\nDone"
        XCTAssertFalse(SessionRestart.hitUsageLimit(in: Transcript.parse(recovered)))
    }
}

private final class RestartLauncher: RoutineLaunching {
    var specs: [LaunchSpec] = []
    var events: [RunEvents] = []
    var shouldFail = false

    func launch(_ spec: LaunchSpec, events: RunEvents) throws -> RunControl {
        if shouldFail { throw LaunchError.missingExecutable(spec.executable) }
        specs.append(spec)
        self.events.append(events)
        return RestartControl()
    }
}

private final class RestartControl: RunControl {
    func stop() {}
    func send(_ message: String) {}
}
