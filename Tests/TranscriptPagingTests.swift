@testable import RotaCore
import XCTest

final class TranscriptPagingTests: XCTestCase {
    private var folder: URL!
    private var log: URL!
    private var journal: RunJournal!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        log = folder.appendingPathComponent("session.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let output = try FileHandle(forWritingTo: log)
        journal = RunJournal(output: output, events: RunEvents(session: { _ in }, finished: { _ in }),
                             transcript: try TranscriptJournal(log: log, resuming: false, logSize: 0))
    }

    override func tearDownWithError() throws {
        journal = nil
        try FileManager.default.removeItem(at: folder)
    }

    func testTailReadsBoundedBytesAndPagesReconstructProducerHistory() throws {
        for index in 0..<300 {
            journal.record(index.isMultiple(of: 2) ? .user : .agent,
                           "Message \(index): " + String(repeating: "long content ", count: index < 250 ? 500 : 3))
        }
        journal.finish(.succeeded)
        var reader = TranscriptReader(pageSize: 17)
        var snapshot = reader.read(log: log, finished: true)
        XCTAssertTrue(snapshot.structured)
        XCTAssertTrue(snapshot.hasEarlier)
        XCTAssertEqual(snapshot.items.count, 17)
        let size = try FileManager.default.attributesOfItem(atPath: TranscriptReader.journalURL(for: log).path)[.size]
        XCTAssertLessThan(reader.bytesRead, try XCTUnwrap(size as? Int) / 4,
                          "A limited projection must also avoid reading the entire file")
        let tail = snapshot.items
        var requests = 0
        while snapshot.hasEarlier, requests < 25 {
            snapshot = reader.readEarlier(log: log, finished: true)
            XCTAssertTrue(snapshot.structured)
            XCTAssertNil(snapshot.problem)
            requests += 1
        }
        XCTAssertFalse(snapshot.hasEarlier)
        var full = TranscriptReader()
        XCTAssertEqual(snapshot.items, full.read(log: log, finished: true).items)
        XCTAssertEqual(Array(snapshot.items.suffix(17)), tail)
        let bytes = reader.bytesRead
        XCTAssertEqual(reader.read(log: log, finished: true), snapshot)
        XCTAssertEqual(reader.bytesRead, bytes, "An unchanged poll should fetch no journal bytes")
        if let destination = ProcessInfo.processInfo.environment["ROTA_PAGED_FIXTURE_DIR"] {
            try TranscriptJournalTests.exportFixture(log: log, to: URL(fileURLWithPath: destination))
        }
    }

    func testPagingPreservesLiveUnicodeAppendsAndCompletion() throws {
        for index in 0..<9 { journal.record(.user, "Question \(index)") }
        journal.text("Привет")
        journal.text(" 世界")
        var reader = TranscriptReader(pageSize: 3)
        let first = reader.read(log: log)
        XCTAssertTrue(first.structured)
        XCTAssertEqual(first.items.last?.text, "Привет 世界")
        XCTAssertFalse(try XCTUnwrap(first.items.last).isComplete)
        journal.text("\n\n## Growing\nMore text")
        let earlier = reader.readEarlier(log: log)
        XCTAssertTrue(earlier.structured)
        XCTAssertEqual(earlier.items.count, 6)
        XCTAssertEqual(earlier.items.last?.id, first.items.last?.id)
        XCTAssertEqual(earlier.items.last?.text, "Привет 世界\n\n## Growing\nMore text")
        journal.finish(.succeeded)
        let finished = reader.read(log: log, finished: true)
        XCTAssertTrue(finished.structured)
        XCTAssertEqual(finished.items.count, 7)
        XCTAssertTrue(try XCTUnwrap(finished.items.dropLast().last).isComplete)
        XCTAssertEqual(finished.items.first?.id, earlier.items.first?.id)
    }

    func testOneInconsistentPollKeepsChatButRepeatedOrFinishedMismatchWarns() throws {
        journal.record(.agent, "saved")
        var reader = TranscriptReader(pageSize: 3, settleWrites: true)
        let good = reader.read(log: log)
        let output = try FileHandle(forWritingTo: log)
        defer { try? output.close() }
        try output.seekToEnd()
        try output.write(contentsOf: Data("[error] lost journal write\n".utf8))
        XCTAssertEqual(reader.read(log: log), good)
        let failed = reader.read(log: log)
        XCTAssertFalse(failed.structured)
        XCTAssertNotNil(failed.problem)
        XCTAssertTrue(failed.items.contains { $0.text == "lost journal write" })
        var finished = TranscriptReader(pageSize: 3, settleWrites: true)
        XCTAssertNotNil(finished.read(log: log, finished: true).problem)
    }

    func testInterleavedWritesRecoverWithoutFallbackAndStrictWriterStillRejectsMismatch() throws {
        journal.record(.agent, "saved")
        var reader = TranscriptReader(pageSize: 2, settleWrites: true)
        let good = reader.read(log: log)
        let url = TranscriptReader.journalURL(for: log)
        let old = try Data(contentsOf: url)
        journal.record(.agent, "next")
        let complete = try Data(contentsOf: url)
        try old.write(to: url)
        XCTAssertEqual(reader.read(log: log), good)
        XCTAssertThrowsError(try TranscriptJournal(log: log, resuming: true, logSize: 0))
        try complete.write(to: url)
        let recovered = reader.read(log: log)
        XCTAssertTrue(recovered.structured)
        XCTAssertNil(recovered.problem)
        XCTAssertEqual(recovered.items.map(\.text), ["saved", "next"])
        // The grace period resets after a coherent read.
        journal.record(.agent, "third")
        let third = try Data(contentsOf: url)
        try complete.write(to: url)
        XCTAssertEqual(reader.read(log: log), recovered)
        try third.write(to: url)
        XCTAssertTrue(reader.read(log: log).structured)
    }

    func testPartialHeaderAtOpenWaitsOnePollAndThenRecovers() throws {
        let url = TranscriptReader.journalURL(for: log)
        let full = try Data(contentsOf: url)
        try full.prefix(8).write(to: url)
        var reader = TranscriptReader(pageSize: 2, settleWrites: true)
        let waiting = reader.read(log: log)
        XCTAssertTrue(waiting.structured)
        XCTAssertNil(waiting.problem)
        XCTAssertTrue(waiting.items.isEmpty)
        try full.write(to: url)
        XCTAssertTrue(reader.read(log: log).structured)
        XCTAssertNil(reader.read(log: log).problem)
    }

    func testPartialTailAtOpenCompletesAndInvalidOlderPageWarnsOnDemand() throws {
        for index in 0..<8 { journal.record(.agent, "Message \(index)") }
        let url = TranscriptReader.journalURL(for: log)
        let full = try Data(contentsOf: url)
        let lastNewline = try XCTUnwrap(full.dropLast().lastIndex(of: 10))
        let cut = full.count - 4
        try full.prefix(cut).write(to: url)
        var reader = TranscriptReader(pageSize: 2, settleWrites: true)
        let first = reader.read(log: log)
        XCTAssertTrue(first.structured)
        XCTAssertEqual(first.items.map(\.text), ["Message 5", "Message 6"])
        let handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        try handle.write(contentsOf: full.suffix(from: cut))
        try handle.close()
        XCTAssertEqual(reader.read(log: log).items.last?.text, "Message 7")
        XCTAssertGreaterThan(cut, lastNewline)
        // Reopen a journal with an unsupported older record outside the initial page.
        var lines = full.split(separator: 10).map(Data.init)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: lines[1]) as? [String: Any])
        object["version"] = 2
        lines[1] = try JSONSerialization.data(withJSONObject: object)
        try (lines.reduce(Data()) { $0 + $1 + Data([10]) }).write(to: url)
        var older = TranscriptReader(pageSize: 2)
        var snapshot = older.read(log: log)
        XCTAssertTrue(snapshot.structured)
        var requests = 0
        while snapshot.hasEarlier && snapshot.problem == nil && requests < 8 {
            snapshot = older.readEarlier(log: log)
            requests += 1
        }
        XCTAssertNotNil(snapshot.problem)
        XCTAssertFalse(snapshot.structured)
    }
}
