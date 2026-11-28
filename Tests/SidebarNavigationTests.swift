@testable import Rota
@testable import RotaCore
import XCTest

final class SidebarNavigationTests: XCTestCase {
    func testSkippedSlotsNeverBecomeSessionDestinations() {
        let id = "example"
        let session = RunRecord(routineID: id, trigger: .manual, harness: .codex,
                                startedAt: Date(timeIntervalSince1970: 100), outcome: .succeeded)
        let skip = RunRecord(routineID: id, trigger: .scheduled, harness: .codex,
                             startedAt: Date(timeIntervalSince1970: 200), outcome: .skipped("Still running"))
        XCTAssertEqual(SidebarItem.latest(routineID: id, records: [skip, session]), .session(session.id))
        XCTAssertEqual(SidebarItem.latest(routineID: id, records: [session, skip]), .session(session.id))
        XCTAssertEqual(SidebarItem.latest(routineID: id, records: [skip]), .routine(id))
        XCTAssertEqual(SidebarItem.latest(routineID: id, records: []), .routine(id))
    }
    func testContinuedSessionUsesActivityForDestinationAndDayGroup() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var older = RunRecord(routineID: "example", trigger: .manual, harness: .codex,
                              startedAt: now.addingTimeInterval(-172_800), outcome: .running)
        let newer = RunRecord(routineID: "example", trigger: .manual, harness: .shell,
                              startedAt: now.addingTimeInterval(-86_400), outcome: .running)
        older.updatedAt = now
        XCTAssertEqual(SidebarItem.latest(routineID: "example", records: [newer, older]), .session(older.id))
        let groups = DayGroup.group([older, newer], now: now)
        XCTAssertEqual(groups.map(\.title), ["Today", "Yesterday"])
        XCTAssertEqual(groups.first?.records.map(\.id), [older.id])
        older.updatedAt = nil
        older.endedAt = now
        XCTAssertEqual(older.lastActivityAt, now, "Legacy sessions fall back to their latest completion")
        older.endedAt = nil
        XCTAssertEqual(older.lastActivityAt, older.startedAt)
    }

}
