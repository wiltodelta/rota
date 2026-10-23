@testable import Rota
@testable import RotaCore
import XCTest

final class ToolGroupingTests: XCTestCase {
    func testOnlyAdjacentToolsFoldAndEveryOtherKindRemainsVisible() {
        let kinds: [TranscriptItem.Kind] = [.user, .tool, .tool, .agent, .tool, .error, .tool,
                                           .status, .tool, .plan, .tool, .output, .tool]
        let items = kinds.enumerated().map { TranscriptItem(id: $0.offset, kind: $0.element, text: "same") }
        let rows = WorkRow.group(items)
        XCTAssertEqual(rows.flatMap(\.items), items, "Grouping must preserve order, IDs, and repeated calls")
        XCTAssertEqual(rows.map(\.id), [0, 1, 3, 4, 5, 6, 7, 8, 9, 10])
        XCTAssertEqual(rows.filter { if case .tools = $0 { true } else { false } }.count, 5)
        for row in rows {
            if case .note(let item) = row { XCTAssertNotEqual(item.kind, .tool) }
        }
    }

    func testLiveAppendAndEarlierPageKeepTheExistingGroupReachable() {
        let calls = (10...20).map { TranscriptItem(id: $0, kind: .tool, text: "js") }
        let initial = WorkRow.group(Array(calls[3...5]))
        let appended = WorkRow.group(Array(calls[3...]))
        XCTAssertEqual(initial.first?.id, appended.first?.id)
        let prepended = WorkRow.group(calls)
        XCTAssertEqual(WorkRow.visibleID(for: 13, in: prepended), 10)
        XCTAssertTrue(prepended[0].items.contains { $0.id == 13 },
                      "An expanded group still owns its expansion key")
        XCTAssertEqual(WorkRow.visibleID(for: 99, in: prepended), 99)
    }

    func testPagingNeverReparentsVisibleOutputIntoAToolGroup() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = folder.appendingPathComponent("session.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let journal = RunJournal(output: try FileHandle(forWritingTo: log),
                                 events: RunEvents(session: { _ in }, finished: { _ in }),
                                 transcript: try TranscriptJournal(log: log, resuming: false, logSize: 0))
        for index in 0..<60 { journal.record(.agent, "Earlier message \(index)") }
        journal.record(.tool, "Read synthetic file")
        journal.record(.output, "First tool output")
        journal.record(.tool, "Inspect synthetic output")
        journal.record(.output, "Second tool output")
        for index in 0..<48 { journal.record(.agent, "Later message \(index)") }
        journal.finish(.succeeded)
        var reader = TranscriptReader(pageSize: 50)
        let initial = reader.read(log: log, finished: true)
        XCTAssertTrue(initial.structured)
        XCTAssertNil(initial.problem)
        XCTAssertTrue(initial.hasEarlier)
        let rows = WorkRow.group(initial.items)
        let group = try XCTUnwrap(rows.first { if case .tools = $0 { true } else { false } })
        XCTAssertEqual(group.items.map(\.id), [60, 61, 62, 63], "The initial page must contain the whole group")
        XCTAssertFalse(rows.contains { row in
            if case .note(let item) = row { return item.kind == .output }
            return false
        }, "Paging must not detach output from its tool call")
        let earlier = reader.readEarlier(log: log, finished: true)
        XCTAssertTrue(earlier.structured)
        XCTAssertNil(earlier.problem)
        let loadedRows = WorkRow.group(earlier.items)
        for row in rows {
            XCTAssertEqual(WorkRow.visibleID(for: row.id, in: loadedRows), row.id)
            XCTAssertEqual(loadedRows.first { $0.id == row.id }?.items, row.items,
                           "Prepending a page must not regroup already visible content")
        }
        if let destination = ProcessInfo.processInfo.environment["ROTA_PAGING_GROUP_FIXTURE_DIR"] {
            try TranscriptJournalTests.exportFixture(log: log, to: URL(fileURLWithPath: destination))
        }
    }

    func testProducerGeneratedToolHistory() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = folder.appendingPathComponent("session.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let output = try FileHandle(forWritingTo: log)
        let transcript = try TranscriptJournal(log: log, resuming: false, logSize: 0)
        let journal = RunJournal(output: output,
                                 events: RunEvents(session: { _ in }, finished: { _ in }), transcript: transcript)
        journal.record(.user, "Inspect the synthetic example")
        journal.record(.agent, "I will inspect the example and summarize what changed.")
        for index in 1...14 {
            journal.record(.tool, index == 9
                ? "$ inspect --input example --explain \"A long command remains fully readable when expanded\""
                : "js synthetic check \(index)")
        }
        journal.record(.agent, "The checks are complete. All calls remain available in the collapsed group above.")
        journal.record(.error, "Synthetic warning, this stays visible outside tool groups.")
        journal.record(.tool, "js final check")
        journal.finish(.succeeded)
        var reader = TranscriptReader()
        let snapshot = reader.read(log: log, finished: true)
        XCTAssertTrue(snapshot.structured)
        XCTAssertNil(snapshot.problem)
        let rows = WorkRow.group(snapshot.items)
        XCTAssertEqual(rows.count, 7)
        XCTAssertEqual(rows[2].items.count, 14)
        XCTAssertEqual(rows[4].items.first?.kind, .error)
        if let destination = ProcessInfo.processInfo.environment["ROTA_TOOL_FIXTURE_DIR"] {
            try TranscriptJournalTests.exportFixture(log: log, to: URL(fileURLWithPath: destination))
        }
    }
}
