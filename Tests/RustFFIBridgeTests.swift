@testable import Rota
@testable import RotaCore
import XCTest

enum TranscriptJournalTests {
    static func exportFixture(log: URL, to destination: URL) throws {
        let location = StorageLocation(root: destination, logs: destination.appendingPathComponent("Logs"))
        let routine = Routine(
            id: "transcript-check",
            name: "Transcript check",
            workingDirectory: destination.path,
            schedule: "0 9 * * *",
            harness: .codex,
            enabled: false,
            prompt: "Synthetic example"
        )
        try RoutineStore(location: location).save([routine])
        let history = RunHistory(location: location)
        var record = RunRecord(
            routineID: routine.id,
            trigger: .manual,
            harness: .codex,
            startedAt: Date().addingTimeInterval(-30),
            endedAt: Date(),
            outcome: .succeeded
        )
        let target = history.logFile(for: record)
        try FileManager.default.createDirectory(
            at: target.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: log, to: target)
        try FileManager.default.copyItem(
            at: TranscriptReader.journalURL(for: log),
            to: TranscriptReader.journalURL(for: target)
        )
        record.logPath = target.path
        record.sessionID = "synthetic-session"
        try history.upsert(record)
    }
}

@MainActor
final class RustFFIBridgeTests: XCTestCase {
    private final class UnusedLauncher: RoutineLaunching {
        func launch(_ spec: LaunchSpec, events: RunEvents) throws -> RunControl {
            fatalError("UnusedLauncher must never be invoked")
        }
    }

    func testSwiftSchedulerAndControlSocketRoundTripThroughRustCore() async throws {
        let folder = URL(fileURLWithPath: "/tmp/rota-ffi-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let location = StorageLocation(root: folder, logs: folder.appendingPathComponent("Logs"))
        let scheduler = Scheduler(location: location, launcher: UnusedLauncher())
        XCTAssertTrue(scheduler.routines.isEmpty)

        let routine = Routine(
            id: "morning-sync",
            name: "Morning Sync",
            workingDirectory: folder.path,
            schedule: "0 9 * * 1-5",
            harness: .codex,
            enabled: true,
            prompt: "Summarize overnight runs."
        )
        XCTAssertTrue(scheduler.save(routine))
        XCTAssertEqual(scheduler.routines.map(\.id), ["morning-sync"])
        XCTAssertNotNil(scheduler.routines.first?.nextFire, "Rust scheduler must compute nextFire on save")

        let socketURL = folder.appendingPathComponent("rota.sock")
        let server = ControlServer(socket: socketURL) { method, params in
            await scheduler.controlRequest(method, params)
        }
        try server.start()
        defer { server.stop() }

        let rowIDs: [String] = try await Task.detached {
            let listed = try ControlClient.call("routines.list", [:], socket: socketURL, timeout: 5)
            let rows = listed as? [[String: Any]] ?? []
            return rows.compactMap { $0["id"] as? String }
        }.value
        XCTAssertEqual(rowIDs, ["morning-sync"])

        XCTAssertTrue(scheduler.setEnabled(false, for: "morning-sync"))
        XCTAssertEqual(scheduler.routine("morning-sync")?.enabled, false)
        XCTAssertTrue(scheduler.delete("morning-sync"))
        XCTAssertTrue(scheduler.routines.isEmpty)
    }

    func testFollowPreviewUpdatesRunningSessionAcrossWrites() async throws {
        let folder = URL(fileURLWithPath: "/tmp/rota-preview-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let log = folder.appendingPathComponent("live.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let output = try FileHandle(forWritingTo: log)
        let journal = RunJournal(
            output: output,
            events: RunEvents(session: { _ in }, finished: { _ in }),
            transcript: try TranscriptJournal(log: log, resuming: false, logSize: 0)
        )
        journal.record(.agent, "Initial message")

        var record = RunRecord(
            routineID: "preview",
            trigger: .manual,
            harness: .codex,
            startedAt: Date(),
            outcome: .running
        )
        record.logPath = log.path

        let reader = TranscriptSessionReader()
        var seen: [String] = []
        let secondArrived = expectation(description: "running session preview refreshes")
        let followTask = Task {
            await reader.followPreview(of: record) { text in
                seen.append(text)
                if text == "Updated live message" {
                    secondArrived.fulfill()
                }
            }
        }
        defer { followTask.cancel() }

        try await Task.sleep(for: .milliseconds(150))
        journal.record(.agent, "Updated live message")
        await fulfillment(of: [secondArrived], timeout: 4.5)
        XCTAssertTrue(seen.contains("Initial message"))
        XCTAssertEqual(seen.last, "Updated live message")
    }
}
