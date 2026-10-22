@testable import RotaCore
import XCTest

private final class Control: RunControl {
    func stop() {}
}

private final class Launcher: RoutineLaunching {
    var specs: [LaunchSpec] = []
    var events: [RunEvents] = []
    func launch(_ spec: LaunchSpec, events: RunEvents) throws -> RunControl {
        specs.append(spec)
        self.events.append(events)
        return Control()
    }
}

/// Routines the Mac cut off: by sleeping, by having no network on waking, by shutting down.
@MainActor
final class ResilienceTests: XCTestCase {
    private var directory: URL!
    private var launcher: Launcher!
    private var scheduler: Scheduler!
    private var clock = Date(timeIntervalSince1970: 1_791_000_000)
    private var online = true
    private var serviceAnswers = true

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        launcher = Launcher()
        scheduler = makeScheduler()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func makeScheduler(alive: Bool = false) -> Scheduler {
        let scheduler = Scheduler(location: StorageLocation(root: directory,
                                                   logs: directory.appendingPathComponent("logs")),
                                  launcher: launcher)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        scheduler.calendar = calendar
        scheduler.now = { [unowned self] in clock }
        scheduler.executable = { "/bin/\($0.rawValue)" }
        scheduler.isOnline = { [unowned self] in online }
        scheduler.sessionAlive = { _ in alive }
        scheduler.probe = { [unowned self] _, done in done(serviceAnswers) }
        return scheduler
    }

    private func add(_ harness: Harness = .codex, schedule: String = "0 * * * *") -> Routine {
        let routine = Routine(id: "digest", name: "Digest", workingDirectory: directory.path, schedule: schedule,
                              harness: harness, enabled: true, prompt: "Summarize.")
        scheduler.save(routine)
        return routine
    }

    /// Starts a run that has reported its session, as a real one does.
    private func startRun(_ routine: Routine) {
        scheduler.run(routine, trigger: .manual)
        launcher.events.last?.session("thread-1")
    }

    func testADueSlotWaitsWhileOfflineAndRunsOnceOnline() throws {
        _ = add()
        clock = clock.addingTimeInterval(3 * 3600)
        online = false
        scheduler.tick()
        XCTAssertTrue(launcher.specs.isEmpty, "no run starts without a network")
        online = true
        scheduler.networkBecameAvailable()
        XCTAssertEqual(launcher.specs.count, 1)
        XCTAssertEqual(scheduler.active["digest"]?.trigger, .catchUp)
    }

    func testARunCutOffBySleepContinuesWhenTheNetworkIsBack() throws {
        let routine = add()
        startRun(routine)
        scheduler.systemWillSleep()
        online = false
        launcher.events.last?.finished(.failed(exitCode: 1))
        XCTAssertEqual(launcher.specs.count, 1, "waits for the network")
        online = true
        scheduler.networkBecameAvailable()
        XCTAssertEqual(launcher.specs.count, 2)
        XCTAssertEqual(launcher.specs.last?.resume, "thread-1")
        XCTAssertEqual(launcher.specs.last?.prompt, Scheduler.resumeMessage)
        XCTAssertEqual(scheduler.active["digest"]?.resumes, 1)
    }

    func testAFailureNotCausedByTheMacIsLeftAlone() {
        let routine = add()
        startRun(routine)
        launcher.events.last?.finished(.failed(exitCode: 1))
        scheduler.networkBecameAvailable()
        XCTAssertEqual(launcher.specs.count, 1)
    }

    func testRunsOpenAtShutdownContinueOnTheNextLaunch() {
        let routine = add()
        startRun(routine)
        // The Mac shut down: nothing finished the run, and Rota starts again later.
        scheduler = makeScheduler()
        scheduler.start()
        XCTAssertEqual(launcher.specs.count, 2)
        XCTAssertEqual(launcher.specs.last?.resume, "thread-1")
        XCTAssertEqual(scheduler.active[routine.id]?.resumes, 1)
    }

    func testAClaudeSessionStillAliveInItsTerminalIsNotStartedTwice() {
        let routine = add(.claude)
        startRun(routine)
        scheduler = makeScheduler(alive: true)
        scheduler.start()
        XCTAssertEqual(launcher.specs.count, 1)
        XCTAssertEqual(scheduler.history.records(for: routine.id).first?.outcome, .interrupted)
    }

    func testSurvivingClaudeBlocksScheduledManualAndChatRunsUntilItExits() async throws {
        let routine = add(.claude, schedule: "* * * * *")
        startRun(routine)
        scheduler = makeScheduler(alive: true)
        scheduler.start()
        let record = try XCTUnwrap(scheduler.history.records(for: routine.id).first)
        clock = clock.addingTimeInterval(120)
        scheduler.tick()
        scheduler.run(routine, trigger: .manual)
        XCTAssertFalse(scheduler.message("Do not start another writer", to: record))
        let continued = await scheduler.continueInTerminal(record)
        XCTAssertFalse(continued)
        XCTAssertEqual(launcher.specs.count, 1)
        scheduler.sessionAlive = { _ in false }
        clock = clock.addingTimeInterval(60)
        scheduler.tick()
        XCTAssertEqual(launcher.specs.count, 2)
    }

    func testAShellCommandIsNeverRunTwiceBehindTheUsersBack() {
        let routine = add(.shell)
        startRun(routine)
        scheduler = makeScheduler()
        scheduler.start()
        XCTAssertEqual(launcher.specs.count, 1)
    }

    func testContinuationsStopAtTheLimit() {
        let routine = add()
        startRun(routine)
        for _ in 0..<Scheduler.resumeLimit {
            scheduler.systemWillSleep()
            launcher.events.last?.finished(.interrupted)
        }
        XCTAssertEqual(launcher.specs.count, 1 + Scheduler.resumeLimit)
        scheduler.systemWillSleep()
        launcher.events.last?.finished(.interrupted)
        XCTAssertEqual(launcher.specs.count, 1 + Scheduler.resumeLimit, "no more than the limit")
    }

    /// The log the run wrote, as the runner would.
    private func log(_ text: String) throws {
        let path = try XCTUnwrap(scheduler.active["digest"]?.logPath)
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                withIntermediateDirectories: true)
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
    }

    func testANetworkErrorWithoutSleepContinuesOnceTheServiceAnswers() throws {
        let routine = add()
        startRun(routine)
        try log("[you] Summarize.\nReading the files.\n[error] API Error: Connection error.")
        serviceAnswers = false
        launcher.events.last?.finished(.failed(exitCode: 1))
        XCTAssertEqual(launcher.specs.count, 1, "the service does not answer yet")
        serviceAnswers = true
        scheduler.networkBecameAvailable()
        XCTAssertEqual(launcher.specs.count, 2)
        XCTAssertEqual(launcher.specs.last?.resume, "thread-1")
    }

    func testARunThatFailedOnTheNetworkBeforeItsSessionRunsAgain() throws {
        let routine = add()
        scheduler.run(routine, trigger: .scheduled)
        try log("[you] Summarize.\n[error] getaddrinfo ENOTFOUND api.openai.com")
        launcher.events.last?.finished(.failed(exitCode: 1))
        XCTAssertEqual(launcher.specs.count, 2, "nothing was done yet, so the whole run starts again")
        XCTAssertNil(launcher.specs.last?.resume)
        XCTAssertEqual(launcher.specs.last?.prompt, "Summarize.")
        XCTAssertEqual(scheduler.active["digest"]?.trigger, .scheduled)
        for _ in 0..<Scheduler.resumeLimit {
            try log("[error] getaddrinfo ENOTFOUND api.openai.com")
            launcher.events.last?.finished(.failed(exitCode: 1))
        }
        XCTAssertEqual(launcher.specs.count, 1 + Scheduler.resumeLimit, "reruns stop at the limit")
    }

    func testAntigravityReadTimeoutContinuesTheSameSessionAndStopsAtTheLimit() throws {
        let routine = add(.antigravity)
        startRun(routine)
        let failure = "[error] API error (attempt 1): request failed: "
            + "Post \"https://daily-cloudcode-pa.googleapis.com/v1internal:streamGenerateContent?alt=sse\": "
            + "read tcp [2001:db8::1]:61510->[2001:db8::2]:443: read: operation timed out"
        // The network is already back and no sleep notification was observed.
        // Recovery must recognize the CLI's actual error wording on its own.
        for attempt in 1...Scheduler.resumeLimit {
            try log(failure)
            launcher.events.last?.finished(.failed(exitCode: 1))
            XCTAssertEqual(launcher.specs.count, 1 + attempt)
            XCTAssertEqual(launcher.specs.last?.mode, .antigravityStream)
            XCTAssertEqual(launcher.specs.last?.resume, "thread-1")
            XCTAssertEqual(launcher.specs.last?.prompt, Scheduler.resumeMessage)
            XCTAssertEqual(scheduler.active[routine.id]?.resumes, attempt)
        }
        try log(failure)
        launcher.events.last?.finished(.failed(exitCode: 1))
        scheduler.networkBecameAvailable()
        XCTAssertEqual(launcher.specs.count, 1 + Scheduler.resumeLimit)
        XCTAssertEqual(scheduler.history.records(for: routine.id).first?.outcome, .failed(exitCode: 1))
    }

    func testAntigravityThatRecoversDuringItsTurnIsNotContinuedAgain() throws {
        let routine = add(.antigravity)
        startRun(routine)
        try log("[error] read tcp [2001:db8::1]:61510->[2001:db8::2]:443: read: operation timed out")
        launcher.events.last?.finished(.succeeded)
        scheduler.networkBecameAvailable()
        XCTAssertEqual(launcher.specs.count, 1)
        XCTAssertEqual(scheduler.history.records(for: routine.id).first?.outcome, .succeeded)
    }

    func testAFailureOnItsOwnWorkIsNotRetried() throws {
        let routine = add()
        startRun(routine)
        try log("[you] Summarize.\n[error] The file does not exist.")
        launcher.events.last?.finished(.failed(exitCode: 1))
        XCTAssertEqual(launcher.specs.count, 1)
    }

    func testNetworkFailuresReadFromWhatTheCLIsWrite() {
        XCTAssertTrue(NetworkFailure.matches("API Error: Connection error."))
        XCTAssertTrue(NetworkFailure.matches("stream disconnected before completion: error sending request"))
        XCTAssertTrue(NetworkFailure.matches("TypeError: fetch failed"))
        XCTAssertTrue(NetworkFailure.matches("read tcp [2001:db8::1]:61510->[2001:db8::2]:443: "
            + "read: operation timed out"))
        XCTAssertTrue(NetworkFailure.matches("read tcp [2001:db8::1]:62411->[2001:db8::2]:443: "
            + "read: no route to host"))
        XCTAssertTrue(NetworkFailure.matches("dial tcp: lookup play.googleapis.com: no such host"))
        XCTAssertFalse(NetworkFailure.matches("The test operation timed out"))
        XCTAssertFalse(NetworkFailure.matches("API error: quota exceeded"))
        XCTAssertFalse(NetworkFailure.matches("API error: unauthorized"))
        XCTAssertFalse(NetworkFailure.matches("Error: tests failed"))
        XCTAssertNil(ServiceProbe.host(for: .shell))
        XCTAssertEqual(ServiceProbe.host(for: .claude)?.host, "api.anthropic.com")
    }
}
