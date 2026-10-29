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

    func testRestartRejectsOverlapShellAndTheSameHarness() async throws {
        let same = await scheduler.restart(source, with: source.harness)
        let shell = await scheduler.restart(source, with: .shell)
        XCTAssertNil(same)
        XCTAssertNil(shell)
        scheduler.run(routine, trigger: .manual)
        let overlap = await scheduler.restart(source, with: .claude)
        XCTAssertNil(overlap)
        XCTAssertEqual(launcher.specs.count, 1)
        launcher.events.last?.finished(.succeeded)
        var shellSource = try XCTUnwrap(source)
        shellSource.harness = .shell
        scheduler.saveRecord(shellSource)
        let fromShell = await scheduler.restart(shellSource, with: .claude)
        XCTAssertNil(fromShell)
        XCTAssertEqual(launcher.specs.count, 1)
    }

    func testRestartRejectsUnknownNativeStateAndStaleRunningRecord() async throws {
        scheduler.survivingSessions[routine.id] = source
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
        XCTAssertNil(scheduler.active[routine.id])
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
