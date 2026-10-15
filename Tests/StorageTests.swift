@testable import RotaCore
import XCTest

final class StorageTests: XCTestCase {
    private var directory: URL!
    private var location: StorageLocation!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        location = StorageLocation(root: directory.appendingPathComponent("support"),
                                   logs: directory.appendingPathComponent("logs"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testRoutinesRoundTrip() throws {
        let store = RoutineStore(location: location)
        XCTAssertEqual(try store.load(), [])
        let routine = Routine(id: "a", name: "A", workingDirectory: "/p", schedule: "0 9 * * *",
                              harness: .codex, enabled: true, prompt: "go",
                              nextFire: Date(timeIntervalSince1970: 1_800_000_000))
        try store.save([routine])
        XCTAssertEqual(try store.load(), [routine])
    }

    func testRoutineIDsCannotCollideOnACaseInsensitiveFileSystem() throws {
        let first = Routine(id: "report", name: "Report", workingDirectory: "/tmp", schedule: "0 9 * * *",
                            harness: .shell, prompt: "true")
        var second = first
        second.id = "REPORT"
        XCTAssertThrowsError(try RoutineStore(location: location).save([first, second]))
    }

    func testHistoryRejectsMismatchedAndDuplicateSessionsWithoutOverwritingThem() throws {
        let history = RunHistory(location: location)
        let record = RunRecord(routineID: "a", trigger: .manual, harness: .grok,
                               startedAt: Date(), outcome: .running)
        let file = location.historyDirectory.appendingPathComponent("b.json")
        for corrupt in [[record], [record, record]] {
            try JSONFile.write(corrupt, to: file)
            let original = try Data(contentsOf: file)
            XCTAssertThrowsError(try history.loadRecords(for: "b"))
            let replacement = RunRecord(routineID: "b", trigger: .manual, harness: .grok,
                                        startedAt: Date(), outcome: .running)
            XCTAssertThrowsError(try history.upsert(replacement))
            XCTAssertEqual(try Data(contentsOf: file), original)
        }
        try JSONFile.write([record, record], to: location.historyDirectory.appendingPathComponent("a.json"))
        XCTAssertThrowsError(try history.loadRecords(for: "a"))
    }

    func testRunsStartedInTheSameSecondHaveIndependentLogs() {
        let history = RunHistory(location: location)
        let first = RunRecord(routineID: "a", trigger: .manual, harness: .codex,
                              startedAt: Date(timeIntervalSince1970: 100), outcome: .running)
        let second = RunRecord(routineID: "a", trigger: .manual, harness: .codex,
                               startedAt: first.startedAt, outcome: .running)
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertNotEqual(history.logFile(for: first), history.logFile(for: second))
    }

    func testCorruptHistoryIsNeverReplacedByANewRecord() throws {
        let file = location.historyDirectory.appendingPathComponent("a.json")
        try FileManager.default.createDirectory(at: location.historyDirectory, withIntermediateDirectories: true)
        let corrupt = Data("{broken history".utf8)
        try corrupt.write(to: file)
        let record = RunRecord(routineID: "a", trigger: .manual, harness: .codex,
                               startedAt: .now, outcome: .running)
        XCTAssertThrowsError(try RunHistory(location: location).upsert(record))
        XCTAssertEqual(try Data(contentsOf: file), corrupt)
    }

    func testSkippedSlotsCannotEvictTheRunningConversation() throws {
        let history = RunHistory(location: location)
        let active = RunRecord(routineID: "a", trigger: .manual, harness: .codex,
                               startedAt: Date(timeIntervalSince1970: 0), outcome: .running)
        try history.upsert(active)
        for index in 1...60 {
            let skip = RunRecord(routineID: "a", trigger: .scheduled, harness: .codex,
                                 startedAt: Date(timeIntervalSince1970: TimeInterval(index)),
                                 outcome: .skipped("overlap"))
            try history.upsert(skip)
        }
        XCTAssertEqual(history.records(for: "a").count, RunHistory.limit)
        XCTAssertTrue(history.records(for: "a").contains { $0.id == active.id })
        var finished = active
        finished.outcome = .succeeded
        try history.upsert(finished)
        XCTAssertTrue(history.records(for: "a").contains { $0.id == active.id })
    }

    func testRetentionCannotDeleteAnExternalFileNamedByHistory() throws {
        let outside = directory.appendingPathComponent("user.log")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("keep this".utf8).write(to: outside)
        let history = RunHistory(location: location)
        let record = RunRecord(routineID: "a", trigger: .manual, harness: .shell,
                               startedAt: .now, outcome: .succeeded, logPath: outside.path)
        try history.upsert(record)
        history.removeAll(for: "a")
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "keep this")
    }

    func testUnsafeAndDuplicateRoutineIDsCannotReachStorage() throws {
        let store = RoutineStore(location: location)
        let routine = Routine(id: "a", name: "A", workingDirectory: "/tmp", schedule: "0 9 * * *", prompt: "go")
        XCTAssertThrowsError(try store.save([routine, routine]))
        for id in ["../outside", ".", "..", "", "nested/task"] {
            var unsafe = routine
            unsafe.id = id
            XCTAssertThrowsError(try store.save([unsafe]), id)
            // Loading a hand-edited file has the same boundary as writing one.
            try JSONFile.write([unsafe], to: location.routinesFile)
            XCTAssertThrowsError(try store.load(), id)
        }
        var imported = routine
        imported.id = "Отчёт по SEO"
        try store.save([imported])
        XCTAssertEqual(try store.load(), [imported])
    }

    func testHistoryKeepsNewestAndDeletesDroppedLogs() throws {
        let history = RunHistory(location: location)
        var logs: [URL] = []
        for index in 0..<(RunHistory.limit + 2) {
            var record = RunRecord(routineID: "a", trigger: .scheduled, harness: .claude,
                                   startedAt: Date(timeIntervalSince1970: TimeInterval(index * 60)),
                                   outcome: .succeeded)
            let log = history.logFile(for: record)
            try FileManager.default.createDirectory(at: log.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: log.path, contents: Data("x".utf8))
            record.logPath = log.path
            logs.append(log)
            try history.upsert(record)
        }
        let records = history.records(for: "a")
        XCTAssertEqual(records.count, RunHistory.limit)
        XCTAssertEqual(records.first?.startedAt, Date(timeIntervalSince1970: TimeInterval((RunHistory.limit + 1) * 60)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: logs[0].path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: logs[1].path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: logs[2].path))
    }

    func testOrphanedRunsBecomeInterrupted() throws {
        let history = RunHistory(location: location)
        let record = RunRecord(routineID: "a", trigger: .manual, harness: .grok,
                               startedAt: Date(timeIntervalSince1970: 0), outcome: .running)
        try history.upsert(record)
        try history.closeOrphans(routineIDs: ["a"], now: Date(timeIntervalSince1970: 60))
        let closed = history.records(for: "a")
        XCTAssertEqual(closed.count, 1)
        XCTAssertEqual(closed[0].outcome, .interrupted)
        XCTAssertEqual(closed[0].endedAt, Date(timeIntervalSince1970: 60))
    }

    func testImportReadsRegistrationsAndStubBodies() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let stub = directory.appendingPathComponent("stub.md")
        try "---\nname: daily-report\ndescription: x\n---\n\nInvoke the `daily-report` skill.\n"
            .write(to: stub, atomically: true, encoding: .utf8)
        let tasks = directory.appendingPathComponent("scheduled-tasks.json")
        let json = """
            {"scheduledTasks": [
              {"id": "daily-report", "displayName": "Daily report", "cronExpression": "0 10 * * *",
               "enabled": true, "filePath": "\(stub.path)", "cwd": "/projects/report"},
              {"id": "no-stub", "cronExpression": "5 9 * * 1", "enabled": false,
               "filePath": "/missing.md", "cwd": "/projects/other"},
              {"id": "no-schedule", "cwd": "/projects/other"}
            ], "recordedSkips": []}
            """
        try json.write(to: tasks, atomically: true, encoding: .utf8)

        let candidates = try ClaudeDesktopImport.candidates(from: tasks)
        XCTAssertEqual(candidates.map(\.routine.id), ["daily-report", "no-stub"])
        XCTAssertEqual(Set(candidates.map(\.source)), [.claudeDesktop])
        XCTAssertEqual(candidates[0].routine.name, "Daily report")
        XCTAssertEqual(candidates[0].routine.prompt, "Invoke the `daily-report` skill.")
        XCTAssertTrue(candidates[0].onInSource)
        XCTAssertFalse(candidates[0].routine.enabled, "imports start turned off")
        XCTAssertEqual(candidates[1].routine.name, "no-stub")
        XCTAssertEqual(candidates[1].routine.prompt,
                       Routine.defaultPrompt(skill: "no-stub", workingDirectory: "/projects/other"))
    }

    func testFrontmatterStripping() {
        XCTAssertEqual(ClaudeDesktopImport.stripFrontmatter("---\na: b\n---\nbody"), "body")
        XCTAssertEqual(ClaudeDesktopImport.stripFrontmatter("plain body\n"), "plain body")
        XCTAssertNil(ClaudeDesktopImport.stripFrontmatter("---\na: b\n---\n  \n"))
    }

    /// Checks give the build under test its own folder, so it never opens the installed app's routines.
    func testADataFolderInTheEnvironmentReplacesTheStandardOne() {
        let original = ProcessInfo.processInfo.environment["ROTA_DATA_DIR"]
        setenv("ROTA_DATA_DIR", "/tmp/rota-data-check", 1)
        defer { if let original { setenv("ROTA_DATA_DIR", original, 1) } else { unsetenv("ROTA_DATA_DIR") } }
        XCTAssertEqual(StorageLocation.standard.root.path, "/tmp/rota-data-check")
        XCTAssertEqual(StorageLocation.standard.logs.path, "/tmp/rota-data-check/Logs")
        XCTAssertEqual(ControlServer.standardSocket.path, "/tmp/rota-data-check/rota.sock")
    }
}
