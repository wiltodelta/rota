@testable import RotaCore
import XCTest
import Darwin

final class PTYProcessTests: XCTestCase {
    func testLongInputFromTheReadCallbackIsQueuedUntilTheChildReads() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let gate = folder.appendingPathComponent("read-now")
        let program = """
            import os, sys, time, tty
            tty.setraw(0)
            print('READY', flush=True)
            while not os.path.exists(sys.argv[1]):
                time.sleep(0.001)
            value = sys.stdin.buffer.read(1000000)
            print('COMPLETE' if value == b'x' * 1000000 else 'CORRUPTED', flush=True)
            """
        let queue = DispatchQueue(label: "rota.test.long-pty-input")
        let process = try PTYProcess(executable: "/usr/bin/python3", arguments: ["-c", program, gate.path],
                                    directory: folder.path,
                                    environment: ProcessLauncher.baseEnvironment(), queue: queue)
        defer { queue.sync { process.forceKill() } }
        let ended = expectation(description: "the child received the complete input")
        nonisolated(unsafe) var output = Data()
        nonisolated(unsafe) var sent = false
        process.output = { data in
            output.append(data)
            if !sent && lossyUTF8(output).contains("READY") {
                sent = true
                XCTAssertTrue(process.write(Data(repeating: 120, count: 1_000_000)))
                // This runs only when input processing did not block the terminal queue.
                try? Data().write(to: gate)
            }
        }
        process.exited = { status in XCTAssertEqual(status, 0); ended.fulfill() }
        process.start()
        wait(for: [ended], timeout: 5)
        XCTAssertTrue(sent)
        XCTAssertTrue(lossyUTF8(output).contains("COMPLETE"), lossyUTF8(output))
    }

    func testControllingTerminalUnicodeInputAndRealExitStatus() throws {
        let queue = DispatchQueue(label: "rota.test.pty")
        let ended = expectation(description: "child exited")
        let process = try PTYProcess(executable: "/bin/zsh", arguments: ["-c",
            "stty -echo; stty -a </dev/tty >/dev/null || exit 99; printf 'READY\\n'; IFS= read -r line; "
                + "printf 'RECEIVED:%s\\n' \"$line\"; exit 7"],
            directory: NSTemporaryDirectory(), environment: ProcessLauncher.baseEnvironment(), queue: queue)
        nonisolated(unsafe) var bytes = Data()
        nonisolated(unsafe) var sent = false
        process.output = { data in
            bytes.append(data)
            if !sent && lossyUTF8(bytes).contains("READY") {
                sent = true
                XCTAssertTrue(process.write(Data("Привет 𠀀\r".utf8)))
            }
        }
        process.exited = { status in XCTAssertEqual(status, 7); ended.fulfill() }
        process.start()
        wait(for: [ended], timeout: 10)
        XCTAssertTrue(sent)
        XCTAssertTrue(lossyUTF8(bytes).contains("RECEIVED:Привет 𠀀"), lossyUTF8(bytes))
    }

    func testAttachmentForwardsInputAndResizesTheControllingTerminal() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pty-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let queue = DispatchQueue(label: "rota.test.attachment")
        let process = try PTYProcess(executable: "/bin/zsh", arguments: ["-c",
            "stty -echo; IFS= read -r line; printf 'RECEIVED:%s\\n' \"$line\"; stty size; exit 0"],
            directory: folder.path, environment: ProcessLauncher.baseEnvironment(), queue: queue)
        let terminal = try PTYTerminal(process: process, queue: queue, folder: folder)
        defer { queue.sync { terminal.close(); process.forceKill() } }
        let ended = expectation(description: "attached child exited")
        process.output = { terminal.publish($0) }
        process.exited = { status in XCTAssertEqual(status, 0); terminal.close(); ended.fulfill() }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { Darwin.close(fd) }
        var address = try ControlServer.address(terminal.path)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(connected, 0)
        let request: [String: Any] = ["rows": 42, "columns": 88, "input": Data("hello\r".utf8).base64EncodedString()]
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
        try handle.write(contentsOf: JSONSerialization.data(withJSONObject: request) + Data([10]))
        let received = expectation(description: "terminal output received")
        nonisolated(unsafe) var output = Data()
        DispatchQueue.global().async {
            output = handle.readDataToEndOfFile()
            received.fulfill()
        }
        queue.sync { process.start() }
        wait(for: [ended, received], timeout: 10)
        XCTAssertTrue(lossyUTF8(output).contains("RECEIVED:hello"), lossyUTF8(output))
        XCTAssertTrue(lossyUTF8(output).contains("42 88"), lossyUTF8(output))
    }

    func testMissingExecutableFailsBeforeReturningAProcess() {
        XCTAssertThrowsError(try PTYProcess(executable: "/missing/rota-test", arguments: [],
            directory: NSTemporaryDirectory(), environment: [:], queue: DispatchQueue(label: "rota.test.pty")))
    }
}
