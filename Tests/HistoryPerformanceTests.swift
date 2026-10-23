@testable import RotaCore
import XCTest

@MainActor
final class HistoryPerformanceTests: XCTestCase {
    func testRepeatedHistoryReads() throws {
        guard ProcessInfo.processInfo.environment["ROTA_PERFORMANCE"] == "1" else {
            throw XCTSkip("Set ROTA_PERFORMANCE=1 to measure synthetic history reads")
        }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let location = StorageLocation(root: directory, logs: directory.appendingPathComponent("logs"))
        let routines = (0..<30).map { index in
            Routine(id: "routine-\(index)", name: "Synthetic routine", workingDirectory: "/tmp",
                    schedule: "0 10 * * *", harness: .shell, enabled: false, prompt: "true")
        }
        try RoutineStore(location: location).save(routines)
        for routine in routines {
            let records = (0..<50).map { index in
                RunRecord(routineID: routine.id, trigger: .manual, harness: .shell,
                          startedAt: Date(timeIntervalSince1970: Double(index)),
                          endedAt: Date(timeIntervalSince1970: Double(index + 1)), outcome: .succeeded)
            }
            try JSONFile.write(records, to: location.historyDirectory.appendingPathComponent("\(routine.id).json"))
        }
        let scheduler = Scheduler(location: location, launcher: ProcessLauncher())
        XCTAssertEqual(scheduler.allRecords().count, 1_500)
        measure {
            for _ in 0..<10 { XCTAssertEqual(scheduler.allRecords().count, 1_500) }
        }
    }
}
