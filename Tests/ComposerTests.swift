@testable import Rota
@testable import RotaCore
import XCTest

final class ComposerTests: XCTestCase {
    func testModelAndEffortUseAppliedSessionValues() {
        var record = RunRecord(routineID: "fixture", trigger: .manual, harness: .claude,
                               startedAt: Date(), outcome: .succeeded)
        XCTAssertEqual(ModelLabel.model(record: record, models: [:]), "Model unavailable")
        XCTAssertNil(ModelLabel.effort(record), "An unknown effort is left out, never called Default")
        record.model = "alias"
        record.reportedModel = "resolved-model"
        record.reportedEffort = "medium"
        XCTAssertEqual(ModelLabel.model(record: record, models: [:]), "resolved-model")
        XCTAssertEqual(ModelLabel.effort(record), "Medium")
        record.reportedModel = "claude-opus-5-5"
        XCTAssertEqual(ModelLabel.model(record: record, models: [:]), "Opus 5.5")
        record.effort = "high"
        XCTAssertEqual(ModelLabel.effort(record), "Medium",
                       "The adapter reports the applied effort, including turn overrides")
    }

    func testReportedEffortWinsOverRequestedLevelAndUnknownIsNotCalledDefault() {
        var record = RunRecord(routineID: "fixture", trigger: .manual, harness: .claude,
                               startedAt: Date(), outcome: .succeeded)
        XCTAssertNil(ModelLabel.effort(record), "An unknown effort is left out, never called Default")
        record.effort = "high"
        XCTAssertEqual(ModelLabel.effort(record, fallback: "low"), "Low")
        record.reportedEffort = "low"
        XCTAssertEqual(ModelLabel.effort(record), "Low")
    }

    func testCatalogTitlesAndSeparateEffortAreSharedByRoutineAndSessionLabels() {
        for harness in Harness.agents {
            let option = ModelOption(id: "fixture-v2", title: "Fixture V2", efforts: ["high"],
                                     isDefault: true, aliases: ["fixture-v2-high", "alias"])
            let models = [harness: [option]]
            var routine = Routine(id: "fixture", name: "Fixture", workingDirectory: "/tmp",
                                  schedule: "0 9 * * *", harness: harness, enabled: false, prompt: "Synthetic")
            routine.model = "alias"
            routine.effort = "high"
            var record = RunRecord(routineID: routine.id, trigger: .manual, harness: harness,
                                   startedAt: Date(), outcome: .succeeded)
            record.reportedModel = "fixture-v2-high"
            record.reportedEffort = "high"
            XCTAssertEqual(ModelLabel.model(record: record, models: models), option.title)
            XCTAssertEqual(ModelLabel.name(record: record, models: models), "\(harness.title)  \(option.title)")
            XCTAssertEqual(ModelLabel.configuration(routine, models: models),
                           "\(harness.title) · \(option.title) · High")
            XCTAssertEqual(ModelLabel.effort(record), "High")
            record.reportedModelTitle = option.title
            XCTAssertEqual(ModelLabel.model(record: record, models: [:]), option.title,
                           "A saved native title keeps effort out while the catalog is unavailable")
        }
    }

    func testMissingClaudeExecutableDoesNotInventAnUnversionedCatalog() {
        XCTAssertTrue(ModelCatalog.models(for: .claude, executable: "/missing/claude").isEmpty)
    }

    func testAttachmentHistoryRendersFromTheRealMessageProducer() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let destination = ProcessInfo.processInfo.environment["ROTA_COMPOSER_FIXTURE_DIR"]
            .map { URL(fileURLWithPath: $0) } ?? temporary
        let location = StorageLocation(root: destination, logs: destination.appendingPathComponent("Logs"))
        let routine = Routine(id: "composer-check", name: "Composer check", workingDirectory: destination.path,
                              schedule: "0 9 * * *", harness: .claude, enabled: false, prompt: "Synthetic example")
        try RoutineStore(location: location).save([routine])
        let history = RunHistory(location: location)
        var record = RunRecord(routineID: routine.id, trigger: .manual, harness: .claude,
                               startedAt: Date().addingTimeInterval(-30), endedAt: Date(), outcome: .succeeded)
        let log = history.logFile(for: record)
        try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
        let source = destination.appendingPathComponent("Example report.txt")
        try "Synthetic attachment contents".write(to: source, atomically: true, encoding: .utf8)
        let files = try ChatAttachmentStore(log: log).stage([source])
        let message = try ChatMessage(text: "Review this file.", attachments: files).encoded()
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let journal = RunJournal(output: try FileHandle(forWritingTo: log),
                                 events: RunEvents(session: { _ in }, finished: { _ in }),
                                 transcript: try TranscriptJournal(log: log, resuming: false, logSize: 0))
        journal.record(.user, message)
        journal.record(.agent, "The example is ready. You can attach another file below.")
        journal.finish(.succeeded)
        record.logPath = log.path
        record.sessionID = "synthetic-session"
        record.reportedEffort = "high"
        record.reportedModel = "claude-opus-5-5"
        XCTAssertEqual(ModelLabel.model(record: record, models: [:]), "Opus 5.5")
        record.effort = "high"
        try history.upsert(record)
        var reader = TranscriptReader()
        let snapshot = reader.read(log: log, finished: true)
        XCTAssertEqual(ChatMessage.decode(try XCTUnwrap(snapshot.items.first).text).attachments, files)
    }
}
