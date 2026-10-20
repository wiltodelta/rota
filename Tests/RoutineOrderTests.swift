@testable import Rota
import RotaCore
import XCTest

final class RoutineOrderTests: XCTestCase {
    func testNextRunsComeFirstAndUnscheduledRoutinesKeepTheirOrder() {
        let routines = [
            routine("late", next: 300),
            routine("paused", next: 10, enabled: false),
            routine("soon", next: 100),
            routine("no-date", next: nil),
            routine("same-time", next: 100),
            routine("overdue", next: -100)
        ]
        XCTAssertEqual(RoutineOrder.byNextRun(routines).map(\.id),
                       ["overdue", "soon", "same-time", "late", "paused", "no-date"])
        XCTAssertEqual(routines.first?.id, "late", "Display sorting must not reorder the stored collection")
    }

    func testChangingNextRunOrDisablingMovesTheRoutine() {
        var routines = [routine("first", next: 100), routine("second", next: 200)]
        XCTAssertEqual(RoutineOrder.byNextRun(routines).map(\.id), ["first", "second"])
        routines[0].nextFire = Date(timeIntervalSince1970: 300)
        XCTAssertEqual(RoutineOrder.byNextRun(routines).map(\.id), ["second", "first"])
        routines[1].enabled = false
        XCTAssertEqual(RoutineOrder.byNextRun(routines).map(\.id), ["first", "second"])
        XCTAssertTrue(RoutineOrder.byNextRun([]).isEmpty)
    }

    private func routine(_ id: String, next: TimeInterval?, enabled: Bool = true) -> Routine {
        Routine(id: id, name: id, workingDirectory: "/tmp", schedule: "0 9 * * *", enabled: enabled,
                prompt: "Synthetic fixture", nextFire: next.map { Date(timeIntervalSince1970: $0) })
    }
}
