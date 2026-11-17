@testable import RotaCore
import XCTest

/// A session between runs takes another model and effort for its next message, and each run's
/// answers keep the configuration that run reported.
@MainActor
final class SessionModelTests: XCTestCase {
    private var directory: URL!
    private var scheduler: Scheduler!
    private var launcher: ModelLauncher!
    private var routine: Routine!

    override func setUp() async throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("rota-model-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        launcher = ModelLauncher()
        scheduler = Scheduler(location: StorageLocation(root: directory, logs: directory), launcher: launcher)
        scheduler.executable = { "/synthetic/\($0.commandName)" }
        routine = Routine(id: "model", name: "Model test", workingDirectory: directory.path,
                          schedule: "0 15 * * *", harness: .codex, prompt: "Routine prompt")
        scheduler.save(routine)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func finishedSession(harness: Harness = .codex) throws -> RunRecord {
        var record = RunRecord(routineID: routine.id, trigger: .scheduled, harness: harness,
                               startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                               endedAt: Date(timeIntervalSince1970: 1_700_000_100), outcome: .succeeded)
        record.sessionID = "native-session"
        record.logPath = directory.appendingPathComponent("session.log").path
        try Data("[you] Routine prompt\nDone.\n".utf8).write(to: URL(fileURLWithPath: try XCTUnwrap(record.logPath)))
        record.model = "old-model"
        record.reportedModel = "old-model"
        record.reportedEffort = "low"
        scheduler.saveRecord(record)
        return record
    }

    func testNextMessageRunsOnTheChosenModelAndEarlierAnswersKeepTheirs() throws {
        let record = try finishedSession()
        XCTAssertTrue(scheduler.canConfigure(record))
        XCTAssertTrue(scheduler.configure(record, model: "new-model", effort: "high"))
        let configured = try XCTUnwrap(scheduler.current(record.id, routineID: routine.id))
        XCTAssertEqual(configured.model, "new-model")
        XCTAssertEqual(configured.effort, "high")
        XCTAssertNil(configured.reportedModel)
        XCTAssertNil(configured.reportedEffort)
        // A session from before marks were kept: its answers so far ran on what it reported.
        XCTAssertEqual(configured.configurations, [ConfigurationMark(fromItem: 0, model: "old-model", effort: "low")])

        XCTAssertTrue(scheduler.message("Continue on the new model", to: configured))
        let spec = try XCTUnwrap(launcher.specs.last)
        XCTAssertEqual(spec.resume, "native-session")
        XCTAssertEqual(spec.model, "new-model")
        XCTAssertEqual(spec.effort, "high")
        XCTAssertFalse(scheduler.canConfigure(configured), "A running session keeps its model until the run ends")
        XCTAssertFalse(scheduler.configure(configured, model: "other", effort: nil))

        launcher.events.last?.configuration(SessionConfiguration(model: "new-model-2026", effort: "high", fromItem: 2))
        launcher.events.last?.configuration(SessionConfiguration(model: "new-model-2026", effort: "high",
                                                                 modelTitle: "New Model", fromItem: 2))
        let reported = try XCTUnwrap(scheduler.current(record.id, routineID: routine.id))
        XCTAssertEqual(reported.configurations?.count, 2, "One mark per run, updated as the run reports more")
        XCTAssertEqual(reported.configuration(at: 1)?.model, "old-model")
        XCTAssertEqual(reported.configuration(at: 2)?.model, "new-model-2026")
        XCTAssertEqual(reported.configuration(at: 9)?.modelTitle, "New Model")
        launcher.events.last?.finished(.succeeded)
        XCTAssertTrue(scheduler.canConfigure(try XCTUnwrap(scheduler.current(record.id, routineID: routine.id))))
    }

    func testOnlyAgentSessionsBetweenRunsTakeAnotherModel() throws {
        let shell = try finishedSession(harness: .shell)
        XCTAssertFalse(scheduler.canConfigure(shell))
        XCTAssertFalse(scheduler.configure(shell, model: "any", effort: nil))
        var unattached = try finishedSession()
        unattached.sessionID = nil
        scheduler.saveRecord(unattached)
        XCTAssertFalse(scheduler.canConfigure(unattached), "Nothing to continue without a native session")
    }

    func testJournalReportsTheRunsFirstTranscriptItem() throws {
        let log = directory.appendingPathComponent("journal.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let reported = expectation(description: "configuration")
        nonisolated(unsafe) var value: SessionConfiguration?
        let events = RunEvents(session: { _ in }, finished: { _ in }, configuration: {
            value = $0
            reported.fulfill()
        })
        let transcript = try TranscriptJournal(log: log, resuming: false, logSize: 0)
        let journal = RunJournal(output: try FileHandle(forWritingTo: log), events: events, transcript: transcript)
        journal.record(.user, "Prompt")
        journal.record(.agent, "Answer")
        journal.configure(SessionConfiguration(model: "fixture"))
        wait(for: [reported], timeout: 2)
        XCTAssertEqual(value?.fromItem, 0, "Reported mid-run, the mark still starts at the run's prompt")
        XCTAssertEqual(value?.model, "fixture")
    }
}

private final class ModelLauncher: RoutineLaunching {
    var specs: [LaunchSpec] = []
    var events: [RunEvents] = []

    func launch(_ spec: LaunchSpec, events: RunEvents) throws -> RunControl {
        specs.append(spec)
        self.events.append(events)
        return ModelControl()
    }
}

private final class ModelControl: RunControl {
    func stop() {}
    func send(_ message: String) {}
}
