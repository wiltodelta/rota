@testable import Rota
@testable import RotaCore
import XCTest

final class SessionFilterPersistenceTests: XCTestCase {
    func testRestoresMultipleCategoriesAndPersistsAllSessionsReset() throws {
        let suite = "SessionFilterPersistenceTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(SessionFilters(defaults: defaults), .all)
        let filters = SessionFilters(.running).toggling(.unread).toggling(.failed)
        filters.persist(to: defaults)
        XCTAssertEqual(SessionFilters(defaults: defaults), filters)
        SessionFilters.all.persist(to: defaults)
        XCTAssertEqual(SessionFilters(defaults: defaults), .all)
    }

    func testUnknownAndDuplicateValuesDoNotLoseValidCategories() throws {
        let suite = "SessionFilterPersistenceTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["failed", "future-category", "failed", "all"], forKey: SessionFilters.defaultsKey)
        let restored = SessionFilters(defaults: defaults)
        XCTAssertEqual(restored, SessionFilters(.failed))
        let latest = RunRecord(routineID: "fixture", trigger: .manual, harness: .shell,
                               startedAt: .now, outcome: .succeeded)
        let failed = RunRecord(routineID: "fixture", trigger: .manual, harness: .shell,
                              startedAt: .now.addingTimeInterval(-60), outcome: .failed(exitCode: 1))
        XCTAssertEqual(restored.destination(from: nil, records: [latest, failed]), .session(failed.id))
        defaults.set("wrong-type", forKey: SessionFilters.defaultsKey)
        XCTAssertEqual(SessionFilters(defaults: defaults), .all)
    }
}
