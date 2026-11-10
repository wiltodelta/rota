@testable import RotaCore
import XCTest

private final class ScheduleControl: RunControl {
    func stop() {}
}

private final class ScheduleLauncher: RoutineLaunching {
    var events: [RunEvents] = []
    var beforeLaunch: (() -> Void)?
    var fails = false

    func launch(_ spec: LaunchSpec, events: RunEvents) throws -> RunControl {
        beforeLaunch?()
        self.events.append(events)
        if fails { throw LaunchError.missingExecutable(spec.executable) }
        return ScheduleControl()
    }
}

@MainActor
final class RoutineScheduleTests: XCTestCase {
    private var root: URL!
    private var launcher: ScheduleLauncher!
    private var scheduler: Scheduler!
    private var clock = Date(timeIntervalSince1970: 0)
    private let day: TimeInterval = 24 * 3600
    private var location: StorageLocation { StorageLocation(root: root, logs: root.appendingPathComponent("logs")) }

    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        launcher = ScheduleLauncher()
        clock = Date(timeIntervalSince1970: 8 * 3600)
        reload()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func reload() {
        scheduler = Scheduler(location: location, launcher: launcher)
        scheduler.now = { [unowned self] in clock }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        scheduler.calendar = calendar
        scheduler.executable = { "/synthetic/\($0.rawValue)" }
    }

    private func routine(once: Bool = true, limit: Int? = nil, harness: Harness = .shell) -> Routine {
        Routine(id: "scheduled", name: "Scheduled", workingDirectory: root.path, schedule: "0 10 * * *",
                harness: harness, enabled: true, prompt: "Synthetic work",
                scheduledAt: Date(timeIntervalSince1970: 10 * 3600), repeats: !once, runLimit: limit)
    }

    func testOneTimeSlotsPersistBeforeLaunchForEveryHarnessAndNeverRepeatAfterReload() throws {
        for harness in Harness.allCases {
            var value = routine(harness: harness)
            value.id = harness.rawValue
            scheduler.save(value)
        }
        let file = location.routinesFile
        launcher.beforeLaunch = {
            let saved = try? JSONFile.read([Routine].self, from: file)
            XCTAssertTrue(saved?.contains(where: { $0.isScheduleComplete && $0.scheduledRunCount == 1 }) == true)
        }
        clock = Date(timeIntervalSince1970: 10 * 3600)
        scheduler.tick()
        XCTAssertEqual(launcher.events.count, Harness.allCases.count)
        for value in scheduler.routines {
            XCTAssertFalse(value.enabled)
            XCTAssertTrue(value.isScheduleComplete)
            XCTAssertNil(value.nextFire)
            XCTAssertEqual(value.scheduledRunCount, 1)
        }
        launcher.events.forEach { $0.finished(.succeeded) }
        reload()
        clock += day
        scheduler.tick()
        XCTAssertEqual(launcher.events.count, Harness.allCases.count)
        XCTAssertTrue(scheduler.routines.allSatisfy(\.isScheduleComplete))
    }

    func testTwoScheduledAttemptsExcludeManualRunsAndSkippedBusySlotsAcrossReload() throws {
        scheduler.save(routine(once: false, limit: 2))
        scheduler.run(try XCTUnwrap(scheduler.routine("scheduled")), trigger: .manual)
        XCTAssertEqual(scheduler.routine("scheduled")?.scheduledRunCount, 0)
        launcher.events.last?.finished(.succeeded)
        clock = Date(timeIntervalSince1970: 10 * 3600)
        scheduler.tick()
        launcher.events.last?.finished(.succeeded)
        reload()
        XCTAssertEqual(scheduler.routine("scheduled")?.scheduledRunCount, 1)
        scheduler.run(try XCTUnwrap(scheduler.routine("scheduled")), trigger: .manual)
        clock += day
        scheduler.tick()
        XCTAssertEqual(scheduler.routine("scheduled")?.scheduledRunCount, 1)
        launcher.events.last?.finished(.succeeded)
        clock += day
        scheduler.tick()
        XCTAssertEqual(scheduler.routine("scheduled")?.scheduledRunCount, 2)
        XCTAssertEqual(scheduler.routine("scheduled")?.isScheduleComplete, true)
        XCTAssertFalse(scheduler.setEnabled(true, for: "scheduled"))
        launcher.events.last?.finished(.succeeded)
        scheduler.run(try XCTUnwrap(scheduler.routine("scheduled")), trigger: .manual)
        XCTAssertEqual(scheduler.routine("scheduled")?.scheduledRunCount, 2)
        XCTAssertEqual(launcher.events.count, 5)
    }

    func testOneTimeSlotWaitsForItsExistingSessionAndCatchesUpOnce() throws {
        scheduler.save(routine())
        scheduler.run(try XCTUnwrap(scheduler.routine("scheduled")), trigger: .manual)
        clock = Date(timeIntervalSince1970: 10 * 3600)
        scheduler.tick()
        XCTAssertEqual(launcher.events.count, 1)
        XCTAssertEqual(scheduler.routine("scheduled")?.scheduledRunCount, 0)
        XCTAssertEqual(scheduler.routine("scheduled")?.nextFire, clock)
        launcher.events.last?.finished(.succeeded)
        clock += 300
        scheduler.tick()
        XCTAssertEqual(launcher.events.count, 2)
        XCTAssertEqual(scheduler.records(for: "scheduled").first?.trigger, .catchUp)
        XCTAssertEqual(scheduler.routine("scheduled")?.isScheduleComplete, true)
    }

    func testExpiredOneTimeSlotIsRecordedOnceAndCompletesWithoutAnAttempt() {
        scheduler.save(routine())
        clock = Date(timeIntervalSince1970: 10 * 3600) + Scheduler.missedRunGrace + 1
        scheduler.tick()
        XCTAssertTrue(launcher.events.isEmpty)
        XCTAssertEqual(scheduler.routine("scheduled")?.scheduledRunCount, 0)
        XCTAssertEqual(scheduler.routine("scheduled")?.isScheduleComplete, true)
        XCTAssertEqual(scheduler.records(for: "scheduled").filter(\.isSkip).count, 1)
        scheduler.tick()
        XCTAssertEqual(scheduler.records(for: "scheduled").filter(\.isSkip).count, 1)
    }

    func testLaunchFailureConsumesItsAttemptAndLeavesItsResult() {
        scheduler.save(routine())
        launcher.fails = true
        clock = Date(timeIntervalSince1970: 10 * 3600)
        scheduler.tick()
        XCTAssertEqual(scheduler.routine("scheduled")?.isScheduleComplete, true)
        guard case .launchFailed = scheduler.records(for: "scheduled").first?.outcome else {
            return XCTFail("Expected the failed launch to remain in history")
        }
        scheduler.tick()
        XCTAssertEqual(launcher.events.count, 1)
    }

    func testNetworkRecoveryAfterTheFinalSlotDoesNotConsumeAnotherScheduledAttempt() {
        var online = true
        scheduler.isOnline = { online }
        scheduler.probe = { _, done in done(true) }
        scheduler.save(routine(harness: .codex))
        clock = Date(timeIntervalSince1970: 10 * 3600)
        scheduler.tick()
        online = false
        launcher.events.last?.finished(.failed(exitCode: 1))
        XCTAssertEqual(scheduler.pendingReruns["scheduled"], .scheduled)
        online = true
        scheduler.networkBecameAvailable()
        XCTAssertEqual(launcher.events.count, 2)
        XCTAssertNotNil(scheduler.activeRecord(for: "scheduled"))
        XCTAssertEqual(scheduler.routine("scheduled")?.scheduledRunCount, 1)
        XCTAssertEqual(scheduler.routine("scheduled")?.isScheduleComplete, true)
    }

    func testUnwritableReservationNeverLaunchesAndKeepsTheDueSlot() throws {
        scheduler.save(routine())
        try FileManager.default.removeItem(at: location.routinesFile)
        try FileManager.default.createDirectory(at: location.routinesFile, withIntermediateDirectories: false)
        clock = Date(timeIntervalSince1970: 10 * 3600)
        scheduler.tick()
        XCTAssertTrue(launcher.events.isEmpty)
        XCTAssertEqual(scheduler.routine("scheduled")?.scheduledRunCount, 0)
        XCTAssertEqual(scheduler.routine("scheduled")?.nextFire, clock)
        XCTAssertNotNil(scheduler.lastError)
    }

    func testCosmeticEditsKeepProgressAndSchedulingEditsStartANewCount() throws {
        scheduler.save(routine(once: false, limit: 2))
        clock = Date(timeIntervalSince1970: 10 * 3600)
        scheduler.tick()
        launcher.events.last?.finished(.succeeded)
        var value = try XCTUnwrap(scheduler.routine("scheduled"))
        value.name = "Renamed"
        value.scheduledRunCount = 0
        scheduler.save(value)
        XCTAssertEqual(scheduler.routine("scheduled")?.scheduledRunCount, 1)
        value = try XCTUnwrap(scheduler.routine("scheduled"))
        value.runLimit = 3
        scheduler.save(value)
        XCTAssertEqual(scheduler.routine("scheduled")?.scheduledRunCount, 0)
        XCTAssertFalse(try XCTUnwrap(scheduler.routine("scheduled")).isScheduleComplete)
    }

    func testLegacyFilesRemainRecurringAndAStartBoundDelaysTheFirstCronSlot() throws {
        let data = Data(#"""
        {"id":"old","name":"Old","workingDirectory":"/tmp","schedule":"0 10 * * *",
         "harness":"shell","enabled":true,"prompt":"true"}
        """#.utf8)
        let value = try JSONFile.decoder.decode(Routine.self, from: data)
        XCTAssertTrue(value.repeats)
        XCTAssertNil(value.runLimit)
        XCTAssertEqual(value.scheduledRunCount, 0)
        var bounded = routine(once: false)
        bounded.scheduledAt = Date(timeIntervalSince1970: 2 * day + 11 * 3600)
        XCTAssertEqual(bounded.nextScheduledFire(after: clock, calendar: scheduler.calendar),
                       Date(timeIntervalSince1970: 3 * day + 10 * 3600))
    }

    func testControlAndCLIExposeDatesLimitsAndCompletedState() throws {
        let (_, params) = try ControlCLI.request("add", ControlCLI.Arguments([
            "add", "once", "--folder", root.path, "--harness", "shell", "--prompt", "true",
            "--at", "1970-01-01T12:00:00+02:00"
        ]))
        let json = try XCTUnwrap(try scheduler.control("routines.create", params).get() as? [String: Any])
        XCTAssertEqual(json["repeats"] as? Bool, false)
        XCTAssertEqual(json["remainingRuns"] as? Int, 1)
        XCTAssertEqual(scheduler.routine("once")?.scheduledAt, Date(timeIntervalSince1970: 10 * 3600))
        clock = Date(timeIntervalSince1970: 10 * 3600)
        scheduler.tick()
        let completed = try XCTUnwrap(try scheduler.control("routines.get", ["id": "once"]).get() as? [String: Any])
        XCTAssertEqual(completed["scheduleState"] as? String, "completed")
        XCTAssertEqual(completed["remainingRuns"] as? Int, 0)
        let (_, repeatParams) = try ControlCLI.request("update", ControlCLI.Arguments([
            "update", "once", "--schedule", "0 10 * * *", "--repeat", "--runs", "2"
        ]))
        _ = try scheduler.control("routines.update", repeatParams).get()
        XCTAssertEqual(scheduler.routine("once")?.repeats, true)
        XCTAssertEqual(scheduler.routine("once")?.runLimit, 2)
        XCTAssertEqual(scheduler.routine("once")?.scheduledRunCount, 0)
        let (_, unlimited) = try ControlCLI.request("update", ControlCLI.Arguments([
            "update", "once", "--no-run-limit"
        ]))
        _ = try scheduler.control("routines.update", unlimited).get()
        XCTAssertNil(scheduler.routine("once")?.runLimit)
    }

    func testInvalidDatesAndLimitsAreRejected() {
        var value = routine()
        value.scheduledAt = nil
        XCTAssertNotNil(value.scheduleProblem(now: clock))
        value.scheduledAt = clock
        XCTAssertNotNil(value.scheduleProblem(now: clock))
        value = routine(once: false, limit: 0)
        XCTAssertNotNil(value.scheduleProblem(now: clock))
        for date in ["tomorrow", "1970-01-01", "1970-01-01T10:00:00"] {
            XCTAssertThrowsError(try scheduler.control("routines.create", [
                "id": "bad", "workingDirectory": root.path, "scheduledAt": date,
                "prompt": "true", "harness": "shell"
            ]).get())
        }
        XCTAssertThrowsError(try ControlCLI.request("add", ControlCLI.Arguments(["add", "x", "--once", "--repeat"])))
        XCTAssertThrowsError(try ControlCLI.request("add", ControlCLI.Arguments([
            "add", "x", "--runs", "2", "--no-run-limit"
        ])))
    }
}
