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
        history.closeOrphans(routineIDs: ["a"], now: Date(timeIntervalSince1970: 60))
        let closed = history.records(for: "a")
        XCTAssertEqual(closed.count, 1)
        XCTAssertEqual(closed[0].outcome, .interrupted)
        XCTAssertEqual(closed[0].endedAt, Date(timeIntervalSince1970: 60))
    }

    func testModelSnapshotRoundTripsAndOldRecordsDecodeWithoutIt() throws {
        var record = RunRecord(routineID: "a", trigger: .manual, harness: .codex,
                               startedAt: Date(timeIntervalSince1970: 0), outcome: .succeeded)
        record.model = "gpt-6-luna"
        record.effort = "high"
        let history = RunHistory(location: location)
        try history.upsert(record)
        XCTAssertEqual(history.records(for: "a"), [record])
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONFile.encoder.encode(record))
            as? [String: Any])
        old.removeValue(forKey: "model")
        old.removeValue(forKey: "effort")
        let decoded = try JSONFile.decoder.decode(RunRecord.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertNil(decoded.model)
        XCTAssertNil(decoded.effort)
        XCTAssertEqual(decoded.id, record.id)
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
