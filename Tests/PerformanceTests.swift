@testable import RotaCore
import XCTest

final class PerformanceTests: XCTestCase {
    func testCPUUsesElapsedTimeAndUnknownSamplesStayUnknown() {
        let first = PerformanceResources(uptime: 10, cpuSeconds: 40, residentBytes: 100)
        let next = PerformanceResources(uptime: 15, cpuSeconds: 43, residentBytes: 200)
        XCTAssertEqual(next.cpuPercent(since: first), 60)
        XCTAssertNil(first.cpuPercent(since: nil))
        XCTAssertNil(first.cpuPercent(since: first))
        XCTAssertNil(first.cpuPercent(since: next))
        let unknown = PerformanceResources(uptime: 20, cpuSeconds: nil, residentBytes: nil)
        XCTAssertNil(unknown.cpuPercent(since: first))
        XCTAssertNil(next.cpuPercent(since: unknown))
    }

    func testMainQueueKeepsOneProbeAndRecordsStallAndRecovery() throws {
        var state = PerformanceProbeState()
        let probe = try XCTUnwrap(state.begin(at: 10))
        XCTAssertNil(state.begin(at: 10.5))
        XCTAssertNil(state.stalled(at: 10.9))
        XCTAssertEqual(state.stalled(at: 11), 1)
        XCTAssertNil(state.stalled(at: 12))
        XCTAssertEqual(state.finish(probe, at: 13), 3)
        XCTAssertEqual(state.maxDelay, 3)
        XCTAssertNil(state.finish(probe, at: 14))
        XCTAssertNotNil(state.begin(at: 14))
    }

    func testSleepDiscardsOldProbes() throws {
        var state = PerformanceProbeState()
        let stale = try XCTUnwrap(state.begin(at: 10))
        state.setSleeping(true)
        XCTAssertNil(state.stalled(at: 100))
        XCTAssertNil(state.begin(at: 100))
        XCTAssertNil(state.finish(stale, at: 100))
        state.setSleeping(false)
        let fresh = try XCTUnwrap(state.begin(at: 101))
        XCTAssertNil(state.finish(stale, at: 102))
        XCTAssertEqual(state.finish(fresh, at: 102), 1)
    }

    func testTranscriptCountersSeparateEarlierAndShellReads() {
        var stats = TranscriptPerformance()
        stats.add(seconds: 0.01, items: 50, earlier: false, shell: true)
        stats.add(seconds: 0.2, items: 100, earlier: true, shell: false)
        XCTAssertEqual(stats.reads, 2)
        XCTAssertEqual(stats.earlierReads, 1)
        XCTAssertEqual(stats.shellReads, 1)
        XCTAssertEqual(stats.totalMs, 210, accuracy: 0.001)
        XCTAssertEqual(stats.maxMs, 200)
        XCTAssertEqual(stats.maxItems, 100)
    }

    func testRotationBoundsBothFilesAndPreservesNewLaunchIdentity() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let limit = 1_024
        let journal = try PerformanceLog(directory: folder, metadata: ["appVersion": "test", "launchID": "first"],
                                         byteLimit: limit)
        for index in 0..<40 {
            try journal.append(PerformanceEvent(kind: .resources, residentBytes: UInt64(index)))
        }
        try journal.close()
        let contents = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
        XCTAssertEqual(Set(contents.map(\.lastPathComponent)), ["current.jsonl", "previous.jsonl"])
        for file in contents {
            let data = try Data(contentsOf: file)
            XCTAssertLessThanOrEqual(data.count, limit)
            let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
            XCTAssertEqual(permissions, 0o600)
        }
        let relaunched = try PerformanceLog(directory: folder, metadata: ["appVersion": "new", "launchID": "second"],
                                            byteLimit: limit)
        try relaunched.append(PerformanceEvent(kind: .shutdown))
        try relaunched.close()
        let lines = try String(contentsOf: folder.appendingPathComponent("current.jsonl"), encoding: .utf8)
            .split(separator: "\n")
        let records = try lines.compactMap { try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        XCTAssertTrue(records.contains { $0["launchID"] as? String == "second" })
        XCTAssertEqual(records.last?["kind"] as? String, "shutdown")
    }

    func testUnavailableJournalDoesNotPreventAppFromContinuing() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data().write(to: folder)
        let diagnostics = PerformanceDiagnostics()
        diagnostics.start(directory: folder, metadata: [:]) { PerformanceContext() }
        diagnostics.recordTranscript(seconds: 1, items: 10, earlier: true, shell: false)
        diagnostics.setSleeping(true)
        diagnostics.stop()
        XCTAssertEqual(try Data(contentsOf: folder).count, 0)
    }

    func testCommonTranscriptReaderRecordsCountsWithoutContentOrPaths() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = folder.appendingPathComponent("private-session.log")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("private fixture message\n".utf8).write(to: log)
        let diagnostics = PerformanceDiagnostics.shared
        let journal = folder.appendingPathComponent("diagnostics")
        diagnostics.start(directory: journal, metadata: [:]) { PerformanceContext() }
        let reader = TranscriptSessionReader()
        _ = await reader.read(log: log, shell: false, finished: true)
        _ = await reader.read(log: log, shell: true, finished: true, earlier: true)
        diagnostics.stop()
        let text = try String(contentsOf: journal.appendingPathComponent("current.jsonl"), encoding: .utf8)
        let lines = text.split(separator: "\n")
        let records = try lines.compactMap { try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
        XCTAssertEqual(records.last?["kind"] as? String, "shutdown")
        // An immediate resource tick may already have flushed a read; count all recorded aggregates.
        let aggregates = records.filter { ["resources", "shutdown"].contains($0["kind"] as? String ?? "") }
            .compactMap { $0["transcript"] as? [String: Any] }
        XCTAssertEqual(aggregates.reduce(0) { $0 + ($1["reads"] as? Int ?? 0) }, 2)
        XCTAssertEqual(aggregates.reduce(0) { $0 + ($1["shellReads"] as? Int ?? 0) }, 1)
        XCTAssertEqual(aggregates.reduce(0) { $0 + ($1["earlierReads"] as? Int ?? 0) }, 1)
        XCTAssertFalse(text.contains("private fixture message"))
        XCTAssertFalse(text.contains(log.path))
    }
}
