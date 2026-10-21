import Darwin
@testable import RotaCore
import SQLite3
import XCTest

final class ImportReliabilityTests: XCTestCase {
    func testDuplicateNamesKeepSourceIdentityAcrossImportAndReload() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let candidates = try source(in: folder)
        XCTAssertEqual(candidates.count, 3)
        XCTAssertEqual(Set(candidates.map(\.id)).count, 3)
        var routines: [Routine] = []
        for candidate in candidates {
            if let routine = RoutineImport.routineToImport(candidate, existing: routines) { routines.append(routine) }
        }
        XCTAssertEqual(routines.map(\.id), ["daily-review", "daily-review-2"])
        XCTAssertNotNil(candidates[2].unsupported)
        let store = RoutineStore(location: StorageLocation(root: folder, logs: folder))
        try store.save(routines)
        let restored = try store.load()
        XCTAssertTrue(candidates.prefix(2).allSatisfy { RoutineImport.isImported($0, in: restored) })
        XCTAssertTrue(candidates.prefix(2).allSatisfy {
            RoutineImport.routineToImport($0, existing: restored) == nil
        })
        var renamed = candidates[0]
        renamed.routine.name = "Renamed in source"
        renamed.routine.id = "renamed-in-source"
        XCTAssertTrue(RoutineImport.isImported(renamed, in: restored))
    }

    private func source(in folder: URL) throws -> [ImportCandidate] {
        let database = folder.appendingPathComponent("source.db")
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(database.path, &handle), SQLITE_OK)
        defer { sqlite3_close(handle) }
        let sql = """
        CREATE TABLE automations (id TEXT, name TEXT, prompt TEXT, status TEXT, next_run_at INTEGER,
            cwds TEXT, rrule TEXT, model TEXT, reasoning_effort TEXT, target_thread_id TEXT);
        INSERT INTO automations VALUES ('a', 'Daily review', 'Review.', 'ACTIVE', NULL,
            '["/tmp/fixture-a"]', 'FREQ=DAILY;BYHOUR=9;BYMINUTE=0', NULL, NULL, NULL);
        INSERT INTO automations VALUES ('b', 'Daily review', 'Review.', 'ACTIVE', NULL,
            '["/tmp/fixture-b"]', 'FREQ=DAILY;BYHOUR=9;BYMINUTE=0', NULL, NULL, NULL);
        INSERT INTO automations VALUES ('c', 'Multiple folders', 'Review.', 'ACTIVE', NULL,
            '["/tmp/fixture-a","/tmp/fixture-b"]', 'FREQ=DAILY;BYHOUR=9;BYMINUTE=0', NULL, NULL, NULL);
        """
        XCTAssertEqual(sqlite3_exec(handle, sql, nil, nil, nil), SQLITE_OK)
        return try CodexAutomationsImport.candidates(from: database)
    }
}

private final class RecordingTransport: MessageTransport, @unchecked Sendable {
    var onMessage: ((Data) -> Void)?
    var onClose: (() -> Void)?
    let received: @Sendable (Data) -> Void
    init(received: @escaping @Sendable (Data) -> Void) { self.received = received }
    func send(_ data: Data) { received(data) }
    func close() {}
}

final class CodexMessageReliabilityTests: XCTestCase {
    func testMessagesBeforeTurnStartAreSteeredOnceAndInOrder() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = folder.appendingPathComponent("run.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let replies = expectation(description: "both messages reached turn/steer")
        replies.expectedFulfillmentCount = 2
        let messages = NSLockProtectedMessages()
        let transport = RecordingTransport { data in
            guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
            XCTAssertEqual(value["method"] as? String, "turn/steer")
            let params = value["params"] as? [String: Any]
            XCTAssertEqual(params?["threadId"] as? String, "fixture-thread")
            XCTAssertEqual(params?["expectedTurnId"] as? String, "fixture-turn")
            let input = params?["input"] as? [[String: String]]
            messages.append(input?.first?["text"] ?? "")
            replies.fulfill()
        }
        let journal = RunJournal(output: try FileHandle(forWritingTo: log),
                                 events: RunEvents(session: { _ in }, finished: { _ in }))
        let spec = LaunchSpec(executable: "/bin/false", prompt: "Fixture", arguments: [],
                              workingDirectory: folder.path, environment: [:], mode: .codexDaemon,
                              timeout: nil, log: log, resume: "fixture-thread")
        let run = CodexDaemonRun(spec: spec, journal: journal, peer: JSONRPCPeer(transport: transport))
        run.send("first")
        run.send("second")
        run.turnStarted(.success(["turn": ["id": "fixture-turn"]]))
        wait(for: [replies], timeout: 5)
        XCTAssertEqual(messages.values, ["first", "second"])
        let text = try String(contentsOf: log, encoding: .utf8)
        XCTAssertEqual(text.components(separatedBy: "[you] first").count, 2)
        XCTAssertEqual(text.components(separatedBy: "[you] second").count, 2)
        journal.finish(.succeeded)
    }
}

private final class NSLockProtectedMessages: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    var values: [String] { lock.withLock { stored } }
    func append(_ value: String) { lock.withLock { stored.append(value) } }
}

final class ControlConnectionReliabilityTests: XCTestCase {
    func testAStalledReaderDoesNotBlockAndADisconnectDoesNotRaiseSIGPIPE() throws {
        var sockets: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &sockets), 0)
        let queue = DispatchQueue(label: "rota.test.connection")
        let connection = ControlConnection(descriptor: sockets[0], queue: queue)
        connection.reader.resume()
        defer { connection.cancel() }
        var enabled: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        XCTAssertEqual(getsockopt(sockets[0], SOL_SOCKET, SO_NOSIGPIPE, &enabled, &size), 0)
        guard enabled == 1 else {
            close(sockets[1])
            return XCTFail("Accepted sockets must suppress SIGPIPE before any write")
        }
        XCTAssertTrue(connection.enqueue(Data(repeating: 120, count: 8_000_000)))
        XCTAssertTrue(connection.flush())
        XCTAssertGreaterThan(connection.offset, 0)
        XCTAssertLessThan(connection.offset, connection.output.count, "the peer is not reading")
        close(sockets[1])
        XCTAssertFalse(connection.flush())
    }
}

final class CaptureReliabilityTests: XCTestCase {
    func testDeadlineKillsATermIgnoringHelperAndItsInheritedPipe() throws {
        for detachedChild in [false, true] {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let ready = folder.appendingPathComponent("ready")
            let body = "trap '' TERM; echo ready; echo $$ > \(shellQuote(ready.path)); exec /bin/sleep 300"
            let command = detachedChild ? "/bin/sh -c \(shellQuote(body)) & exit 0" : body
            var elapsed: TimeInterval = 0
            let result = ProcessLauncher.capture("/bin/sh", ["-c", command], in: folder.path,
                                                 timeout: 1, loginShell: false, clock: {
                // The child first proves its handler is installed. Advance an injected clock,
                // not the wall clock, through the deadline and kill escalation.
                if FileManager.default.fileExists(atPath: ready.path) { elapsed += 1 }
                return elapsed
            })
            XCTAssertTrue(FileManager.default.fileExists(atPath: ready.path), "the intended child ran")
            XCTAssertTrue(result.1.contains("ready"), "the actual stdout pipe was drained")
            XCTAssertEqual(result.0, -1, "a deadline is a failure even if the parent exited successfully")
        }
    }
}
