@testable import RotaCore
import XCTest

private final class LoopbackTransport: MessageTransport {
    var onMessage: ((Data) -> Void)?
    var onClose: (() -> Void)?
    var sent: [[String: Any]] = []
    func send(_ message: Data) {
        sent.append((try? JSONSerialization.jsonObject(with: message)) as? [String: Any] ?? [:])
    }
    func close() { onClose?() }
    func deliver(_ json: String) { onMessage?(Data(json.utf8)) }
}

final class JSONRPCPeerTests: XCTestCase {
    func testRepliesAndNotificationsArriveOnTheCallbackQueue() {
        let transport = LoopbackTransport()
        let queue = DispatchQueue(label: "rota.test.callbacks")
        let key = DispatchSpecificKey<Bool>()
        queue.setSpecific(key: key, value: true)
        let peer = JSONRPCPeer(transport: transport, callbackQueue: queue)
        let replied = expectation(description: "reply on the queue")
        let notified = expectation(description: "notification on the queue")
        peer.request("ping", [:]) { _ in
            XCTAssertEqual(DispatchQueue.getSpecific(key: key), true)
            replied.fulfill()
        }
        peer.onNotification = { _, _ in
            XCTAssertEqual(DispatchQueue.getSpecific(key: key), true)
            notified.fulfill()
        }
        transport.deliver(#"{"jsonrpc":"2.0","id":1,"result":{}}"#)
        transport.deliver(#"{"jsonrpc":"2.0","method":"update","params":{}}"#)
        wait(for: [replied, notified], timeout: 2)
    }

    func testRequestGetsItsOwnReply() {
        let transport = LoopbackTransport()
        let peer = JSONRPCPeer(transport: transport)
        var first: Any?
        var second: String?
        peer.request("a", [:]) { if case .success(let value) = $0 { first = value } }
        peer.request("b", [:]) { if case .failure(let error) = $0 { second = error.message } }
        XCTAssertEqual(transport.sent.map { $0["id"] as? Int }, [1, 2])
        transport.deliver(#"{"jsonrpc":"2.0","id":2,"error":{"code":1,"message":"nope"}}"#)
        transport.deliver(#"{"jsonrpc":"2.0","id":1,"result":{"ok":true}}"#)
        XCTAssertEqual((first as? [String: Any])?["ok"] as? Bool, true)
        XCTAssertEqual(second, "nope")
    }

    func testNotificationsAndPeerRequests() {
        let transport = LoopbackTransport()
        let peer = JSONRPCPeer(transport: transport)
        var seen: [String] = []
        peer.onNotification = { method, _ in seen.append(method) }
        peer.onRequest = { method, _ in method == "ping" ? ["pong": true] : nil }
        transport.deliver(#"{"jsonrpc":"2.0","method":"turn/completed","params":{}}"#)
        transport.deliver(#"{"jsonrpc":"2.0","id":"x1","method":"ping","params":{}}"#)
        transport.deliver(#"{"jsonrpc":"2.0","id":"x2","method":"fs/read","params":{}}"#)
        XCTAssertEqual(seen, ["turn/completed"])
        XCTAssertEqual(transport.sent[0]["id"] as? String, "x1")
        XCTAssertNotNil(transport.sent[0]["result"])
        XCTAssertNotNil(transport.sent[1]["error"])
    }

    func testDeferredQuestionDoesNotBlockNotificationsAndRepliesOnlyOnce() {
        let transport = LoopbackTransport()
        let peer = JSONRPCPeer(transport: transport)
        var answer: ((Any?) -> Void)?
        var notifications = 0
        peer.onRequestAsync = { id, method, _, reply in
            XCTAssertEqual(id, "q")
            XCTAssertEqual(method, "ask")
            answer = reply
        }
        peer.onNotification = { _, _ in notifications += 1 }
        transport.deliver(#"{"jsonrpc":"2.0","id":"q","method":"ask","params":{}}"#)
        transport.deliver(#"{"jsonrpc":"2.0","method":"progress","params":{}}"#)
        XCTAssertEqual(notifications, 1)
        XCTAssertTrue(transport.sent.isEmpty)
        answer?(["answer": "Blue"])
        answer?(["answer": "Green"])
        XCTAssertEqual(transport.sent.count, 1)
        XCTAssertEqual((transport.sent.first?["result"] as? [String: String])?["answer"], "Blue")
    }

    func testResolvedAndDisconnectedQuestionsCannotSendLateAnswers() {
        let transport = LoopbackTransport()
        let peer = JSONRPCPeer(transport: transport)
        var answer: ((Any?) -> Void)?
        peer.onRequestAsync = { _, _, _, reply in answer = reply }
        transport.deliver(#"{"jsonrpc":"2.0","id":1,"method":"ask","params":{}}"#)
        peer.dismissRequest("1")
        answer?(["answer": "late"])
        XCTAssertTrue(transport.sent.isEmpty)
        transport.deliver(#"{"jsonrpc":"2.0","id":2,"method":"ask","params":{}}"#)
        transport.close()
        answer?(["answer": "late"])
        XCTAssertTrue(transport.sent.isEmpty)
    }

    func testCloseFailsWaitingRequests() {
        let transport = LoopbackTransport()
        let peer = JSONRPCPeer(transport: transport)
        var failed = false
        peer.request("a", [:]) { if case .failure = $0 { failed = true } }
        transport.close()
        XCTAssertTrue(failed)
    }
}

final class WebSocketFrameTests: XCTestCase {
    /// Client frames are masked; unmasking one must give the payload back, at every length form.
    func testFrameRoundTripsAtEachLengthForm() throws {
        for count in [0, 5, 125, 126, 70_000] {
            let payload = Data((0..<count).map { UInt8($0 % 251) })
            let frame = WebSocketTransport.frame(payload, opcode: 0x1)
            XCTAssertEqual(frame[1] & 0x80, 0x80, "client frames are masked")
            let parsedFrame = try XCTUnwrap(WebSocketTransport.parse(frame))
            let (opcode, final, parsed, length) = (parsedFrame.opcode, parsedFrame.final, parsedFrame.payload,
                                                   parsedFrame.length)
            XCTAssertEqual(opcode, 0x1)
            XCTAssertTrue(final)
            XCTAssertEqual(parsed, payload, "length \(count)")
            XCTAssertEqual(length, frame.count)
        }
    }

    func testParseWaitsForAWholeFrame() {
        let frame = WebSocketTransport.frame(Data(repeating: 7, count: 300), opcode: 0x1)
        XCTAssertNil(WebSocketTransport.parse(frame.prefix(frame.count - 1)))
        XCTAssertNil(WebSocketTransport.parse(frame.prefix(1)))
    }

    func testUnmaskedServerFrame() throws {
        let frame = Data([0x81, 0x02]) + Data("hi".utf8)
        let parsedFrame = try XCTUnwrap(WebSocketTransport.parse(frame + Data([0x81])))
        let (opcode, payload, length) = (parsedFrame.opcode, parsedFrame.payload, parsedFrame.length)
        XCTAssertEqual(opcode, 0x1)
        XCTAssertEqual(payload, Data("hi".utf8))
        XCTAssertEqual(length, 4)
    }
}

final class LiveRunPieceTests: XCTestCase {
    func testGrokPermissionPicksAnAllowOption() {
        let params: [String: Any] = ["options": [["optionId": "no", "kind": "reject_once"],
                                                 ["optionId": "yes", "kind": "allow_once"]]]
        let answer = GrokACPRun.answer("session/request_permission", params) as? [String: Any]
        XCTAssertEqual((answer?["outcome"] as? [String: Any])?["optionId"] as? String, "yes")
        XCTAssertNil(GrokACPRun.answer("fs/read_text_file", [:]))
        XCTAssertNil(GrokACPRun.answer("session/request_permission",
                                       ["options": [["optionId": "no", "kind": "reject_once"]]]))
    }

    func testCodexItemDescriptions() {
        XCTAssertEqual(CodexDaemonRun.describe(started: ["type": "commandExecution", "command": "ls"]), "$ ls")
        XCTAssertEqual(CodexDaemonRun.describe(started: ["type": "mcpToolCall", "tool": "search"]), "search")
        XCTAssertEqual(CodexDaemonRun.describe(started: ["type": "collabAgentToolCall", "tool": "spawnAgent"]),
                       "agent spawnAgent")
        XCTAssertNil(CodexDaemonRun.describe(started: ["type": "reasoning"]))
    }

    /// Runs the screen script with zsh directly: the command's output reaches the
    /// log and its exit status the exit file, even through the tee pipeline.
    func testShellScriptRecordsOutputAndExitStatus() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let log = folder.appendingPathComponent("run's.log")
        let exitFile = folder.appendingPathComponent("exit")
        let script = folder.appendingPathComponent("s.zsh")
        try ScreenRun.scriptText(command: "echo \"in $(pwd)\"; echo oops >&2; exit 4", directory: folder.path,
                                 log: log, exitFile: exitFile).write(to: script, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [script.path]
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        let status = try String(contentsOf: exitFile, encoding: .utf8)
        XCTAssertEqual(status.trimmingCharacters(in: .whitespacesAndNewlines), "4")
        let text = try String(contentsOf: log, encoding: .utf8)
        XCTAssertTrue(text.contains("oops"))
        XCTAssertTrue(text.contains("in /"), text)
    }

    func testShellQuote() {
        XCTAssertEqual(shellQuote("it's"), #"'it'\''s'"#)
    }

    /// The order grok 1.0.70 sent on 2026-10-26 around a background command that woke the session.
    func testGrokActivityHoldsTheRunUntilTheWokenTurnEnds() {
        var activity = GrokActivity()
        func read(_ method: String, _ params: [String: Any]) {
            XCTAssertTrue(activity.read(method, params.merging(["sessionId": "s1"]) { $1 }, session: "s1"), method)
        }
        func update(_ method: String, _ fields: [String: Any]) { read(method, ["update": fields]) }
        read("_x.ai/queue/changed", ["entries": [], "runningPromptId": "p1"])
        update("_x.ai/session_notification", ["sessionUpdate": "background_tasks",
                                              "tasks": [["task_id": "t1", "status": "running"]]])
        read("_x.ai/queue/changed", ["entries": []])
        update("_x.ai/session_notification", ["sessionUpdate": "turn_completed", "prompt_id": "p1"])
        XCTAssertFalse(activity.idle)
        XCTAssertEqual(activity.running, 1)
        read("_x.ai/queue/changed", ["entries": [], "runningPromptId": "task-completed-t1"])
        update("_x.ai/task_completed", ["sessionUpdate": "task_completed", "will_wake": true])
        update("_x.ai/session_notification", ["sessionUpdate": "background_tasks",
                                              "tasks": [["task_id": "t1", "status": "completed"]]])
        XCTAssertFalse(activity.idle, "the woken turn is still running")
        update("_x.ai/session_notification", ["sessionUpdate": "turn_completed", "prompt_id": "task-completed-t1"])
        XCTAssertTrue(activity.idle)
    }

    func testGrokActivityWaitsForAWakeAndIgnoresOtherSessions() {
        var activity = GrokActivity()
        XCTAssertFalse(activity.read("_x.ai/queue/changed", ["sessionId": "other", "runningPromptId": "x"],
                                     session: "s1"))
        XCTAssertFalse(activity.read("session/update", ["sessionId": "s1"], session: "s1"))
        XCTAssertTrue(activity.idle)
        _ = activity.read("_x.ai/subagent_finished", ["sessionId": "s1", "update": [
            "sessionUpdate": "subagent_finished", "subagent_id": "a1", "will_wake": true]], session: "s1")
        XCTAssertFalse(activity.idle, "a wake is announced before its turn is queued")
        _ = activity.read("_x.ai/queue/changed", ["sessionId": "s1", "entries": [], "runningPromptId": "w"],
                          session: "s1")
        _ = activity.read("_x.ai/session_notification", ["sessionId": "s1", "update": [
            "sessionUpdate": "turn_completed", "prompt_id": "w"]], session: "s1")
        XCTAssertTrue(activity.idle)
        _ = activity.read("_x.ai/session/update", ["sessionId": "s1", "update": [
            "sessionUpdate": "subagent_spawned", "subagent_id": "a2"]], session: "s1")
        XCTAssertEqual(activity.running, 1)
    }
}
