@testable import Rota
@testable import RotaCore
import XCTest

private func makeLACalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
    calendar.firstWeekday = 1
    return calendar
}

private func localDate(_ text: String, calendar: Calendar) -> Date {
    let formatter = DateFormatter()
    formatter.calendar = calendar
    formatter.timeZone = calendar.timeZone
    formatter.dateFormat = "yyyy-MM-dd HH:mm"
    return formatter.date(from: text)!
}

final class ScheduleCalendarTests: XCTestCase {
    private let calendar = makeLACalendar()

    private func date(_ text: String) -> Date { localDate(text, calendar: calendar) }

    private func makeRoutine(
        id: String = "digest", name: String = "Digest",
        schedule: String = "0 9 * * *", enabled: Bool = true
    ) -> Routine {
        Routine(
            id: id, name: name, workingDirectory: "/tmp/project",
            schedule: schedule, harness: .codex, enabled: enabled, prompt: "Summarize."
        )
    }

    func testWeekMonthAndAgendaIntervalsRespectFirstWeekdayAndMonthBounds() {
        let anchor = date("2026-11-18 14:30") // Wednesday
        let sundayWeek = ScheduleCalendar.weekInterval(containing: anchor, calendar: calendar)
        XCTAssertEqual(sundayWeek.start, date("2026-11-15 00:00"))
        XCTAssertEqual(sundayWeek.end, date("2026-11-22 00:00"))

        var mondayCalendar = calendar
        mondayCalendar.firstWeekday = 2
        let mondayWeek = ScheduleCalendar.weekInterval(containing: anchor, calendar: mondayCalendar)
        XCTAssertEqual(mondayWeek.start, date("2026-11-16 00:00"))
        XCTAssertEqual(mondayWeek.end, date("2026-11-23 00:00"))

        let octAnchor = date("2026-10-15 12:00")
        let (octMonth, octGrid) = ScheduleCalendar.monthGridInterval(containing: octAnchor, calendar: calendar)
        let query = ScheduleCalendar.Query(
            interval: octGrid, currentMonth: octMonth, now: octAnchor, calendar: calendar
        )
        let days = ScheduleCalendar.days(query: query, routines: [], records: [])
        XCTAssertEqual(days.count, 35)
        XCTAssertEqual(days.first?.id, "2026-09-27")
        XCTAssertEqual(days.first?.isCurrentMonth, false)
        XCTAssertEqual(days.first { $0.id == "2026-10-01" }?.isCurrentMonth, true)
        XCTAssertEqual(days.first { $0.id == "2026-10-15" }?.isToday, true)
        XCTAssertEqual(days.last?.id, "2026-10-31")

        let agenda = ScheduleCalendar.agendaInterval(startingAt: anchor, days: 14, calendar: calendar)
        XCTAssertEqual(agenda.start, date("2026-11-18 00:00"))
        XCTAssertEqual(agenda.end, date("2026-12-02 00:00"))
        XCTAssertEqual(ScheduleCalendar.stepped(anchor, mode: .week, by: 1, calendar: calendar),
                       date("2026-11-25 14:30"))
        XCTAssertEqual(ScheduleCalendar.stepped(anchor, mode: .agenda, by: 1, calendar: calendar),
                       date("2026-12-02 14:30"))
    }

    func testMultiSlotCronProjectsRemainingTodayAndFullTomorrow() throws {
        let now = date("2026-11-16 15:00")
        var routine = makeRoutine(schedule: "0 9,14,18 * * *")
        routine.nextFire = try CronSchedule(routine.schedule).next(after: now, calendar: calendar)
        let interval = ScheduleCalendar.agendaInterval(startingAt: now, days: 2, calendar: calendar)
        let query = ScheduleCalendar.Query(interval: interval, now: now, calendar: calendar)
        let days = ScheduleCalendar.days(query: query, routines: [routine], records: [])

        XCTAssertEqual(days.count, 2)
        XCTAssertEqual(days[0].entries.map(\.start), [date("2026-11-16 18:00")])
        XCTAssertTrue(days[0].entries.allSatisfy { !$0.isFrequent && !$0.isPaused })
        XCTAssertEqual(days[1].entries.map(\.start), [
            date("2026-11-17 09:00"),
            date("2026-11-17 14:00"),
            date("2026-11-17 18:00")
        ])
    }

    func testHighFrequencyCronSummarizesDailyBurstWithoutFloodingGrid() throws {
        let now = date("2026-11-16 23:20")
        var routine = makeRoutine(id: "poller", name: "Poller", schedule: "*/15 * * * *")
        routine.nextFire = try CronSchedule(routine.schedule).next(after: now, calendar: calendar)
        let interval = ScheduleCalendar.agendaInterval(startingAt: now, days: 2, calendar: calendar)
        let query = ScheduleCalendar.Query(interval: interval, now: now, calendar: calendar)
        let days = ScheduleCalendar.days(query: query, routines: [routine], records: [])

        let todayBurst = try XCTUnwrap(days[0].entries.first)
        XCTAssertEqual(days[0].entries.count, 1)
        XCTAssertTrue(todayBurst.isFrequent)
        XCTAssertEqual(todayBurst.count, 2)
        XCTAssertEqual(todayBurst.start, date("2026-11-16 23:30"))
        XCTAssertEqual(todayBurst.end, date("2026-11-16 23:45"))

        let tomorrowBurst = try XCTUnwrap(days[1].entries.first)
        XCTAssertEqual(days[1].entries.count, 1)
        XCTAssertTrue(tomorrowBurst.isFrequent)
        XCTAssertEqual(tomorrowBurst.count, 96)
        XCTAssertEqual(tomorrowBurst.start, date("2026-11-17 00:00"))
        XCTAssertEqual(tomorrowBurst.end, date("2026-11-17 23:45"))
    }

    func testOneTimeScheduledAtRunLimitAndPriorWindowConsumption() {
        let now = date("2026-11-16 08:00")
        var once = makeRoutine(id: "once", name: "Once", schedule: "0 9 * * *")
        once.repeats = false
        once.scheduledAt = date("2026-11-17 11:30")
        once.nextFire = once.scheduledAt

        var limited = makeRoutine(id: "limited", name: "Limited", schedule: "0 10 * * *")
        limited.runLimit = 4
        limited.scheduledRunCount = 1
        limited.nextFire = date("2026-11-16 10:00")

        var futureStart = makeRoutine(id: "later", name: "Later", schedule: "0 12 * * *")
        futureStart.scheduledAt = date("2026-11-18 12:00")
        futureStart.nextFire = futureStart.scheduledAt

        var completed = makeRoutine(id: "done", name: "Done", schedule: "0 9 * * *", enabled: false)
        completed.runLimit = 2
        completed.scheduledRunCount = 2
        completed.scheduleCompletedAt = date("2026-11-15 09:00")

        // Full 5-day window sees all 3 remaining runs of `limited` (Nov 16, 17, 18).
        let fullWindow = ScheduleCalendar.agendaInterval(startingAt: now, days: 5, calendar: calendar)
        let fullDays = ScheduleCalendar.days(
            query: .init(interval: fullWindow, now: now, includePaused: true, calendar: calendar),
            routines: [once, limited, futureStart, completed], records: []
        )
        let allEntries = fullDays.flatMap(\.entries)
        XCTAssertEqual(allEntries.filter { $0.routineID == "once" }.map(\.start), [date("2026-11-17 11:30")])
        XCTAssertEqual(allEntries.filter { $0.routineID == "limited" }.map(\.start), [
            date("2026-11-16 10:00"), date("2026-11-17 10:00"), date("2026-11-18 10:00")
        ])
        XCTAssertEqual(allEntries.filter { $0.routineID == "later" }.first?.start, date("2026-11-18 12:00"))
        XCTAssertTrue(allEntries.filter { $0.routineID == "done" }.isEmpty)

        // Jumping forward to Nov 18 consumes Nov 16 and Nov 17 first, leaving only 1 slot on Nov 18.
        let laterWindow = ScheduleCalendar.agendaInterval(
            startingAt: date("2026-11-18 00:00"), days: 4, calendar: calendar
        )
        let laterDays = ScheduleCalendar.days(
            query: .init(interval: laterWindow, now: now, calendar: calendar),
            routines: [limited], records: []
        )
        XCTAssertEqual(laterDays.flatMap(\.entries).map(\.start), [date("2026-11-18 10:00")])
    }

    func testOverdueGraceSlotPausedToggleAndRoutineFilter() {
        let now = date("2026-11-16 09:30")
        var overdue = makeRoutine(id: "overdue", name: "Overdue", schedule: "0 9 * * *")
        overdue.nextFire = date("2026-11-16 09:00")
        overdue.runLimit = 2

        let paused = makeRoutine(id: "paused", name: "Paused", schedule: "0 15 * * *", enabled: false)
        let pastRecord = RunRecord(
            routineID: "paused", trigger: .scheduled, harness: .codex,
            startedAt: date("2026-11-16 07:00"), endedAt: date("2026-11-16 07:02"), outcome: .succeeded
        )
        let interval = ScheduleCalendar.agendaInterval(startingAt: now, days: 2, calendar: calendar)

        let activeOnly = ScheduleCalendar.days(
            query: .init(interval: interval, now: now, includePaused: false, calendar: calendar),
            routines: [overdue, paused], records: [pastRecord]
        )
        // Past session of a paused routine stays visible, while its future slot stays hidden.
        XCTAssertEqual(activeOnly[0].entries.map(\.routineID), ["paused", "overdue"])
        XCTAssertNotNil(activeOnly[0].entries[0].record)
        XCTAssertEqual(activeOnly[1].entries.map(\.routineID), ["overdue"])

        let withPaused = ScheduleCalendar.days(
            query: .init(interval: interval, now: now, includePaused: true, calendar: calendar),
            routines: [overdue, paused], records: [pastRecord]
        )
        XCTAssertEqual(withPaused[0].entries.filter(\.isPaused).map(\.routineID), ["paused"])

        let filtered = ScheduleCalendar.days(
            query: .init(interval: interval, now: now, includePaused: true, routineID: "paused", calendar: calendar),
            routines: [overdue, paused], records: [pastRecord]
        )
        XCTAssertTrue(filtered.flatMap(\.entries).allSatisfy { $0.routineID == "paused" })
    }

    func testQuietRecordBurstCollapsesWhileProminentRunsStayIndividual() {
        let now = date("2026-11-16 20:00")
        let routine = makeRoutine(id: "watch", name: "Watch", schedule: "0 23 * * *")
        var records: [RunRecord] = (0..<8).map { index in
            let start = date("2026-11-16 08:00").addingTimeInterval(Double(index * 600))
            return RunRecord(
                routineID: "watch", trigger: .scheduled, harness: .codex,
                startedAt: start, endedAt: start.addingTimeInterval(30), outcome: .succeeded
            )
        }
        var needsReply = RunRecord(
            routineID: "watch", trigger: .scheduled, harness: .codex,
            startedAt: date("2026-11-16 11:00"), endedAt: date("2026-11-16 11:01"), outcome: .succeeded
        )
        needsReply.attention = "Approve staging deploy?"
        let failed = RunRecord(
            routineID: "watch", trigger: .scheduled, harness: .codex,
            startedAt: date("2026-11-16 12:00"), endedAt: date("2026-11-16 12:01"), outcome: .failed(exitCode: 1)
        )
        records.append(contentsOf: [needsReply, failed])

        let interval = ScheduleCalendar.agendaInterval(startingAt: now, days: 1, calendar: calendar)
        let day = ScheduleCalendar.days(
            query: .init(interval: interval, now: now, calendar: calendar),
            routines: [routine], records: records
        )[0]

        let recordEntries = day.entries.filter { $0.record != nil }
        XCTAssertEqual(recordEntries.count, 3)
        XCTAssertEqual(recordEntries.first(where: \.isFrequent)?.count, 8)
        XCTAssertTrue(recordEntries.contains { $0.record?.id == needsReply.id && !$0.isFrequent })
        XCTAssertTrue(recordEntries.contains { $0.record?.id == failed.id && !$0.isFrequent })
    }

    func testSpringForwardSkipsMissingHourAndPreservesCalendarDays() throws {
        let now = date("2027-03-14 00:30")
        var routine = makeRoutine(schedule: "30 2 * * *")
        routine.nextFire = try CronSchedule(routine.schedule).next(after: now, calendar: calendar)
        let interval = ScheduleCalendar.weekInterval(containing: now, calendar: calendar)
        let days = ScheduleCalendar.days(
            query: .init(interval: interval, now: now, calendar: calendar),
            routines: [routine], records: []
        )
        XCTAssertEqual(days.count, 7)
        XCTAssertEqual(days.first { $0.id == "2027-03-14" }?.entries, [])
        XCTAssertEqual(days.first { $0.id == "2027-03-15" }?.entries.map(\.start), [date("2027-03-15 02:30")])
    }
}

@MainActor
final class ControlCalendarTests: XCTestCase {
    private var directory: URL!
    private var scheduler: Scheduler!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let laCalendar = makeLACalendar()
        let fixedNow = localDate("2026-11-16 10:30", calendar: laCalendar)
        scheduler = Scheduler(
            location: StorageLocation(root: directory, logs: directory.appendingPathComponent("logs")),
            launcher: CalendarNoopLauncher()
        )
        scheduler.calendar = laCalendar
        scheduler.now = { fixedNow }
        scheduler.executable = { "/bin/\($0.rawValue)" }
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testDateOnlyAnchorStaysInLocalZoneAcrossHemispheres() {
        for identifier in ["America/Los_Angeles", "Asia/Tokyo", "UTC"] {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: identifier)!
            let parsed = Scheduler.parseCalendarAnchor("2026-11-15", calendar: cal)
            XCTAssertEqual(
                parsed.map { ScheduleCalendar.dayIdentifier(for: $0, calendar: cal) },
                "2026-11-15",
                identifier
            )
        }
        let laCal = makeLACalendar()
        XCTAssertNotNil(Scheduler.parseCalendarAnchor("2026-11-15T18:00:00Z", calendar: laCal))
        XCTAssertNil(Scheduler.parseCalendarAnchor("2026-02-30", calendar: laCal))
        XCTAssertNil(Scheduler.parseCalendarAnchor("2026-11-15T10:00:00", calendar: laCal))
        XCTAssertNil(Scheduler.parseCalendarAnchor("tomorrow", calendar: laCal))
    }

    func testRoutinesCalendarControlProjectsDaysFiltersAndValidates() throws {
        _ = try scheduler.control("routines.create", [
            "id": "digest", "name": "Digest", "workingDirectory": directory.path,
            "schedule": "0 9,18 * * *", "harness": "codex", "prompt": "Summarize."
        ]).get()
        _ = try scheduler.control("routines.create", [
            "id": "nightly", "name": "Nightly", "workingDirectory": directory.path,
            "schedule": "0 22 * * *", "harness": "claude", "prompt": "sync", "enabled": false
        ]).get()

        let response = try XCTUnwrap(
            try scheduler.control("routines.calendar", ["days": 2]).get() as? [String: Any]
        )
        XCTAssertEqual(response["days"] as? Int, 2)
        XCTAssertEqual(response["timeZone"] as? String, "America/Los_Angeles")
        let days = try XCTUnwrap(response["calendar"] as? [[String: Any]])
        XCTAssertEqual(days.map { $0["date"] as? String }, ["2026-11-16", "2026-11-17"])
        let firstEntries = try XCTUnwrap(days[0]["entries"] as? [[String: Any]])
        XCTAssertEqual(firstEntries.map { $0["routine"] as? String }, ["digest"])
        XCTAssertEqual(firstEntries.first?["kind"] as? String, "scheduled")

        let withPaused = try XCTUnwrap(
            try scheduler.control("routines.calendar", ["days": 1, "includePaused": true]).get() as? [String: Any]
        )
        let pausedDays = try XCTUnwrap(withPaused["calendar"] as? [[String: Any]])
        let pausedEntries = try XCTUnwrap(pausedDays[0]["entries"] as? [[String: Any]])
        XCTAssertEqual(pausedEntries.map { $0["routine"] as? String }, ["digest", "nightly"])
        XCTAssertEqual(pausedEntries.last?["paused"] as? Bool, true)

        XCTAssertThrowsError(try scheduler.control("routines.calendar", ["id": "missing"]).get())
        XCTAssertThrowsError(try scheduler.control("routines.calendar", ["days": 0]).get())
        XCTAssertThrowsError(try scheduler.control("routines.calendar", ["days": 367]).get())
        XCTAssertThrowsError(try scheduler.control("routines.calendar", ["from": "bad-date"]).get())
    }

    func testCLICalendarArgumentsAndPresentationStatePersistence() throws {
        let raw = ["calendar", "digest", "--from", "2026-11-16", "--days", "14", "--paused"]
        let (method, params) = try ControlCLI.request("calendar", ControlCLI.Arguments(raw))
        XCTAssertEqual(method, "routines.calendar")
        XCTAssertEqual(params["id"] as? String, "digest")
        XCTAssertEqual(params["from"] as? String, "2026-11-16")
        XCTAssertEqual(params["days"] as? Int, 14)
        XCTAssertEqual(params["includePaused"] as? Bool, true)
        XCTAssertThrowsError(
            try ControlCLI.request("calendar", ControlCLI.Arguments(["calendar", "--days", "nope"]))
        )

        let suiteName = "rota-calendar-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let now = localDate("2026-11-16 10:30", calendar: scheduler.calendar)
        let state = CalendarPresentationState(defaults: defaults, now: now)
        XCTAssertEqual(state.mode, .week)
        XCTAssertFalse(state.showPaused)
        state.mode = .month
        state.showPaused = true
        state.step(1, calendar: scheduler.calendar)

        let reloaded = CalendarPresentationState(defaults: defaults, now: now)
        XCTAssertEqual(reloaded.mode, .month)
        XCTAssertTrue(reloaded.showPaused)
        reloaded.goToToday(now: now, calendar: scheduler.calendar)
        XCTAssertEqual(reloaded.anchor, now)
    }
}

private final class CalendarNoopLauncher: RoutineLaunching {
    func launch(_ spec: LaunchSpec, events: RunEvents) throws -> RunControl {
        CalendarNoopControl()
    }
}

private final class CalendarNoopControl: RunControl {
    func stop() {}
}
