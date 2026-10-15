@testable import RotaCore
import XCTest

final class ClaudeStreamProtocolTests: XCTestCase {
    func testStopRemainsAvailableWhenTheProviderStopsReadingMessages() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let pidFile = folder.appendingPathComponent("pid")
        let program = folder.appendingPathComponent("provider.py")
        let script = """
            #!/usr/bin/python3
            import json, os, signal, sys
            json.loads(sys.stdin.readline())
            with open('\(pidFile.path)', 'w') as output:
                output.write(str(os.getpid()))
            print(json.dumps({'type': 'system', 'subtype': 'init', 'session_id': 'fixture-stream'}), flush=True)
            while True:
                signal.pause()
            """
        try script.write(to: program, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: program.path)
        let spec = LaunchSpec(executable: program.path, prompt: "Read the fixture", arguments: [],
                              workingDirectory: folder.path, environment: [:], mode: .claudeStream,
                              timeout: nil, log: folder.appendingPathComponent("session.log"))
        let ended = expectation(description: "Stop reaches the blocked provider")
        nonisolated(unsafe) var outcome: RunOutcome?
        nonisolated(unsafe) var control: RunControl?
        control = try ProcessLauncher().launch(spec, events: RunEvents(session: { id in
            XCTAssertEqual(id, "fixture-stream")
            control?.send(String(repeating: "x", count: 1_000_000))
            control?.stop()
        }, finished: {
            outcome = $0
            ended.fulfill()
        }))
        defer {
            if outcome == nil, let text = try? String(contentsOf: pidFile, encoding: .utf8), let pid = Int32(text) {
                _ = kill(pid, SIGKILL)
            }
        }
        wait(for: [ended], timeout: 2)
        XCTAssertEqual(outcome, .cancelled)
    }
}
