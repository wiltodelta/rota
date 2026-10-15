@testable import RotaCore
import XCTest
import os

final class ProcessCaptureTests: XCTestCase {
    func testAnExitedCommandDoesNotWaitForADescendantHoldingStdout() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let childFile = folder.appendingPathComponent("child")
        let script = """
            import os, signal, sys
            child = os.fork()
            if child == 0:
                signal.pause()
                os._exit(0)
            with open(sys.argv[1], 'w') as output:
                output.write(str(child))
            print('parent finished', flush=True)
            """
        let result = OSAllocatedUnfairLock<(Int32, String)?>(initialState: nil)
        let completed = expectation(description: "capture follows the direct command's exit")
        let cleaned = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            let value = ProcessLauncher.capture("/usr/bin/python3", ["-c", script, childFile.path],
                                                in: folder.path, loginShell: false)
            result.withLock { $0 = value }
            completed.fulfill()
            cleaned.signal()
        }
        defer {
            if let text = try? String(contentsOf: childFile, encoding: .utf8), let pid = Int32(text) {
                _ = kill(pid, SIGKILL)
            }
            _ = cleaned.wait(timeout: .now() + 5)
        }
        wait(for: [completed], timeout: 2)
        let captured = try XCTUnwrap(result.withLock { $0 })
        let child = try XCTUnwrap(Int32(String(contentsOf: childFile, encoding: .utf8)))
        XCTAssertEqual(kill(child, 0), 0, "the descendant still holds its inherited stdout")
        XCTAssertEqual(captured.0, 0)
        XCTAssertTrue(captured.1.contains("parent finished"))
    }

    func testDeadlineEndsACommandThatIgnoresTermination() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let ready = folder.appendingPathComponent("ready")
        let script = """
            import os, signal, sys
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            print('fixture ready', flush=True)
            with open(sys.argv[1] + '.tmp', 'w') as output:
                output.write(str(os.getpid()))
            os.rename(sys.argv[1] + '.tmp', sys.argv[1])
            while True:
                signal.pause()
            """
        let scheduled = OSAllocatedUnfairLock<UncheckedSendable<DispatchWorkItem>?>(initialState: nil)
        let result = OSAllocatedUnfairLock<(Int32, String)?>(initialState: nil)
        let completed = expectation(description: "capture completes after its injected deadline")
        let cleaned = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            let captured = ProcessLauncher.capture("/usr/bin/python3", ["-c", script, ready.path],
                in: folder.path, timeout: 1_000, loginShell: false, timeoutSchedule: { seconds, work in
                    XCTAssertEqual(seconds, 1_000)
                    let box = UncheckedSendable(work)
                    scheduled.withLock { $0 = box }
                })
            result.withLock { $0 = captured }
            completed.fulfill()
            cleaned.signal()
        }
        // Wait only for fixture readiness; the timeout itself is advanced by hand.
        let guardDeadline = Date().addingTimeInterval(5)
        while !FileManager.default.fileExists(atPath: ready.path), Date() < guardDeadline {
            Thread.sleep(forTimeInterval: 0.01)
        }
        let pid = try XCTUnwrap(Int32(String(contentsOf: ready, encoding: .utf8)))
        XCTAssertEqual(kill(pid, 0), 0, "the SIGTERM-ignoring fixture is alive")
        defer {
            if result.withLock({ $0 == nil }) { _ = kill(pid, SIGKILL) }
            _ = cleaned.wait(timeout: .now() + 5)
        }
        let deadline = try XCTUnwrap(scheduled.withLock { $0 })
        deadline.value.perform()
        wait(for: [completed], timeout: 2)
        let captured = try XCTUnwrap(result.withLock { $0 })
        XCTAssertEqual(captured.0, SIGKILL)
        XCTAssertTrue(captured.1.contains("fixture ready"))
    }
}
