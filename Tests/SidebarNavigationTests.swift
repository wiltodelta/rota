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
}
