@testable import RotaCore
import XCTest

final class CronScheduleTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return calendar
    }()

    private func date(_ text: String) -> Date {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: text)!
    }

    private func next(_ expression: String, after text: String) throws -> Date? {
        try CronSchedule(expression).next(after: date(text), calendar: calendar)
    }

    func testDailyTimeLaterTodayAndTomorrow() throws {
        XCTAssertEqual(try next("0 10 * * *", after: "2026-10-09 09:59"), date("2026-10-09 10:00"))
        XCTAssertEqual(try next("0 10 * * *", after: "2026-10-09 10:00"), date("2026-10-10 10:00"))
    }

    func testSecondsWithinTheMinuteDoNotRefireIt() throws {
        let schedule = try CronSchedule("0 10 * * *")
        let midMinute = date("2026-10-09 10:00").addingTimeInterval(30)
        XCTAssertEqual(schedule.next(after: midMinute, calendar: calendar), date("2026-10-10 10:00"))
    }

    func testListsOfHours() throws {
        XCTAssertEqual(try next("37 10,14,17,20 * * *", after: "2026-10-09 10:37"), date("2026-10-09 14:37"))
        XCTAssertEqual(try next("37 10,14,17,20 * * *", after: "2026-10-09 20:40"), date("2026-10-10 10:37"))
    }

    func testWeekdayRangeSkipsWeekend() throws {
        // 2026-10-09 is a Friday.
        XCTAssertEqual(try next("0 10 * * 1-5", after: "2026-10-09 11:00"), date("2026-10-12 10:00"))
    }

    func testSundayIsZeroAndSeven() throws {
        XCTAssertEqual(try next("0 9 * * 0", after: "2026-10-09 11:00"), date("2026-10-11 09:00"))
        XCTAssertEqual(try next("0 9 * * 7", after: "2026-10-09 11:00"), date("2026-10-11 09:00"))
    }

    func testStepsAndRangeSteps() throws {
        XCTAssertEqual(try CronSchedule("*/15 * * * *").minutes, [0, 15, 30, 45])
        XCTAssertEqual(try CronSchedule("10-40/10 * * * *").minutes, [10, 20, 30, 40])
        XCTAssertEqual(try CronSchedule("5/20 * * * *").minutes, [5, 25, 45])
    }

    func testDayOfMonthAndWeekdayBothRestrictedMatchEither() throws {
        // The 15th (a Thursday) or any Monday, whichever comes first.
        XCTAssertEqual(try next("0 9 15 * 1", after: "2026-10-09 11:00"), date("2026-10-12 09:00"))
        XCTAssertEqual(try next("0 9 15 * 1", after: "2026-10-13 11:00"), date("2026-10-15 09:00"))
    }

    func testMonthlyAndSpecificMonth() throws {
        XCTAssertEqual(try next("45 13 2 * *", after: "2026-10-09 11:00"), date("2026-11-02 13:45"))
        XCTAssertEqual(try next("15 12 2-3 10 *", after: "2026-10-09 11:00"), date("2027-10-02 12:15"))
    }

    func testTimeSkippedBySpringForwardIsNotReported() throws {
        // 2027-03-14 02:30 does not exist in Los Angeles.
        XCTAssertEqual(try next("30 2 * * *", after: "2027-03-13 03:00"), date("2027-03-15 02:30"))
    }

    func testImpossibleDateNeverFires() throws {
        XCTAssertNil(try next("0 0 30 2 *", after: "2026-10-09 11:00"))
    }

    func testRejectsMalformedExpressions() {
        XCTAssertThrowsError(try CronSchedule("0 10 * *")) { error in
            XCTAssertEqual(error as? CronError, .fieldCount(4))
        }
        for bad in ["60 * * * *", "* 24 * * *", "* * 0 * *", "* * * 13 *", "* * * * 8",
                    "5-1 * * * *", "*/0 * * * *", "a * * * *", "1,,2 * * * *", "MON * * * *"] {
            XCTAssertThrowsError(try CronSchedule(bad), bad)
        }
    }

    func testUpcomingReturnsConsecutiveTimes() throws {
        let times = try CronSchedule("0 10 * * *").upcoming(after: date("2026-10-09 11:00"), count: 3,
                                                           calendar: calendar)
        XCTAssertEqual(times, [date("2026-10-10 10:00"), date("2026-10-11 10:00"), date("2026-10-12 10:00")])
    }
}
