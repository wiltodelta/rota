@testable import RotaCore
import XCTest

/// An explicitly supplied disposable native session, never a real routine.
final class LiveTerminalTests: XCTestCase {
    func testNativeTerminalContinuation() throws {
        let environment = ProcessInfo.processInfo.environment
        try XCTSkipUnless(environment["ROTA_TERMINAL_LIVE"] == "1", "set ROTA_TERMINAL_LIVE=1 to run")
        let harness = try XCTUnwrap(environment["ROTA_TERMINAL_HARNESS"].flatMap(Harness.init(rawValue:)))
        let session = try XCTUnwrap(environment["ROTA_TERMINAL_SESSION"])
        let directory = try XCTUnwrap(environment["ROTA_TERMINAL_DIRECTORY"])
        let folder = URL(fileURLWithPath: directory)
        if environment["ROTA_TERMINAL_APP_ONLY"] == "1" {
            return try continueInApp(harness, session: session,
                directory: environment["ROTA_TERMINAL_CWD"] ?? directory, folder: folder)
        }
        let source = try XCTUnwrap(NativeTranscript.locate(harness, session: session))
        let command = try XCTUnwrap(harness.terminal(session: session, running: false))
        var spec = LaunchSpec(executable: harness.defaultExecutable(), prompt: "", arguments: command.arguments,
            workingDirectory: environment["ROTA_TERMINAL_CWD"] ?? directory, environment: [:],
            mode: .terminal(harness), timeout: nil,
            log: folder.appendingPathComponent("\(harness.rawValue)-terminal-\(UUID().uuidString).log"),
            resume: session)
        spec.terminalTranscript = source
        _ = try TranscriptJournal(log: spec.log, resuming: false, logSize: 0)
        let waiting = expectation(description: "native turn completed")
        let ended = expectation(description: "terminal stopped")
        nonisolated(unsafe) var working = false
        nonisolated(unsafe) var completed = false
        let control = try ProcessLauncher().launch(spec, events: .init(session: { _ in XCTFail("Session changed") },
            finished: { _ in
                if !completed { completed = true; waiting.fulfill() }
                ended.fulfill()
            }, terminalState: { state in
                if state == .working { working = true }
                if state == .waiting, working, !completed { completed = true; waiting.fulfill() }
            }))
        let name = try XCTUnwrap(control.attachCommand?.last)
        defer { control.stop() }
        let (attachment, output) = try attach(name, folder: folder, harness: harness)
        defer { try? output.close(); if attachment.isRunning { attachment.terminate() } }
        wait(for: [waiting], timeout: 90)
        let text = try String(contentsOf: spec.log, encoding: .utf8)
        var reader = TranscriptReader()
        let snapshot = reader.read(log: spec.log)
        XCTAssertTrue(snapshot.structured)
        XCTAssertNil(snapshot.problem)
        XCTAssertTrue(snapshot.items.contains { $0.kind == .agent && $0.text == "TERMINAL_SYNC_OK" }, text)
        XCTAssertTrue(snapshot.items.contains { $0.kind == .user && $0.text.contains("TERMINAL_SYNC_OK") }, text)
        XCTAssertTrue(working)
        _ = ProcessLauncher.capture("/usr/bin/screen", ["-S", name, "-X", "hardcopy",
            folder.appendingPathComponent("\(harness.rawValue)-terminal.txt").path], in: directory, loginShell: false)
        control.stop()
        wait(for: [ended], timeout: 15)
        try continueInApp(harness, session: session, directory: spec.workingDirectory, folder: folder)
    }
    private func continueInApp(_ harness: Harness, session: String, directory: String, folder: URL) throws {
        let spec = LaunchSpec(executable: harness.defaultExecutable(),
            prompt: "Reply exactly APP_SYNC_OK. Do not use tools.",
            arguments: harness.arguments(settings: ClaudeUserSettings(), resume: session),
            workingDirectory: directory, environment: [:], mode: harness.launchMode, timeout: 90,
            log: folder.appendingPathComponent("app-\(UUID().uuidString).log"), resume: session)
        let done = expectation(description: "continued from app")
        nonisolated(unsafe) var outcome: RunOutcome?
        let control = try ProcessLauncher().launch(spec, events: .init(session: { id in
            XCTAssertEqual(id, session)
        }, finished: { result in outcome = result; done.fulfill() }))
        defer { control.stop() }
        wait(for: [done], timeout: 120)
        let text = try String(contentsOf: spec.log, encoding: .utf8)
        XCTAssertEqual(outcome, .succeeded, text)
        XCTAssertTrue(text.split(separator: "\n").contains("APP_SYNC_OK"), text)
    }

    private func attach(_ name: String, folder: URL, harness: Harness) throws -> (Process, FileHandle) {
        // script supplies a real PTY, as a terminal app does, without touching the desktop.
        let attach = Process()
        attach.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        attach.arguments = ["-q", "/dev/null", "/usr/bin/screen", "-x", name]
        attach.environment = ProcessLauncher.baseEnvironment().merging(["TERM": "xterm-256color"]) { $1 }
        let input = Pipe()
        attach.standardInput = input
        let capture = folder.appendingPathComponent("\(harness.rawValue)-terminal-pty.txt")
        FileManager.default.createFile(atPath: capture.path, contents: nil)
        let output = try FileHandle(forWritingTo: capture)
        attach.standardOutput = output
        attach.standardError = output
        try attach.run()
        // Native TUIs need to draw before accepting the test's bracketed paste.
        DispatchQueue.global().asyncAfter(deadline: .now() + 8) {
            let prompt = "\u{1B}[200~Reply exactly TERMINAL_SYNC_OK. Do not use tools.\u{1B}[201~"
            input.fileHandleForWriting.write(Data(prompt.utf8))
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                input.fileHandleForWriting.write(Data("\r".utf8))
            }
        }
        return (attach, output)
    }
}
