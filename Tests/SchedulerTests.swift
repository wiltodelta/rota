@testable import RotaCore
import XCTest

private final class FakeControl: RunControl {
    var stopped = false
    var sent: [String] = []
    func stop() { stopped = true }
    func send(_ message: String) { sent.append(message) }
}

private final class FakeLauncher: RoutineLaunching {
    var specs: [LaunchSpec] = []
    var events: [RunEvents] = []
    var completions: [(RunOutcome) -> Void] { events.map(\.finished) }
    var controls: [FakeControl] = []
    var failure: Error?
    /// Reports this session from inside `launch`, as a runner that spins the run loop does.
    var sessionDuringLaunch: String?

    func launch(_ spec: LaunchSpec, events: RunEvents) throws -> RunControl {
        if let failure { throw failure }
        specs.append(spec)
        self.events.append(events)
        if let sessionDuringLaunch { events.session(sessionDuringLaunch) }
        let control = FakeControl()
        controls.append(control)
        return control
    }
}

private final class RecordingNotifier: RunNotifying {
    var outcomes: [RunOutcome] = []
    var paused: [String] = []
    var added: [String] = []
    func runEnded(_ record: RunRecord, routine: Routine) { outcomes.append(record.outcome) }
    func routinePaused(_ routine: Routine, failures: Int) { paused.append(routine.id) }
    func routineAdded(_ routine: Routine) { added.append(routine.id) }
}

@MainActor
final class SchedulerTests: XCTestCase {
    private var directory: URL!
    private var launcher: FakeLauncher!
    private var notifier: RecordingNotifier!
    private var scheduler: Scheduler!
    private var clock = Date(timeIntervalSince1970: 0)

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        launcher = FakeLauncher()
        notifier = RecordingNotifier()
        clock = makeDate(hour: 9, minute: 0)
        scheduler = Scheduler(location: StorageLocation(root: directory, logs: directory.appendingPathComponent("logs")),
                              launcher: launcher)
        scheduler.calendar = calendar
        scheduler.now = { [unowned self] in clock }
        scheduler.executable = { "/bin/\($0.rawValue)" }
        scheduler.notifier = notifier
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    private func makeDate(day: Int = 9, hour: Int, minute: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    private func addDailyRoutine(enabled: Bool = true) -> Routine {
        let routine = Routine(id: "report", name: "Report", workingDirectory: "/p", schedule: "0 10 * * *",
                              harness: .codex, enabled: enabled, prompt: "go", timeLimitMinutes: 30)
        scheduler.save(routine)
        return routine
    }

    func testSavingAnEnabledRoutineSchedulesItsNextSlot() {
        _ = addDailyRoutine()
        XCTAssertEqual(scheduler.routine("report")?.nextFire, makeDate(hour: 10, minute: 0))
        scheduler.setEnabled(false, for: "report")
        XCTAssertNil(scheduler.routine("report")?.nextFire)
    }

    func testFiresWhenDueAndBuildsTheHarnessCommand() throws {
        _ = addDailyRoutine()
        clock = makeDate(hour: 9, minute: 59)
        scheduler.tick()
        XCTAssertTrue(launcher.specs.isEmpty)

        clock = makeDate(hour: 10, minute: 0)
        scheduler.tick()
        let spec = try XCTUnwrap(launcher.specs.first)
        XCTAssertEqual(spec.executable, "/bin/codex")
        XCTAssertEqual(spec.mode, .codexDaemon)
        XCTAssertEqual(spec.workingDirectory, "/p")
        XCTAssertEqual(spec.timeout, 30 * 60)
        XCTAssertNotNil(scheduler.active["report"])
        XCTAssertEqual(scheduler.routine("report")?.nextFire, makeDate(day: 10, hour: 10, minute: 0))

        launcher.completions[0](.succeeded)
        XCTAssertNil(scheduler.active["report"])
        XCTAssertEqual(scheduler.history.records(for: "report").map(\.outcome), [.succeeded])
        XCTAssertEqual(notifier.outcomes, [.succeeded])
    }

    func testDisabledRoutineNeverFires() {
        _ = addDailyRoutine(enabled: false)
        clock = makeDate(hour: 10, minute: 0)
        scheduler.tick()
        XCTAssertTrue(launcher.specs.isEmpty)
    }

    func testMissedSlotsRunOnceLateAsACatchUp() throws {
        _ = addDailyRoutine()
        // Three daily slots passed while the Mac slept: one run, marked as a catch-up.
        clock = makeDate(day: 12, hour: 9, minute: 0)
        scheduler.tick()
        XCTAssertEqual(launcher.specs.count, 1)
        XCTAssertEqual(scheduler.active["report"]?.trigger, .catchUp)
        XCTAssertEqual(scheduler.routine("report")?.nextFire, makeDate(day: 12, hour: 10, minute: 0))
        launcher.completions[0](.succeeded)
        scheduler.tick()
        XCTAssertEqual(launcher.specs.count, 1, "no second catch-up")
    }

    func testOnTimeSlotIsScheduledNotCatchUp() {
        _ = addDailyRoutine()
        clock = makeDate(hour: 10, minute: 1)
        scheduler.tick()
        XCTAssertEqual(scheduler.active["report"]?.trigger, .scheduled)
    }

    func testSlotMissedBeyondGraceIsSkippedNotRun() {
        _ = addDailyRoutine()
        clock = makeDate(day: 17, hour: 10, minute: 1)
        scheduler.tick()
        XCTAssertTrue(launcher.specs.isEmpty)
        guard case .skipped = scheduler.history.records(for: "report").first?.outcome else {
            return XCTFail("expected a skipped record")
        }
        XCTAssertEqual(scheduler.routine("report")?.nextFire, makeDate(day: 18, hour: 10, minute: 0))
    }

    func testFiveFailuresInARowPauseTheRoutine() {
        _ = addDailyRoutine()
        for day in 9..<14 {
            clock = makeDate(day: day, hour: 10, minute: 0)
            scheduler.tick()
            launcher.completions.last?(.failed(exitCode: 1))
            if day < 13 { XCTAssertEqual(scheduler.routine("report")?.enabled, true, "day \(day)") }
        }
        XCTAssertEqual(scheduler.routine("report")?.enabled, false)
        XCTAssertEqual(notifier.paused, ["report"])
    }

    func testOverlapSkipsAndManualFailuresDoNotPause() {
        let routine = addDailyRoutine()
        for _ in 0..<5 {
            scheduler.run(routine, trigger: .manual)
            launcher.completions.last?(.failed(exitCode: 1))
        }
        XCTAssertEqual(scheduler.routine("report")?.enabled, true)

        // A long run overlapping five slots: five skips, still on.
        var minutely = routine
        minutely.schedule = "* * * * *"
        scheduler.save(minutely)
        clock = clock.addingTimeInterval(60)
        scheduler.tick()
        for _ in 0..<5 {
            clock = clock.addingTimeInterval(60)
            scheduler.tick()
        }
        launcher.completions.last?(.failed(exitCode: 1))
        XCTAssertEqual(scheduler.routine("report")?.enabled, true)
        XCTAssertTrue(notifier.outcomes.filter { if case .skipped = $0 { return true }; return false }.isEmpty,
                      "overlap skips do not notify")
    }

    func testSkippedSlotsStayOutOfTheSessionsList() {
        _ = addDailyRoutine()
        clock = makeDate(day: 17, hour: 10, minute: 1)
        scheduler.tick()
        XCTAssertEqual(scheduler.history.records(for: "report").count, 1, "the skip is recorded")
        XCTAssertTrue(scheduler.allRecords().isEmpty, "but is not a session")
        XCTAssertEqual(scheduler.unreadCount, 0)
    }

    func testFinishedSessionIsUnreadUntilOpened() throws {
        let routine = addDailyRoutine()
        scheduler.run(routine, trigger: .manual)
        XCTAssertEqual(scheduler.unreadCount, 0, "a running session is not unread")
        launcher.completions[0](.succeeded)
        let record = try XCTUnwrap(scheduler.history.records(for: "report").first)
        XCTAssertTrue(record.isUnread)
        XCTAssertEqual(scheduler.unreadCount, 1)
        clock = clock.addingTimeInterval(60)
        scheduler.markRead(record)
        XCTAssertFalse(try XCTUnwrap(scheduler.history.records(for: "report").first).isUnread)
        XCTAssertEqual(scheduler.unreadCount, 0)
    }

    func testOverlappingSlotIsSkippedWhileThePreviousRunGoes() {
        var routine = addDailyRoutine()
        routine.schedule = "* * * * *"
        scheduler.save(routine)
        clock = makeDate(hour: 9, minute: 1)
        scheduler.tick()
        clock = makeDate(hour: 9, minute: 2)
        scheduler.tick()
        XCTAssertEqual(launcher.specs.count, 1)
        let outcomes = scheduler.history.records(for: "report").map(\.outcome)
        XCTAssertEqual(outcomes.first, .skipped("the previous run was still going"))
    }

    func testStopReachesTheRunningProcess() {
        let routine = addDailyRoutine()
        scheduler.run(routine, trigger: .manual)
        scheduler.stop("report")
        XCTAssertTrue(launcher.controls[0].stopped)
        launcher.completions[0](.cancelled)
        XCTAssertEqual(scheduler.history.records(for: "report").first?.trigger, .manual)
        XCTAssertEqual(notifier.outcomes, [.cancelled])
    }

    func testStopAllReachesEveryRunningProcess() {
        let first = addDailyRoutine()
        let second = Routine(id: "digest", name: "Digest", workingDirectory: "/p", schedule: "0 10 * * *",
                             harness: .shell, enabled: true, prompt: "true")
        scheduler.save(second)
        scheduler.run(first, trigger: .manual)
        scheduler.run(second, trigger: .manual)
        scheduler.stopAll()
        XCTAssertEqual(launcher.controls.map(\.stopped), [true, true])
    }

    func testLaunchFailureIsRecorded() {
        let routine = addDailyRoutine()
        launcher.failure = LaunchError.missingExecutable("/bin/codex")
        scheduler.run(routine, trigger: .manual)
        XCTAssertNil(scheduler.active["report"])
        XCTAssertEqual(scheduler.history.records(for: "report").first?.outcome,
                       .launchFailed("no executable at /bin/codex"))
    }

    func testRoutinesSurviveARestart() {
        _ = addDailyRoutine()
        let reopened = Scheduler(location: StorageLocation(root: directory, logs: directory),
                                 launcher: launcher)
        XCTAssertEqual(reopened.routines.map(\.id), ["report"])
        XCTAssertEqual(reopened.routines.first?.nextFire, makeDate(hour: 10, minute: 0))
    }

    func testClaudeRunTakesMessagesAndResumesWithItsSession() throws {
        var routine = addDailyRoutine()
        routine.harness = .claude
        scheduler.save(routine)
        scheduler.run(routine, trigger: .manual)
        let spec = try XCTUnwrap(launcher.specs.first)
        XCTAssertEqual(spec.mode, .claudeStream)
        XCTAssertEqual(spec.prompt, "go")
        XCTAssertFalse(spec.arguments.contains("--resume"))
        launcher.events[0].session("abc123")
        let running = try XCTUnwrap(scheduler.active["report"])
        XCTAssertEqual(running.sessionID, "abc123")
        XCTAssertTrue(scheduler.canMessage(running))
        XCTAssertNil(scheduler.terminalCommand(for: running))
        launcher.completions[0](.succeeded)
        let finished = try XCTUnwrap(scheduler.history.records(for: "report").first)
        XCTAssertEqual(scheduler.terminalCommand(for: finished)?.arguments, ["--resume", "abc123"])
        scheduler.message("and then?", to: finished)
        XCTAssertEqual(Array(try XCTUnwrap(launcher.specs.last).arguments.suffix(2)), ["--resume", "abc123"])
    }

    func testARunTakesAsLongAsItNeedsUnlessTheRoutineSetsALimit() throws {
        var routine = addDailyRoutine()
        routine.timeLimitMinutes = nil
        scheduler.save(routine)
        scheduler.run(routine, trigger: .manual)
        XCTAssertNil(try XCTUnwrap(launcher.specs.last).timeout)
        launcher.completions[0](.succeeded)
        routine.timeLimitMinutes = 90
        scheduler.save(routine)
        scheduler.run(routine, trigger: .manual)
        XCTAssertEqual(try XCTUnwrap(launcher.specs.last).timeout, 90 * 60)
        XCTAssertNil(Routine(id: "r", name: "R", workingDirectory: "/p", schedule: "0 9 * * *", prompt: "go")
            .timeLimitMinutes, "a new routine has no limit")
    }

    func testTheRoutinesModelReachesTheRunAndItsContinuation() throws {
        var routine = addDailyRoutine()
        routine.model = "gpt-6-luna"
        routine.effort = "high"
        scheduler.save(routine)
        scheduler.run(routine, trigger: .manual)
        launcher.events[0].session("thread-1")
        launcher.completions[0](.succeeded)
        let finished = try XCTUnwrap(scheduler.history.records(for: "report").first)
        scheduler.message("and then?", to: finished)
        XCTAssertEqual(launcher.specs.map(\.model), ["gpt-6-luna", "gpt-6-luna"])
        XCTAssertEqual(launcher.specs.map(\.effort), ["high", "high"])
    }

    func testCodexRunTakesMessagesWhileRunningAndContinuesAfter() throws {
        let routine = addDailyRoutine()
        scheduler.run(routine, trigger: .manual)
        XCTAssertEqual(launcher.specs.first?.mode, .codexDaemon)
        XCTAssertNil(launcher.specs.first?.resume)
        launcher.events[0].session("thread-1")
        let running = try XCTUnwrap(scheduler.active["report"])
        XCTAssertTrue(scheduler.canMessage(running))
        XCTAssertNil(scheduler.terminalCommand(for: running))
        scheduler.message("also check the logs", to: running)
        XCTAssertEqual(launcher.controls[0].sent, ["also check the logs"])
        launcher.completions[0](.succeeded)

        // Afterwards a message continues the same session as a run of its own.
        let finished = try XCTUnwrap(scheduler.history.records(for: "report").first)
        XCTAssertEqual(scheduler.terminalCommand(for: finished)?.arguments, ["resume", "thread-1"])
        scheduler.message("one more thing", to: finished)
        let follow = try XCTUnwrap(launcher.specs.last)
        XCTAssertEqual(launcher.specs.count, 2)
        XCTAssertEqual(follow.resume, "thread-1")
        XCTAssertEqual(follow.prompt, "one more thing")
        XCTAssertEqual(follow.log.path, finished.logPath)
        XCTAssertEqual(scheduler.active["report"]?.id, finished.id, "the same session is running again")
        XCTAssertEqual(scheduler.history.records(for: "report").count, 1)
        launcher.completions[1](.succeeded)
        XCTAssertEqual(scheduler.history.records(for: "report").first?.outcome, .succeeded)
    }

    func testSessionReportedDuringLaunchIsKept() throws {
        let routine = addDailyRoutine()
        launcher.sessionDuringLaunch = "early-1"
        scheduler.run(routine, trigger: .manual)
        XCTAssertEqual(scheduler.history.records(for: "report").first?.sessionID, "early-1")
        XCTAssertEqual(scheduler.active["report"]?.sessionID, "early-1")
    }

    func testFinishedSessionWaitsWhileAnotherRunOfTheRoutineWorks() throws {
        let routine = addDailyRoutine()
        scheduler.run(routine, trigger: .manual)
        launcher.events[0].session("thread-1")
        launcher.completions[0](.succeeded)
        let old = try XCTUnwrap(scheduler.history.records(for: "report").first)
        scheduler.run(routine, trigger: .manual)
        XCTAssertFalse(scheduler.canMessage(old))
        scheduler.message("hello", to: old)
        XCTAssertEqual(launcher.specs.count, 2, "no third launch")
    }

    func testShellRoutineRunsItsCommandWithoutSkillScanning() throws {
        var routine = addDailyRoutine()
        routine.harness = .shell
        routine.prompt = "echo PushNotification"
        scheduler.save(routine)
        XCTAssertTrue(scheduler.requirements(of: routine).isEmpty)
        scheduler.run(routine, trigger: .manual)
        XCTAssertEqual(launcher.specs.first?.prompt, "echo PushNotification")
        XCTAssertEqual(launcher.specs.first?.mode, .screen)
    }

    func testDeleteRemovesRoutineAndHistory() {
        let routine = addDailyRoutine()
        scheduler.run(routine, trigger: .manual)
        launcher.completions[0](.succeeded)
        scheduler.delete("report")
        XCTAssertNil(scheduler.routine("report"))
        XCTAssertTrue(scheduler.history.records(for: "report").isEmpty)
    }
}
