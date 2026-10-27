@testable import RotaCore
import XCTest
import Darwin

final class TerminalRunTests: XCTestCase {
    func testStopClosesOwnedScreenExactlyOnce() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let native = folder.appendingPathComponent("native.jsonl")
        try Data().write(to: native)
        let pidFile = folder.appendingPathComponent("native.pid")
        let event = #"{"type":"event_msg","payload":{"type":"task_started"}}"#
        let producer = "trap '' HUP INT; print -r -- $$ > \(shellQuote(pidFile.path)); "
            + "print -r -- \(shellQuote(event)) >> \(shellQuote(native.path)); "
            + "while true; do read -r reply || /bin/sleep 1; done"
        var spec = LaunchSpec(executable: "/bin/zsh", prompt: "", arguments: ["-c", producer],
            workingDirectory: folder.path, environment: [:], mode: .terminal(.codex), timeout: nil,
            log: folder.appendingPathComponent("run.log"), resume: "test")
        spec.terminalTranscript = native
        let done = expectation(description: "owned terminal stopped")
        done.assertForOverFulfill = true
        nonisolated(unsafe) var control: RunControl?
        control = try ProcessLauncher().launch(spec, events: .init(session: { _ in }, finished: { result in
            XCTAssertEqual(result, .cancelled)
            done.fulfill()
        }, terminalState: { state in
            if state == .working { control?.stop(); control?.stop() }
        }))
        let name = try XCTUnwrap(control?.attachCommand?.last)
        wait(for: [done], timeout: 15)
        XCTAssertFalse(ScreenRun.alive(name))
        let pid = try XCTUnwrap(Int32(String(contentsOf: pidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
        XCTAssertEqual(kill(pid, 0), -1, "A TUI that ignores HUP must not outlive Stop")
        XCTAssertEqual(errno, ESRCH)
    }

    func testOwnedTerminalAppendsNativeMessagesAndReportsExit() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let native = folder.appendingPathComponent("native.jsonl")
        try Data("old history\n".utf8).write(to: native)
        let log = folder.appendingPathComponent("run.log")
        var spec = LaunchSpec(executable: "/bin/zsh", prompt: "Not submitted to the CLI", arguments: [],
                              workingDirectory: folder.path,
                              environment: [:], mode: .terminal(.codex), timeout: nil, log: log, resume: "test")
        spec.terminalTranscript = native
        // A producer writes the verified native wire shape. No agent or user data is involved.
        let message: [String: Any] = ["type": "response_item", "payload": ["type": "message", "role": "assistant",
            "content": [["type": "output_text", "text": "Native terminal answer"]]]]
        let user: [String: Any] = ["type": "event_msg", "payload": ["type": "item_completed", "item": [
            "type": "UserMessage", "content": [["type": "text", "text": "Typed in Terminal"]]]]]
        let data = try JSONSerialization.data(withJSONObject: message)
        let userData = try JSONSerialization.data(withJSONObject: user)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        let userText = try XCTUnwrap(String(data: userData, encoding: .utf8))
        spec.arguments = ["-c", "print -r -- \(shellQuote(userText)) >> \(shellQuote(native.path)); "
            + "print -r -- \(shellQuote(text)) >> \(shellQuote(native.path)); exit 7"]
        let done = expectation(description: "native process ended")
        nonisolated(unsafe) var outcome: RunOutcome?
        nonisolated(unsafe) var inputSeen = false
        let control = try ProcessLauncher().launch(spec, events: .init(session: { _ in XCTFail("Session changed") },
            finished: { outcome = $0; done.fulfill() }, terminalInput: { inputSeen = true }))
        XCTAssertEqual(control.attachCommand?.prefix(2), ["/usr/bin/screen", "-x"])
        wait(for: [done], timeout: 15)
        XCTAssertEqual(outcome, .failed(exitCode: 7))
        let readable = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(readable.contains("Native terminal answer"))
        XCTAssertFalse(readable.contains("old history"))
        XCTAssertTrue(readable.contains("[you] Typed in Terminal"))
        XCTAssertFalse(readable.contains("Not submitted to the CLI"), "Opening must not invent a user message")
        XCTAssertTrue(inputSeen, "A real native user event must acknowledge the pending reply")
    }
}
