@testable import RotaCore
import XCTest

final class OwnedProcessTests: XCTestCase {
    /// `proc_listchildpids` returns a count of PIDs, not bytes: read as bytes, a process with
    /// fewer than four children had none, and Stop left a session's agent running (2026-11-26).
    func testDescendantsReachEveryLevel() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "/bin/sh -c 'sleep 30 & wait' & wait"]
        try process.run()
        defer { process.terminate() }
        let root = try XCTUnwrap(OwnedProcess(pid: process.processIdentifier))
        var found: [OwnedProcess] = []
        for _ in 0..<50 where found.count < 2 {
            usleep(20_000)
            found = root.descendants()
        }
        XCTAssertEqual(found.count, 2, "the inner shell and its sleep")
        for child in found { child.signal(SIGKILL) }
    }
}

final class ScreenTerminationTests: XCTestCase {
    /// Two screens under one name refuse `screen -S name` commands; `terminate` ends both with their processes.
    func testTerminateEndsEveryScreenUnderTheName() throws {
        let name = "rota-test-" + UUID().uuidString.prefix(8).lowercased()
        let script = FileManager.default.temporaryDirectory.appendingPathComponent(name + ".zsh")
        try "sleep 60".write(to: script, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: script) }
        for _ in 0..<2 {
            try ScreenRun.launchDetached(name, script: script, in: NSTemporaryDirectory(), environment: [:],
                                         loginShell: false)
        }
        defer { ScreenRun.terminate(name) }
        let roots = ScreenRun.pids(name, in: ScreenRun.list(name)).compactMap(OwnedProcess.init(pid:))
        XCTAssertEqual(roots.count, 2)
        var sleeps: [OwnedProcess] = []
        for _ in 0..<50 where sleeps.count < 4 {
            usleep(20_000)
            sleeps = roots.flatMap { $0.descendants() }
        }
        XCTAssertEqual(sleeps.count, 4, "zsh and sleep under each screen, past the root-owned login")
        XCTAssertNotEqual(ScreenRun.command(name, ["-X", "select", "0"]), 0, "screen refuses an ambiguous name")

        XCTAssertEqual(ScreenRun.terminate(name), 2)
        XCTAssertFalse(ScreenRun.alive(name))
        XCTAssertFalse((roots + sleeps).contains(where: \.exists))
    }
}
