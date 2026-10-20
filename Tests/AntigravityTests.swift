@testable import RotaCore
import XCTest

final class AntigravityTests: XCTestCase {
    private func events(_ json: String, stream: inout AntigravityStream) -> [AntigravityStream.Event] {
        stream.events(Data(json.utf8))
    }

    func testStreamingTextIsNotRepeatedByResultAndResetsBetweenTurns() {
        var stream = AntigravityStream()
        XCTAssertEqual(events(#"""
        {"event":"step_update","step_update":{"step_type":"agent_response","state":"ACTIVE","text_delta":"hello"}}
        """#, stream: &stream), [.text("hello")])
        XCTAssertEqual(events(#"""
        {"event":"step_update","step_update":{"step_type":"agent_response","state":"DONE","text_delta":" world"}}
        """#, stream: &stream), [.text(" world")])
        XCTAssertEqual(events(#"""
        {"event":"result","result":{"status":"SUCCESS","response":"hello world","conversation_id":"a1"}}
        """#, stream: &stream), [.session("a1"), .result(.succeeded)])
        XCTAssertEqual(events(#"""
        {"event":"result","result":{"status":"SUCCESS","response":"next"}}
        """#, stream: &stream), [.text("next"), .result(.succeeded)])
    }

    func testSessionAndOnlyReportedConfiguration() {
        var stream = AntigravityStream()
        XCTAssertEqual(events(#"""
        {"event":"init","conversation_id":"a1","init":{"model":"model-a","effort":"high"}}
        """#, stream: &stream), [.session("a1"), .configuration(.init(model: "model-a", effort: "high"))])
        XCTAssertEqual(events(#"{"event":"init","init":{}}"#, stream: &stream), [.configuration(.init())])
    }

    func testStatusesNeverTurnIncompleteWorkIntoSuccess() {
        for status in ["ERROR", "INVALID", "WAITING", "RUNNING", "future", ""] {
            var stream = AntigravityStream()
            let data = Data("{\"event\":\"result\",\"result\":{\"status\":\"\(status)\",\"error\":\"reason\"}}".utf8)
            XCTAssertEqual(stream.events(data), [.item(.error, "reason"), .result(.failed(exitCode: 1))])
        }
        var stream = AntigravityStream()
        XCTAssertEqual(events(#"""
        {"event":"result","result":{"status":"CANCELED"}}
        """#, stream: &stream), [.result(.cancelled)])
        XCTAssertEqual(events(#"""
        {"event":"result","result":{"status":"INTERRUPTED"}}
        """#, stream: &stream), [.result(.interrupted)])
    }

    func testToolActivityOutputAndError() {
        var stream = AntigravityStream()
        let active = #"""
        {"event":"step_update","step_update":{"step_index":4,"step_type":"tool","state":"ACTIVE","tool_name":"run_command"}}
        """#
        XCTAssertEqual(events(active, stream: &stream), [.item(.tool, "run_command")])
        XCTAssertEqual(events(active, stream: &stream), [])
        XCTAssertEqual(events(#"""
        {"event":"step_update","step_update":{"step_index":4,"step_type":"tool","state":"DONE","tool_info":{"output":"hello","error":{"message":"failed"}}}}
        """#, stream: &stream), [.item(.output, "hello"), .item(.error, "failed")])
    }

    func testDiscoveryAndAccessUseTheAgyContracts() throws {
        XCTAssertEqual(Harness.antigravity.commandName, "agy")
        XCTAssertEqual(Harness.antigravity.defaultExecutable(home: URL(fileURLWithPath: "/Users/example")),
                       "/Users/example/.local/bin/agy")
        XCTAssertTrue(Harness.antigravity.takesMessages)
        XCTAssertNil(Harness.antigravity.terminal(session: "a1", running: false))
        XCTAssertEqual(AgentAccess.addArguments(.antigravity, command: "/app/rota"),
                       ["mcp", "add", "rota", "/app/rota", "mcp"])
        XCTAssertEqual(AgentAccess.removeArguments(.antigravity), ["mcp", "remove", "rota"])
        XCTAssertTrue(AgentAccess.antigravityLists("rota",
            in: "NAME TYPE STATUS COMMAND/URL\nrota stdio enabled /r mcp"))
        XCTAssertFalse(AgentAccess.antigravityLists("rota", in: "rota stdio disabled /r mcp"))
        XCTAssertFalse(AgentAccess.antigravityLists("rota", in: "rotary stdio enabled /r mcp"))
        XCTAssertFalse(AgentAccess.antigravityLists("rota", in: "Error: rota is unavailable"))
        let message = try JSONSerialization.jsonObject(with: AntigravityRun.userMessage("hello\n\"world\""))
            as? [String: Any]
        XCTAssertEqual(message?["event"] as? String, "user")
        XCTAssertEqual((message?["message"] as? [String: Any])?["content"] as? String, "hello\n\"world\"")
    }

    func testMessageWaitsForCurrentResultAndRunWaitsForItsAnswer() throws {
        try checkQueuedTurn(completes: true)
    }

    func testMissingFollowUpResultCannotReuseTheFirstTurnsSuccess() throws {
        try checkQueuedTurn(completes: false)
    }

    private func checkQueuedTurn(completes: Bool) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("rota-queue-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let ready = folder.appendingPathComponent("ready")
        XCTAssertEqual(mkfifo(ready.path, 0o600), 0)
        let descriptor = open(ready.path, O_RDWR)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        let signal = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? signal.close() }
        let peer = folder.appendingPathComponent("peer")
        let second = completes
            ? #"{"event":"result","result":{"status":"SUCCESS","response":"second answer"}}"# : ""
        let script = """
        #!/bin/zsh
        IFS= read -r message
        printf '%s\\n' '{"event":"init","conversation_id":"a1","init":{}}'
        IFS= read -r signal < ready
        printf '%s\\n' '{"event":"result","result":{"status":"SUCCESS","response":"first answer"}}'
        IFS= read -r message || exit 8
        [[ "$message" == *'follow-up'* ]] || exit 9
        printf '%s' '\(second)'
        """
        try script.write(to: peer, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: peer.path)
        let log = folder.appendingPathComponent("run.log")
        let spec = LaunchSpec(executable: peer.path, prompt: "first", arguments: [], workingDirectory: folder.path,
                              environment: [:], mode: .antigravityStream, timeout: 10, log: log)
        let finished = expectation(description: "both turns finished")
        var control: RunControl?
        control = try ProcessLauncher().launch(spec, events: RunEvents(session: { _ in
            control?.send("follow-up")
            // The FIFO releases the peer only after send has entered the runner's
            // serial queue. No sleep or timing assumption decides which turn wins.
            do {
                try signal.write(contentsOf: Data("ready\n".utf8))
            } catch { XCTFail(error.localizedDescription) }
        }, finished: { outcome in
            XCTAssertEqual(outcome, completes ? .succeeded : .interrupted)
            finished.fulfill()
        }))
        wait(for: [finished], timeout: 15)
        withExtendedLifetime(control) {}
        let text = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(text.contains("[you] follow-up"), text)
        XCTAssertTrue(text.contains("first answer"), text)
        XCTAssertEqual(text.contains("second answer"), completes, text)
        if !completes { XCTAssertTrue(text.contains("without a result"), text) }
    }

    func testStopEndsTheOwnedPeerWithoutAResult() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("rota-stop-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let peer = folder.appendingPathComponent("peer")
        let script = """
        #!/bin/zsh
        IFS= read -r message
        printf '%s\\n' '{"event":"init","conversation_id":"a1","init":{}}'
        IFS= read -r message
        """
        try script.write(to: peer, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: peer.path)
        let spec = LaunchSpec(executable: peer.path, prompt: "first", arguments: [], workingDirectory: folder.path,
                              environment: [:], mode: .antigravityStream, timeout: 10,
                              log: folder.appendingPathComponent("run.log"))
        let stopped = expectation(description: "owned peer stopped")
        var control: RunControl?
        control = try ProcessLauncher().launch(spec, events: RunEvents(session: { _ in
            control?.stop()
        }, finished: { outcome in
            XCTAssertEqual(outcome, .cancelled)
            stopped.fulfill()
        }))
        wait(for: [stopped], timeout: 15)
        withExtendedLifetime(control) {}
    }

    /// Exercises ProcessLauncher, stdin framing, byte draining and native resume flags.
    /// The peer is a local shell script, never an agent or a model request.
    func testRunnerUsesStdinAndDrainsFinalResultBeforeExit() throws {
        try checkRunner(status: "SUCCESS", exit: 0, expected: .succeeded)
        try checkRunner(status: "ERROR", exit: 0, expected: .failed(exitCode: 1))
        try checkRunner(status: "SUCCESS", exit: 7, expected: .failed(exitCode: 7))
        try checkRunner(status: nil, exit: 0, expected: .interrupted)
    }

    private func checkRunner(status: String?, exit: Int, expected: RunOutcome) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("rota-peer-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let peer = folder.appendingPathComponent("peer")
        let result = status.map {
            "{\"event\":\"result\",\"result\":{\"status\":\"\($0)\",\"response\":\"answer\"}}"
        } ?? ""
        let script = """
        #!/bin/zsh
        [[ "$*" == *'--conversation a1'* ]] || exit 9
        [[ "$*" != *'private prompt'* ]] || exit 8
        [[ "$*" == *'--model model-a --effort high'* ]] || exit 10
        IFS= read -r message
        [[ "$message" == '{"event":"user","message":{"content":"private prompt"}}' || "$message" == '{"message":{"content":"private prompt"},"event":"user"}' ]] || exit 6
        printf '%s\\n' '{"event":"init","conversation_id":"a1","init":{"model":"model-a"}}'
        printf '%s' '\(result)'
        exit \(exit)
        """
        try script.write(to: peer, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: peer.path)
        let log = folder.appendingPathComponent("run.log")
        let spec = LaunchSpec(executable: peer.path, prompt: "private prompt", arguments: [],
                              workingDirectory: folder.path, environment: [:], mode: .antigravityStream,
                              timeout: 10, log: log, resume: "a1", model: "model-a", effort: "high")
        let finished = expectation(description: "peer finished")
        var sessions: [String] = []
        let control = try ProcessLauncher().launch(spec, events: RunEvents(session: { sessions.append($0) },
            finished: { outcome in
                XCTAssertEqual(outcome, expected)
                finished.fulfill()
            }))
        wait(for: [finished], timeout: 15)
        withExtendedLifetime(control) {}
        XCTAssertEqual(sessions, ["a1"])
        let text = try String(contentsOf: log, encoding: .utf8)
        if status != nil { XCTAssertTrue(text.contains("answer"), text) }
    }
}
