@testable import RotaCore
import XCTest
import Darwin

final class TerminalRunTests: XCTestCase {
    func testGrokTerminalKeepsAdjacentNativeMessagesSeparate() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let native = folder.appendingPathComponent("updates.jsonl")
        try Data().write(to: native)
        let texts = ["First answer.", "Second answer."]
        let commands = try texts.enumerated().map { index, text in
            let row: [String: Any] = ["method": "session/update", "params": ["sessionId": "session",
                "_meta": ["promptId": "prompt", "streamStartMs": index + 1],
                "update": ["sessionUpdate": "agent_message_chunk", "content": ["type": "text", "text": text]]]]
            let json = try XCTUnwrap(String(data: JSONSerialization.data(withJSONObject: row), encoding: .utf8))
            return "print -r -- \(shellQuote(json)) >> \(shellQuote(native.path))"
        }
        let log = folder.appendingPathComponent("session.log")
        var spec = LaunchSpec(executable: "/bin/zsh", prompt: "", arguments: ["-c", commands.joined(separator: "; ")],
            workingDirectory: folder.path, environment: [:], mode: .terminal(.grok), timeout: nil, log: log)
        spec.terminalTranscript = native
        let done = expectation(description: "synthetic native terminal exited")
        let control = try ProcessLauncher().launch(spec, events: .init(session: { _ in }, finished: {
            XCTAssertEqual($0, .succeeded)
            done.fulfill()
        }))
        defer { control.stop() }
        wait(for: [done], timeout: 15)
        var reader = TranscriptReader()
        XCTAssertEqual(reader.read(log: log, finished: true).items.filter { $0.kind == .agent }.map(\.text), texts)
    }

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

    func testScreenAttachmentComesFromTheMatchingSessionOnly() {
        let list = "There are screens on:\n\t63754.rota-terminal-a\t(Attached)\n"
            + "\t811.rota-terminal-b\t(Detached)\n2 Sockets in /tmp/.screen.\n"
        XCTAssertTrue(ScreenRun.attached("rota-terminal-a", in: list))
        XCTAssertFalse(ScreenRun.attached("rota-terminal-b", in: list))
        XCTAssertFalse(ScreenRun.attached("rota-terminal-c", in: list))
    }

    /// Closing the terminal window returns the session to Rota, but only once the CLI waits for input.
    func testClosedTerminalReturnsToRotaAfterTheTurnEnds() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let native = folder.appendingPathComponent("native.jsonl")
        try Data().write(to: native)
        let turnEnds = folder.appendingPathComponent("turn-ends")
        let started = #"{"type":"event_msg","payload":{"type":"task_started"}}"#
        let complete = #"{"type":"event_msg","payload":{"type":"task_complete"}}"#
        let producer = "trap '' HUP INT; print -r -- \(shellQuote(started)) >> \(shellQuote(native.path)); "
            + "while [[ ! -e \(shellQuote(turnEnds.path)) ]]; do /bin/sleep 0.2; done; "
            + "print -r -- \(shellQuote(complete)) >> \(shellQuote(native.path)); "
            + "while true; do /bin/sleep 1; done"
        let log = folder.appendingPathComponent("run.log")
        var spec = LaunchSpec(executable: "/bin/zsh", prompt: "", arguments: ["-c", producer],
            workingDirectory: folder.path, environment: [:], mode: .terminal(.codex), timeout: nil,
            log: log, resume: "test")
        spec.terminalTranscript = native
        let done = expectation(description: "returned to Rota")
        nonisolated(unsafe) var outcome: RunOutcome?
        let control = try ProcessLauncher().launch(spec, events: .init(session: { _ in },
            finished: { outcome = $0; done.fulfill() }))
        let name = try XCTUnwrap(control.attachCommand?.last)
        defer { ScreenRun.quit(name) }

        // A real terminal client: `script` gives `screen -x` a PTY, as a terminal window does.
        let client = Process()
        client.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        client.arguments = ["-q", "/dev/null", ScreenRun.screen, "-x", name]
        let input = Pipe()
        client.standardInput = input
        client.standardOutput = FileHandle.nullDevice
        client.environment = ["TERM": "xterm-256color", "LANG": "en_US.UTF-8"]
        try client.run()
        let deadline = Date().addingTimeInterval(10)
        var attached = false
        while !attached, Date() < deadline {
            attached = ScreenRun.attached(name, in: ScreenRun.list(name))
            if !attached { Thread.sleep(forTimeInterval: 0.2) }
        }
        XCTAssertTrue(attached)
        Thread.sleep(forTimeInterval: 1.5)
        client.terminate()
        client.waitUntilExit()

        Thread.sleep(forTimeInterval: 4)
        XCTAssertNil(outcome, "A closed window must not end a turn in progress")
        XCTAssertTrue(ScreenRun.alive(name))
        try Data().write(to: turnEnds)
        wait(for: [done], timeout: 15)
        XCTAssertEqual(outcome, .succeeded)
        XCTAssertFalse(ScreenRun.alive(name))
        XCTAssertTrue(try String(contentsOf: log, encoding: .utf8).contains("Returned to Rota"))
    }
}
