@testable import RotaCore
import XCTest

final class SessionConfigurationTests: XCTestCase {
    func testUnknownDefaultsStayUnknownAndReadableHeadersUseTheNewestValue() throws {
        XCTAssertNil(SessionConfiguration(model: "unknown model", effort: "  ").model)
        XCTAssertNil(SessionConfiguration(effort: "  ").effort)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: file) }
        let headers = "[session started, old-model]\n[you] [session started, user-text]\n"
            + "[codex thread fixture, latest-model]\n"
        try Data(headers.utf8).write(to: file)
        XCTAssertEqual(SessionConfiguration.recordedModel(log: file), "latest-model")
        try Data(("[session started, old-model]\n" + String(repeating: "x", count: 300_000)).utf8).write(to: file)
        XCTAssertNil(SessionConfiguration.recordedModel(log: file),
                     "Do not invent a current value from an older header")
    }

    func testJournalReportsChangedConfigurationOnlyAndIgnoresEventsAfterFinish() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        FileManager.default.createFile(atPath: file.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: file) }
        let finished = expectation(description: "finished")
        nonisolated(unsafe) var values: [SessionConfiguration] = []
        let events = RunEvents(session: { _ in }, finished: { _ in finished.fulfill() },
                               configuration: { values.append($0) })
        let journal = RunJournal(output: try FileHandle(forWritingTo: file), events: events)
        journal.configure(SessionConfiguration())
        journal.configure(SessionConfiguration(model: "fixture", effort: "high"))
        journal.configure(SessionConfiguration(model: "fixture"))
        journal.configure(SessionConfiguration(model: "next"))
        journal.finish(.succeeded)
        journal.configure(SessionConfiguration(model: "too late"))
        wait(for: [finished], timeout: 2)
        XCTAssertEqual(values, [SessionConfiguration(model: "fixture", effort: "high"),
                                SessionConfiguration(model: "next", effort: "high")])
    }
}
