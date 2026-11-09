@testable import Rota
@testable import RotaCore
import XCTest

final class SessionFilterTests: XCTestCase {
    func testFiltersUseTheSameStatesAcrossHarnessesAndClaudeModes() {
        for harness in Harness.allCases {
            let modes: [LaunchMode] = harness == .claude ? [.claudeStream, .claudeInteractive] : [harness.launchMode]
            for mode in modes {
                var records = [
                    record("completed", .succeeded, harness), record("unread", .succeeded, harness),
                    record("working", .running, harness), record("question", .succeeded, harness),
                    record("attention", .succeeded, harness), record("terminal", .running, harness),
                    record("failed", .failed(exitCode: 1), harness), record("timeout", .timedOut, harness),
                    record("interrupted", .interrupted, harness),
                    record("launch", .launchFailed("Unavailable"), harness),
                    record("stopped", .cancelled, harness), record("skip", .skipped("No run"), harness)
                ]
                records[1].readAt = nil
                records[3].questions = [.init(title: "Synthetic question")]
                records[4].attention = "Synthetic attention request"
                records[5].terminalState = .waiting
                for index in records.indices { records[index].launchMode = mode }
                let expected: [SessionFilter: Set<String>] = [
                    .all: Set(records.filter { !$0.isSkip }.map(\.routineID)),
                    .running: ["working", "terminal"], .needsAttention: ["question", "attention", "terminal"],
                    .unread: ["unread"], .failed: ["failed", "timeout", "interrupted", "launch"],
                    .completed: ["completed", "unread"]
                ]
                for filter in SessionFilter.allCases {
                    XCTAssertEqual(Set(records.filter { filter.includes($0) }.map(\.routineID)), expected[filter],
                                   "\(harness) / \(mode) / \(filter)")
                }
            }
        }
    }

    func testReadingAnUnreadSessionKeepsOnlyThatSelectionVisible() {
        var selected = record("selected", .succeeded)
        let alreadyRead = record("read", .succeeded)
        var unread = record("unread", .succeeded)
        unread.readAt = nil
        let selection = SidebarItem.session(selected.id)
        selected.readAt = selected.endedAt
        let records = [selected, alreadyRead, unread]
        XCTAssertEqual(SessionFilters(.unread).visibleRecords(records, selection: selection).map(\.id),
                       [selected.id, unread.id])
        XCTAssertEqual(SessionFilters(.unread).destination(from: selection, records: records), .session(unread.id))
        XCTAssertNil(unread.readAt, "Reading one session must not drain other unread sessions")
    }

    func testExplicitFilterChangesKeepMatchingSessionsAndClearEmptyResults() {
        let completed = record("completed", .succeeded)
        let failed = record("failed", .failed(exitCode: 2))
        let records = [completed, failed]
        XCTAssertEqual(SessionFilters(.failed).destination(from: .session(completed.id), records: records),
                       .session(failed.id))
        XCTAssertEqual(SessionFilters(.all).destination(from: .session(failed.id), records: records),
                       .session(failed.id))
        XCTAssertNil(SessionFilters(.running).destination(from: .session(completed.id), records: records))
        XCTAssertEqual(SessionFilters(.completed).destination(from: .routine("example"), records: records),
                       .session(completed.id))
    }

    func testArrowNavigationTraversesFiltersWithoutWrappingAtTheEnds() {
        let filters = SessionFilter.allCases
        for (index, filter) in filters.enumerated() {
            XCTAssertEqual(filter.moved(by: -1), filters[max(0, index - 1)])
            XCTAssertEqual(filter.moved(by: 1), filters[min(filters.count - 1, index + 1)])
        }
    }

    func testMultipleCategoriesIncludeEitherMatchOnceAcrossHarnesses() {
        for harness in Harness.allCases {
            let modes: [LaunchMode] = harness == .claude ? [.claudeStream, .claudeInteractive] : [harness.launchMode]
            for mode in modes {
                var attention = record("attention", .succeeded, harness)
                attention.attention = "Synthetic request"
                var failed = record("failed", .failed(exitCode: 1), harness)
                failed.attention = "Synthetic overlapping request"
                var records = [record("running", .running, harness), attention, failed,
                               record("completed", .succeeded, harness), record("skip", .skipped("No run"), harness)]
                for index in records.indices { records[index].launchMode = mode }
                let filters = SessionFilters(.running).toggling(.needsAttention).toggling(.failed)
                XCTAssertEqual(filters.selected, [.running, .needsAttention, .failed])
                XCTAssertEqual(filters.title, "Running, Needs Attention, Failed")
                XCTAssertEqual(filters.visibleRecords(records, selection: nil).map(\.routineID),
                               ["running", "attention", "failed"], "\(harness) / \(mode)")
                XCTAssertEqual(filters.destination(from: .session(failed.id), records: records), .session(failed.id))
                XCTAssertEqual(filters.destination(from: .session(records[3].id), records: records),
                               .session(records[0].id))
            }
        }
    }

    func testRemovingCategoriesAndAllSessionsResetTheSelection() {
        let filters = SessionFilters(.running).toggling(.failed)
        XCTAssertFalse(filters.contains(.all))
        XCTAssertEqual(filters.toggling(.running).selected, [.failed])
        XCTAssertEqual(filters.toggling(.failed).selected, [.running])
        XCTAssertEqual(filters.toggling(.running).toggling(.failed), .all)
        XCTAssertEqual(filters.toggling(.all), .all)
        XCTAssertTrue(SessionFilters.all.contains(.all))
        XCTAssertEqual(filters.moved(by: -1), .unread)
        XCTAssertEqual(SessionFilters.all.moved(by: 1), .running)
    }

    private func record(_ name: String, _ outcome: RunOutcome, _ harness: Harness = .codex) -> RunRecord {
        var record = RunRecord(routineID: name, trigger: .manual, harness: harness,
                               startedAt: Date(timeIntervalSince1970: 100),
                               endedAt: outcome == .running ? nil : Date(timeIntervalSince1970: 200), outcome: outcome)
        record.readAt = Date(timeIntervalSince1970: 300)
        return record
    }
}
