@testable import RotaCore
import XCTest

final class TranscriptJournalTests: XCTestCase {
    private var folder: URL!
    private var log: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        log = folder.appendingPathComponent("session.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: folder)
    }

    private func journal(resuming: Bool = false) throws -> RunJournal {
        let output = try FileHandle(forWritingTo: log)
        try output.seekToEnd()
        let transcript = try TranscriptJournal(log: log, resuming: resuming, logSize: output.offsetInFile)
        return RunJournal(output: output, events: RunEvents(session: { _ in }, finished: { _ in }),
                          transcript: transcript)
    }

    func testTypedContentCannotBecomeControlLines() throws {
        let journal = try journal()
        let text = "[you] not a user\n[error] not an error\n-> not a tool\n```\n\ncode\n```"
        journal.record(.user, "go")
        journal.record(.agent, text)
        journal.record(.tool, "an unfamiliar tool")
        journal.record(.agent, "after the tool")
        journal.finish(.succeeded)
        var reader = TranscriptReader()
        let snapshot = reader.read(log: log)
        XCTAssertTrue(snapshot.structured)
        XCTAssertNil(snapshot.problem)
        XCTAssertEqual(snapshot.items.map(\.kind), [.user, .agent, .tool, .agent, .status])
        XCTAssertEqual(snapshot.items[1].text, text)
        XCTAssertEqual(snapshot.items[3].text, "after the tool")
    }

    func testImageCopyFailureKeepsCompletedMessagesPageable() throws {
        let source = folder.appendingPathComponent("proof.png")
        try Data("synthetic image bytes".utf8).write(to: source)
        let outside = folder.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let attachments = ChatAttachmentStore.folder(for: log)
        try FileManager.default.createSymbolicLink(at: attachments, withDestinationURL: outside)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: attachments.path), outside.path)
        let writer = RunJournal(output: try FileHandle(forWritingTo: log),
            events: RunEvents(session: { _ in }, finished: { _ in }),
            transcript: try TranscriptJournal(log: log, resuming: false, logSize: 0),
            images: SessionImageStore(log: log, workingDirectory: folder))
        writer.text("![Proof](proof.png)")
        writer.endText()
        writer.finish(.succeeded)
        var reader = TranscriptReader()
        let full = reader.read(log: log, finished: true)
        XCTAssertTrue(full.items.contains { $0.kind == .status && $0.text.hasPrefix("Couldn't preserve an image") })
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        var paged = TranscriptReader(pageSize: 1)
        var page = paged.read(log: log, finished: true)
        while page.hasEarlier { page = paged.readEarlier(log: log, finished: true) }
        XCTAssertTrue(page.structured)
        XCTAssertNil(page.problem)
        XCTAssertEqual(page.items, full.items)
    }

    func testContinuationKeepsIDsAndIdenticalMessagesDistinct() throws {
        let first = try journal()
        first.record(.user, "same")
        first.record(.agent, "first")
        first.finish(.succeeded)
        var reader = TranscriptReader()
        let before = reader.read(log: log)
        XCTAssertTrue(before.structured)
        let second = try journal(resuming: true)
        second.record(.user, "same")
        second.record(.agent, "second")
        second.finish(.failed(exitCode: 7))
        let after = reader.read(log: log)
        XCTAssertTrue(after.structured, "Legacy fallback must not hide a broken normalized continuation")
        XCTAssertNil(after.problem)
        XCTAssertEqual(Array(after.items.prefix(before.items.count)), before.items)
        XCTAssertEqual(Set(after.items.map(\.id)).count, after.items.count)
        XCTAssertEqual(after.items.filter { $0.kind == .user }.map(\.text), ["same", "same"])
        XCTAssertTrue(after.items.last?.text.contains("7") == true)
        var reopened = TranscriptReader()
        XCTAssertEqual(reopened.read(log: log), after)
    }

    func testPartialTextUpdatesOneStableItemAndCompletesOnce() throws {
        let journal = try journal()
        journal.record(.user, "go")
        journal.text("Привет")
        var reader = TranscriptReader()
        let first = reader.read(log: log)
        XCTAssertTrue(first.structured)
        XCTAssertFalse(try XCTUnwrap(first.items.last).isComplete)
        journal.text(" 世界\n[error] plain text")
        let growing = reader.read(log: log)
        XCTAssertEqual(growing.items.last?.id, first.items.last?.id)
        XCTAssertEqual(growing.items.last?.text, "Привет 世界\n[error] plain text")
        journal.endText()
        journal.endText()
        let complete = reader.read(log: log)
        XCTAssertTrue(try XCTUnwrap(complete.items.last).isComplete)
        XCTAssertEqual(complete.items.count, 2)
        XCTAssertEqual(complete.items.last?.id, first.items.last?.id)
        journal.finish(.interrupted)
        journal.record(.agent, "must not appear")
        XCTAssertFalse(reader.read(log: log).items.contains { $0.text == "must not appear" })
    }

    func testClaudeUnknownNeighborsDoNotHideKnownText() throws {
        let data = try JSONSerialization.data(withJSONObject: ["type": "assistant", "newField": true,
            "message": ["content": [["type": "future_block", "secret": "must not be displayed"],
                                     ["type": "text", "text": "[error] ordinary prose"],
                                     ["type": "tool_use", "name": "FutureTool", "input": ["newArgument": 42]]]]])
        let journal = try journal()
        for item in StreamJSONFormatter.items(data) { journal.record(item.kind, item.text) }
        journal.finish(.succeeded)
        var reader = TranscriptReader()
        let snapshot = reader.read(log: log)
        XCTAssertEqual(snapshot.items.map(\.kind), [.agent, .tool, .status])
        XCTAssertEqual(snapshot.items.first?.text, "[error] ordinary prose")
        XCTAssertEqual(snapshot.items[1].text, "FutureTool")
        XCTAssertFalse(snapshot.items.contains { $0.text.contains("must not be displayed") })
    }

    func testOptionalRecordsAndUnknownPresentationKeepSupportedText() throws {
        let journal = try journal()
        journal.record(.agent, "known")
        journal.finish(.succeeded)
        try append(["version": 1, "type": "future_auxiliary", "required": false, "logSize": logSize()])
        try append(["version": 1, "type": "item", "id": 50, "kind": "future_card",
                    "text": "fallback display text", "newField": true, "logSize": logSize()])
        var reader = TranscriptReader()
        let snapshot = reader.read(log: log)
        XCTAssertTrue(snapshot.structured)
        XCTAssertNil(snapshot.problem)
        XCTAssertEqual(snapshot.items.first?.text, "known")
        XCTAssertEqual(snapshot.items.last?.kind, .status)
        XCTAssertEqual(snapshot.items.last?.text, "fallback display text")
    }

    func testUnsupportedRequiredRecordAndVersionReportFallback() throws {
        let journal = try journal()
        journal.record(.agent, "readable answer")
        journal.finish(.succeeded)
        let url = TranscriptReader.journalURL(for: log)
        let original = try Data(contentsOf: url)
        for change in [["version": 1, "type": "future_required", "logSize": logSize()],
                       ["version": 2, "type": "checkpoint", "required": false, "logSize": logSize()]] {
            try original.write(to: url)
            try append(change)
            var reader = TranscriptReader()
            let snapshot = reader.read(log: log)
            XCTAssertFalse(snapshot.structured)
            XCTAssertNotNil(snapshot.problem)
            XCTAssertTrue(snapshot.items.contains { $0.text == "readable answer" })
            XCTAssertThrowsError(try TranscriptJournal(log: log, resuming: true, logSize: logSize()))
        }
    }

    func testReadableLogAheadOfJournalCannotLookComplete() throws {
        let journal = try journal()
        journal.record(.agent, "saved")
        let output = try FileHandle(forWritingTo: log)
        try output.seekToEnd()
        try output.write(contentsOf: Data("[error] persistence failed\n".utf8))
        try output.close()
        var reader = TranscriptReader()
        let snapshot = reader.read(log: log)
        XCTAssertFalse(snapshot.structured)
        XCTAssertNotNil(snapshot.problem)
        XCTAssertTrue(snapshot.items.contains { $0.kind == .error && $0.text == "persistence failed" })
    }

    func testPresentationFailureDoesNotBlockContinuationOrOverwriteHistory() throws {
        let first = try journal()
        first.record(.agent, "original")
        first.finish(.succeeded)
        try append(["version": 2, "type": "header", "logSize": logSize()])
        let url = TranscriptReader.journalURL(for: log)
        let damaged = try Data(contentsOf: url)
        let spec = LaunchSpec(executable: "/not-launched", prompt: "continue", arguments: [],
                              workingDirectory: folder.path, environment: [:], mode: .codexDaemon,
                              timeout: nil, log: log, resume: "session")
        let output = try FileHandle(forWritingTo: log)
        try output.seekToEnd()
        let fallback = ProcessLauncher.journal(for: spec, output: output,
                                               events: RunEvents(session: { _ in }, finished: { _ in }))
        fallback.record(.user, spec.prompt)
        fallback.record(.agent, "continued")
        fallback.finish(.succeeded)
        XCTAssertEqual(try Data(contentsOf: url), damaged)
        var reader = TranscriptReader()
        let snapshot = reader.read(log: log)
        XCTAssertNotNil(snapshot.problem)
        XCTAssertTrue(snapshot.items.contains { $0.text == "continued" })
        XCTAssertTrue(snapshot.items.contains { $0.kind == .error && $0.text.contains("Couldn't open chat") })
    }

    func testLegacyAndShellDoNotRequireNormalizedHistory() throws {
        try "[you] go\nold answer\n".write(to: log, atomically: true, encoding: .utf8)
        var reader = TranscriptReader()
        let old = reader.read(log: log)
        XCTAssertFalse(old.structured)
        XCTAssertNil(old.problem)
        XCTAssertEqual(old.items.map(\.text), ["go", "old answer"])
        let journal = try journal()
        journal.record(.agent, "agent")
        let shell = reader.read(log: log, shell: true)
        XCTAssertFalse(shell.structured)
        XCTAssertTrue(shell.items.contains { $0.kind == .output })
    }

    func testReaderWaitsForWholeRecordAndRejectsTruncatedFinishedHistory() throws {
        let journal = try journal()
        journal.record(.agent, "first")
        let data = try JSONSerialization.data(withJSONObject: ["version": 1, "type": "item", "id": 25,
            "kind": "agent", "text": "second", "logSize": logSize()])
        let handle = try FileHandle(forWritingTo: TranscriptReader.journalURL(for: log))
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data.prefix(12))
        var reader = TranscriptReader()
        XCTAssertEqual(reader.read(log: log).items.map(\.text), ["first"])
        XCTAssertNotNil(reader.read(log: log, finished: true).problem)
        try handle.write(contentsOf: data.dropFirst(12) + Data([10]))
        XCTAssertEqual(reader.read(log: log, finished: true).items.map(\.text), ["first", "second"])
    }

    func testNormalizedHistoryDoesNotCutMessagesAtLegacyTailLimit() throws {
        let journal = try journal()
        let text = "start\n" + String(repeating: "x", count: 410_000) + "\nend"
        journal.record(.agent, text)
        journal.finish(.succeeded)
        var reader = TranscriptReader()
        let snapshot = reader.read(log: log, finished: true)
        XCTAssertTrue(snapshot.structured)
        XCTAssertEqual(snapshot.items.first?.text, text)
        XCTAssertEqual(reader.read(log: log), snapshot)
    }

    /// The optional export gives rendered checks data from the real producer,
    /// rather than a second handwritten copy of the journal schema.
    func testBasicKindsRoundTrip() throws {
        let journal = try journal()
        journal.record(.user, "Review this synthetic example.\nKeep the explanation short.")
        journal.record(.agent, "Checking the example before suggesting a change.")
        journal.record(.tool, "FutureTool, details unavailable")
        journal.record(.plan, PlanStep.body([PlanStep(status: .completed, text: "Read the example"),
                                            PlanStep(status: .inProgress, text: "Explain the result")]))
        journal.record(.agent, "## Result\nThe basic chat stays readable.\n\n```swift\nlet ready = true\n```")
        journal.record(.error, "Synthetic warning, no external action was performed.")
        journal.finish(.succeeded)
        var reader = TranscriptReader()
        let snapshot = reader.read(log: log, finished: true)
        XCTAssertTrue(snapshot.structured)
        XCTAssertEqual(snapshot.items.map(\.kind), [.user, .agent, .tool, .plan, .agent, .error, .status])
        if let destination = ProcessInfo.processInfo.environment["ROTA_TRANSCRIPT_FIXTURE_DIR"] {
            try Self.exportFixture(log: log, to: URL(fileURLWithPath: destination))
        }
    }

    static func exportFixture(log: URL, to destination: URL) throws {
        let location = StorageLocation(root: destination, logs: destination.appendingPathComponent("Logs"))
        let routine = Routine(id: "transcript-check", name: "Transcript check", workingDirectory: destination.path,
                              schedule: "0 9 * * *", harness: .codex, enabled: false, prompt: "Synthetic example")
        try RoutineStore(location: location).save([routine])
        let history = RunHistory(location: location)
        var record = RunRecord(routineID: routine.id, trigger: .manual, harness: .codex,
                               startedAt: Date().addingTimeInterval(-30), endedAt: Date(), outcome: .succeeded)
        let target = history.logFile(for: record)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: log, to: target)
        try FileManager.default.copyItem(at: TranscriptReader.journalURL(for: log),
                                        to: TranscriptReader.journalURL(for: target))
        record.logPath = target.path
        record.sessionID = "synthetic-session"
        try history.upsert(record)
    }

    private func logSize() -> UInt64 {
        (try? FileManager.default.attributesOfItem(atPath: log.path)[.size] as? UInt64) ?? 0
    }

    private func append(_ object: [String: Any]) throws {
        let handle = try FileHandle(forWritingTo: TranscriptReader.journalURL(for: log))
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: JSONSerialization.data(withJSONObject: object) + Data([10]))
    }
}
