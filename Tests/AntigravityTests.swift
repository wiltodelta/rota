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
        """#, stream: &stream), [.textStarted(nil), .text("hello")])
        XCTAssertEqual(events(#"""
        {"event":"step_update","step_update":{"step_type":"agent_response","state":"DONE","text_delta":" world"}}
        """#, stream: &stream), [.text(" world"), .textEnded(nil)])
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

    /// Shapes observed from agy 1.4.12: a print timeout reports SUCCESS, an interruption ERROR.
    func testFinishedReasonOutranksStatusAndKeepsThePartialAnswer() {
        let cases: [(String, [AntigravityStream.Event])] = [
            (#"{"status":"SUCCESS","response":"1 one","finished_reason":"print_timeout"}"#,
             [.text("1 one"), .item(.error, "Antigravity's print time limit expired. The answer is partial."),
              .result(.timedOut)]),
            (#"{"status":"ERROR","response":"1 one","error":"interrupted","finished_reason":"interrupted"}"#,
             [.text("1 one"), .item(.error, "Antigravity interrupted the turn. The answer is partial."),
              .result(.interrupted)]),
            (#"{"status":"ERROR","response":"","error":"invalid model","finished_reason":"error"}"#,
             [.item(.error, "invalid model"), .result(.failed(exitCode: 1))]),
            (#"{"status":"SUCCESS","response":"1 one","finished_reason":"future"}"#,
             [.text("1 one"), .item(.error, "Antigravity ended the turn early (future). The answer may be incomplete."),
              .result(.failed(exitCode: 1))]),
            (#"{"status":"SUCCESS","response":"done","finished_reason":""}"#, [.text("done"), .result(.succeeded)]),
        ]
        for (result, expected) in cases {
            var stream = AntigravityStream()
            XCTAssertEqual(events(#"{"event":"result","result":"# + result + "}", stream: &stream), expected, result)
        }
    }

    func testToolActivityOutputAndError() {
        var stream = AntigravityStream()
        let active = #"""
        {"event":"step_update","step_update":{"step_index":4,"step_type":"tool","state":"ACTIVE","tool_name":"run_command"}}
        """#
        XCTAssertEqual(events(active, stream: &stream), [.item(.tool, "run_command", step: 4)])
        XCTAssertEqual(events(active, stream: &stream), [])
        XCTAssertEqual(events(#"""
        {"event":"step_update","step_update":{"step_index":4,"step_type":"tool","state":"DONE","tool_info":{"output":"hello","error":{"message":"failed"}}}}
        """#, stream: &stream), [.item(.output, "hello", step: 4), .item(.error, "failed", step: 4)])
    }

    func testDiscoveryAndAccessUseTheAgyContracts() throws {
        XCTAssertEqual(Harness.antigravity.commandName, "agy")
        XCTAssertEqual(Harness.antigravity.defaultExecutable(home: URL(fileURLWithPath: "/Users/example")),
                       "/Users/example/.local/bin/agy")
        XCTAssertTrue(Harness.antigravity.takesMessages)
        XCTAssertEqual(Harness.antigravity.terminal(session: "a1", running: false)?.arguments, ["--conversation", "a1"])
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
        [[ "$1" == -p ]] && exit 1
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
        [[ "$1" == -p ]] && exit 1
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
        try checkRunner(status: "ERROR", reason: "interrupted", exit: 1, expected: .interrupted)
        try checkRunner(status: "SUCCESS", reason: "print_timeout", exit: 0, expected: .timedOut)
        try checkRunner(status: "SUCCESS", reason: "print_timeout", exit: 1, expected: .timedOut)
        try checkRunner(status: "ERROR", reason: "error", exit: 1, expected: .failed(exitCode: 1))
        try checkRunner(status: "CANCELED", exit: 1, expected: .cancelled)
    }

    private func checkRunner(status: String?, reason: String? = nil, exit: Int, expected: RunOutcome) throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("rota-peer-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let peer = folder.appendingPathComponent("peer")
        let result = status.map {
            "{\"event\":\"result\",\"result\":{\"status\":\"\($0)\",\"response\":\"answer\""
                + (reason.map { ",\"finished_reason\":\"\($0)\"" } ?? "") + "}}"
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

    func testRecoveredHistoricalErrorDoesNotFailCompletedTurnOrContinuation() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("rota-stale-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let session = UUID().uuidString.lowercased()
        let stale = "API error (attempt 1): request failed: read tcp [2001:db8::1]:443: read: no route to host"
        let archive = try XCTUnwrap(AntigravityQuestionArchive(session: session, home: folder))
        try FileManager.default.createDirectory(at: archive.file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let initRow = #"{"event":"init","conversation_id":"\#(session)","init":{}}"#
        let firstArchive = """
        {"step_index":5,"type":"ERROR_MESSAGE","status":"DONE","error":"\(stale)"}
        {"step_index":6,"type":"PLANNER_RESPONSE","status":"DONE","content":"First answer"}

        """
        try Data(firstArchive.utf8).write(to: archive.file)
        let (firstOutcome, firstItems) = try runPeer(lines: [
            initRow,
            #"{"event":"step_update","step_update":{"step_index":5,"step_type":"error_message","state":"DONE"}}"#,
            responseLine(step: 6, text: "First answer"),
            errorResultLine(session: session, response: "First answer", error: stale)
        ], folder: folder)
        XCTAssertEqual(firstOutcome, .succeeded)
        XCTAssertEqual(firstItems.filter { $0.kind == .error }.map(\.text), [stale])
        XCTAssertEqual(firstItems.filter { $0.kind == .agent }.map(\.text), ["First answer"])

        try appendArchive(#"{"step_index":7,"type":"PLANNER_RESPONSE","status":"DONE","content":"Second answer"}"#,
                          to: archive.file)
        let (secondOutcome, secondItems) = try runPeer(lines: [
            initRow, responseLine(step: 7, text: "Second answer"),
            errorResultLine(session: session, response: "Second answer", error: stale)
        ], folder: folder, resume: session)
        XCTAssertEqual(secondOutcome, .succeeded)
        XCTAssertEqual(secondItems.filter { $0.kind == .error }.map(\.text), [])
        XCTAssertEqual(secondItems.filter { $0.kind == .agent }.map(\.text), ["Second answer"])

        try appendArchive(#"{"step_index":9,"type":"ERROR_MESSAGE","status":"DONE","error":"Late archive failure"}"#,
                          to: archive.file)
        let (thirdOutcome, thirdItems) = try runPeer(lines: [
            initRow, responseLine(step: 8, text: "Partial"),
            errorResultLine(session: session, response: "Partial", error: "Late archive failure")
        ], folder: folder)
        XCTAssertEqual(thirdOutcome, .failed(exitCode: 1))
        XCTAssertEqual(thirdItems.filter { $0.kind == .error }.map(\.text), [stale, "Late archive failure"])

        var stream = AntigravityStream()
        _ = events(responseLine(step: 8, text: "Intermediate"), stream: &stream)
        _ = events(#"""
        {"event":"step_update","step_update":{"step_index":9,"step_type":"error_message","state":"DONE"}}
        """#, stream: &stream)
        XCTAssertEqual(events(errorResultLine(session: session, response: "", error: "Quota exhausted"),
                              stream: &stream),
                       [.session(session), .item(.error, "Quota exhausted"), .result(.failed(exitCode: 1))])
    }

    private func responseLine(step: Int, text: String) -> String {
        #"{"event":"step_update","step_update":{"step_index":\#(step),"step_type":"agent_response","#
            + #""state":"DONE","text_delta":"\#(text)"}}"#
    }

    private func errorResultLine(session: String, response: String, error: String) -> String {
        #"{"event":"result","result":{"conversation_id":"\#(session)","status":"ERROR","#
            + #""response":"\#(response)","error":"\#(error)","finished_reason":"error"}}"#
    }

    private func appendArchive(_ row: String, to file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((row + "\n").utf8))
    }

    private func runPeer(lines: [String], folder: URL, resume: String? = nil) throws -> (RunOutcome, [TranscriptItem]) {
        let peer = folder.appendingPathComponent("peer-\(UUID())")
        let body = lines.map { "printf '%s\\n' '\($0)'" }.joined(separator: "\n")
        let script = "#!/bin/zsh\n[[ \"$1\" == -p ]] && exit 1\nIFS= read -r _\n\(body)\nexit 1\n"
        try script.write(to: peer, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: peer.path)
        let log = folder.appendingPathComponent("log-\(UUID()).log")
        let spec = LaunchSpec(executable: peer.path, prompt: "prompt", arguments: [], workingDirectory: folder.path,
                              environment: ["HOME": folder.path], mode: .antigravityStream, timeout: 10,
                              log: log, resume: resume)
        let finished = expectation(description: "peer finished")
        var result: RunOutcome?
        let control = try ProcessLauncher().launch(spec, events: RunEvents(session: { _ in }, finished: { outcome in
            result = outcome
            finished.fulfill()
        }))
        wait(for: [finished], timeout: 15)
        withExtendedLifetime(control) {}
        var reader = TranscriptReader()
        return (try XCTUnwrap(result), reader.read(log: log, finished: true).items)
    }
}
