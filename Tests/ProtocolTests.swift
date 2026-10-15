@testable import RotaCore
import XCTest
import os

final class PipeWriterTests: XCTestCase {
    func testCompletionsFollowMessageBoundariesThroughBackpressureAndCompaction() throws {
        let pipe = Pipe()
        XCTAssertNotEqual(fcntl(pipe.fileHandleForWriting.fileDescriptor, F_SETFL, O_NONBLOCK), -1)
        let queue = DispatchQueue(label: "rota.test.pipe-completions")
        let writer = PipeWriter(pipe.fileHandleForWriting, queue: queue)
        defer { writer.close(); pipe.fileHandleForReading.readabilityHandler = nil }
        let completions = OSAllocatedUnfairLock(initialState: [Int]())
        let first = Data("first\n".utf8)
        let second = Data(repeating: 42, count: 1_000_000)
        let third = Data("third\n".utf8)
        writer.send(first) { completions.withLock { $0.append(1) } }
        writer.send(second) { completions.withLock { $0.append(2) } }
        queue.sync { XCTAssertEqual(completions.withLock { $0 }, [1]) }
        // Appending after a partial write compacts the buffer and its completion offsets.
        let written = expectation(description: "the final message is fully written")
        writer.send(third) {
            completions.withLock { $0.append(3) }
            written.fulfill()
        }
        queue.sync { XCTAssertEqual(completions.withLock { $0 }, [1]) }
        let payload = first + second + third
        let received = OSAllocatedUnfairLock(initialState: Data())
        let read = expectation(description: "all three messages are read")
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            let count = received.withLock { bytes in bytes.append(data); return bytes.count }
            if count >= payload.count {
                handle.readabilityHandler = nil
                read.fulfill()
            }
        }
        wait(for: [written, read], timeout: 5)
        XCTAssertEqual(completions.withLock { $0 }, [1, 2, 3])
        XCTAssertEqual(received.withLock { $0 }, payload)
    }

    func testBackpressureDoesNotBlockTheQueueOrLoseBytes() throws {
        let pipe = Pipe()
        let handle = pipe.fileHandleForWriting
        // Keep a broken blocking implementation from hanging the test process.
        XCTAssertNotEqual(fcntl(handle.fileDescriptor, F_SETFL, O_NONBLOCK), -1)
        let queue = DispatchQueue(label: "rota.test.pipe-writer")
        let writer = PipeWriter(handle, queue: queue)
        defer { writer.close(); pipe.fileHandleForReading.readabilityHandler = nil }
        let payload = Data((0..<1_000_000).map { UInt8($0 % 251) })
        let available = expectation(description: "the writer queue remains available without a reader")
        writer.send(payload)
        queue.async { available.fulfill() }
        wait(for: [available], timeout: 2)
        let received = OSAllocatedUnfairLock(initialState: Data())
        let complete = expectation(description: "all queued bytes reach the reader")
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            let count = received.withLock { bytes in bytes.append(data); return bytes.count }
            if count >= payload.count {
                handle.readabilityHandler = nil
                complete.fulfill()
            }
        }
        wait(for: [complete], timeout: 5)
        XCTAssertEqual(received.withLock { $0 }, payload)
    }
}

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
    func testABooleanResponseIDCannotConfirmANumericRequest() {
        let transport = LoopbackTransport()
        let peer = JSONRPCPeer(transport: transport)
        var replies = 0
        peer.request("fixture", [:]) { _ in replies += 1 }
        transport.deliver(#"{"id":true,"result":{}}"#)
        XCTAssertEqual(replies, 0)
        transport.deliver(#"{"id":1.0,"result":{}}"#)
        XCTAssertEqual(replies, 1)
    }

    func testAWebSocketCloseFrameFailsThePendingRequest() throws {
        let input = Pipe()
        let output = Pipe()
        let transport = WebSocketTransport(input: input.fileHandleForWriting, output: output.fileHandleForReading,
                                           key: "dGhlIHNhbXBsZSBub25jZQ==")
        let peer = JSONRPCPeer(transport: transport)
        defer { peer.close(); try? output.fileHandleForWriting.close() }
        let closed = expectation(description: "close frame resolves the pending request")
        peer.request("initialize", [:]) { result in
            guard case .failure = result else { return XCTFail("A close frame cannot confirm delivery") }
            closed.fulfill()
        }
        let upgrade = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            + "Sec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n\r\n"
        try output.fileHandleForWriting.write(contentsOf: Data(upgrade.utf8))
        try output.fileHandleForWriting.write(contentsOf: Data([0x88, 0]))
        wait(for: [closed], timeout: 2)
    }

    func testNotificationsAfterCloseCannotReachTheRun() {
        let transport = LoopbackTransport()
        let peer = JSONRPCPeer(transport: transport)
        var notifications = 0
        peer.onNotification = { _, _ in notifications += 1 }
        peer.close()
        transport.deliver(#"{"method":"update","params":{}}"#)
        XCTAssertEqual(notifications, 0)
    }

    func testAClosedProviderPipeFailsThePendingRequestWithoutWaitingForAReply() throws {
        let input = Pipe()
        let output = Pipe()
        try input.fileHandleForReading.close()
        let transport = LineTransport(input: input.fileHandleForWriting, output: output.fileHandleForReading)
        let peer = JSONRPCPeer(transport: transport)
        defer { peer.close(); try? output.fileHandleForWriting.close() }
        let failed = expectation(description: "write failure reaches the requester")
        peer.request("initialize", [:]) { result in
            guard case .failure = result else { return XCTFail("The dead pipe cannot confirm a request") }
            failed.fulfill()
        }
        wait(for: [failed], timeout: 2)
    }
    func testModelCatalogReadsEveryPageAndNeverReturnsAPartialCatalog() {
        let transport = LoopbackTransport()
        let peer = JSONRPCPeer(transport: transport)
        var result: [ModelOption]?
        var completed = false
        ModelCatalog.readCodexModels(peer) { result = $0; completed = true }
        transport.deliver(#"{"id":1,"result":{"data":[{"id":"model-a"}],"nextCursor":"page-2"}}"#)
        XCTAssertFalse(completed)
        XCTAssertEqual(transport.sent.count, 2)
        XCTAssertEqual((transport.sent[1]["params"] as? [String: String])?["cursor"], "page-2")
        transport.deliver(#"{"id":2,"result":{"data":[{"id":"model-b"}],"nextCursor":null}}"#)
        XCTAssertTrue(completed)
        XCTAssertEqual(result?.map(\.id), ["model-a", "model-b"])
        completed = false
        ModelCatalog.readCodexModels(peer) { result = $0; completed = true }
        transport.deliver(#"{"id":3,"result":{"data":[{"id":"model-a"}],"nextCursor":"page-2"}}"#)
        transport.deliver(#"{"id":4,"error":{"message":"page unavailable"}}"#)
        XCTAssertTrue(completed)
        XCTAssertNil(result, "one successful page does not prove the catalog is complete")
    }

    func testModelCatalogRejectsARepeatingCursor() {
        let transport = LoopbackTransport()
        let peer = JSONRPCPeer(transport: transport)
        var completed = false
        ModelCatalog.readCodexModels(peer) { XCTAssertNil($0); completed = true }
        transport.deliver(#"{"id":1,"result":{"data":[],"nextCursor":"same"}}"#)
        transport.deliver(#"{"id":2,"result":{"data":[],"nextCursor":"same"}}"#)
        XCTAssertTrue(completed)
        XCTAssertEqual(transport.sent.count, 2)
    }

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

    func testServerRequestCanWaitForUserAndOnlyReplyOnce() {
        let transport = LoopbackTransport()
        let peer = JSONRPCPeer(transport: transport)
        var respond: ((Any?) -> Void)?
        peer.onAsyncRequest = { method, params, identity, reply in
            XCTAssertEqual(identity, #"["provider-id"]"#)
            XCTAssertEqual(method, "item/commandExecution/requestApproval")
            XCTAssertEqual(params["command"] as? String, "echo sample")
            respond = reply
        }
        transport.deliver(#"{"id":"provider-id","method":"item/commandExecution/requestApproval","params": "#
                          + #"{"command":"echo sample"}}"#)
        XCTAssertTrue(transport.sent.isEmpty)
        XCTAssertNotNil(respond)
        respond?(["decision": "decline"])
        respond?(["decision": "accept"])
        XCTAssertEqual(transport.sent.count, 1)
        XCTAssertEqual(transport.sent[0]["id"] as? String, "provider-id")
        XCTAssertEqual((transport.sent[0]["result"] as? [String: Any])?["decision"] as? String, "decline")
    }

    func testSteerWaitsForMatchingAcknowledgmentAndDoesNotRetryAnUnconfirmedWrite() {
        let transport = LoopbackTransport()
        let peer = JSONRPCPeer(transport: transport)
        var deadline: (() -> Void)?
        peer.scheduleTimeout = { seconds, work in XCTAssertEqual(seconds, 10); deadline = work }
        var states: [MessageDelivery] = []
        CodexDaemonRun.requestSteer(peer, message: "Change direction", threadID: "thread", turnID: "turn") {
            states.append($0)
        }
        XCTAssertEqual(transport.sent.count, 1)
        XCTAssertEqual(transport.sent[0]["method"] as? String, "turn/steer")
        XCTAssertEqual((transport.sent[0]["params"] as? [String: Any])?["expectedTurnId"] as? String, "turn")
        XCTAssertTrue(states.isEmpty, "a local send is not a delivery acknowledgment")
        transport.deliver(#"{"jsonrpc":"2.0","id":1,"result":{"turnId":"turn"}}"#)
        XCTAssertEqual(states, [.accepted])
        deadline?()
        XCTAssertEqual(states, [.accepted], "a resolved request cannot time out again")
        CodexDaemonRun.requestSteer(peer, message: "Another message", threadID: "thread", turnID: "turn") {
            states.append($0)
        }
        deadline?()
        guard case .unconfirmed = states.last else { return XCTFail("timeout must preserve uncertainty") }
        transport.deliver(#"{"jsonrpc":"2.0","id":2,"result":{"turnId":"turn"}}"#)
        XCTAssertEqual(states.count, 2, "a late reply cannot resolve an expired request twice")
        XCTAssertEqual(transport.sent.count, 2, "there is no automatic retry of a potentially applied write")
    }

    func testSteeringSendsNativeImageBlocksThroughTheRealPeer() throws {
        let transport = LoopbackTransport()
        let peer = JSONRPCPeer(transport: transport)
        let image = ChatAttachment(id: UUID().uuidString, url: URL(fileURLWithPath: "/tmp/sample.png"),
                                   name: "sample.png", mimeType: "image/png", size: 12)
        var state: MessageDelivery?
        CodexDaemonRun.requestSteer(peer, message: ChatMessage(text: "", attachments: [image]),
                                   threadID: "thread", turnID: "turn") { state = $0 }
        let request = try XCTUnwrap(transport.sent.first)
        let params = try XCTUnwrap(request["params"] as? [String: Any])
        let input = try XCTUnwrap(params["input"] as? [[String: String]])
        XCTAssertEqual(input, [["type": "localImage", "path": "/tmp/sample.png"]])
        transport.deliver(#"{"jsonrpc":"2.0","id":1,"result":{"turnId":"turn"}}"#)
        XCTAssertEqual(state, .accepted)
    }

    func testSteerRejectsAnotherTurnAndKeepsProviderError() {
        let transport = LoopbackTransport()
        let peer = JSONRPCPeer(transport: transport)
        peer.scheduleTimeout = { _, _ in }
        var state: MessageDelivery?
        CodexDaemonRun.requestSteer(peer, message: "Change direction", threadID: "thread", turnID: "turn") {
            state = $0
        }
        transport.deliver(#"{"jsonrpc":"2.0","id":1,"result":{"turnId":"other-turn"}}"#)
        XCTAssertEqual(state, .failed("The active turn changed."))
        CodexDaemonRun.requestSteer(peer, message: "Change direction", threadID: "thread", turnID: "turn") {
            state = $0
        }
        transport.deliver(#"{"jsonrpc":"2.0","id":2,"error":{"code":1,"message":"Steering unavailable"}}"#)
        XCTAssertEqual(state, .failed("Steering unavailable"))
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

    func testCloseFailsWaitingRequests() {
        let transport = LoopbackTransport()
        let peer = JSONRPCPeer(transport: transport)
        var failed = false
        peer.request("a", [:]) { if case .failure = $0 { failed = true } }
        transport.close()
        XCTAssertTrue(failed)
    }

    func testClosedPeerRejectsNewRequestsWithoutWritingAndClosesOnlyOnce() {
        let transport = LoopbackTransport()
        let peer = JSONRPCPeer(transport: transport)
        var closed = 0
        var failed = false
        peer.onClose = { closed += 1 }
        peer.close()
        transport.close()
        peer.request("turn/start", [:]) {
            if case .failure(let error) = $0 {
                failed = true
                XCTAssertFalse(error.deliveryUncertain, "nothing was written after close")
            }
        }
        XCTAssertTrue(failed)
        XCTAssertTrue(transport.sent.isEmpty)
        XCTAssertEqual(closed, 1)
    }
}

final class WebSocketFrameTests: XCTestCase {
    func testUpgradeRequiresTheMatchingNonceAndWebSocketHeaders() {
        // The independent nonce/accept example from RFC 6455, section 1.3.
        let accept = "s3pPLMBiTxaQ9kYGzzhZRbK+xOo="
        let head = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: keep-alive, Upgrade\r\n"
            + "Sec-WebSocket-Accept: \(accept)"
        XCTAssertTrue(WebSocketTransport.validUpgrade(head, expectedAccept: accept))
        XCTAssertTrue(WebSocketTransport.validUpgrade(head.replacingOccurrences(of: "Upgrade:", with: "upgrade:"),
                                                      expectedAccept: accept))
        for invalid in [head.replacingOccurrences(of: accept, with: "wrong nonce"),
                        head.replacingOccurrences(of: "Upgrade: websocket", with: "Upgrade: another-protocol"),
                        head.replacingOccurrences(of: "Connection: keep-alive, Upgrade", with: "Connection: close"),
                        head.replacingOccurrences(of: "101 Switching", with: "1010 Switching"),
                        head + "\r\nSec-WebSocket-Accept: \(accept)"] {
            XCTAssertFalse(WebSocketTransport.validUpgrade(invalid, expectedAccept: accept), invalid)
        }
    }

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

    func testOversizedWebSocketLengthCannotOverflowTheParser() {
        XCTAssertNil(WebSocketTransport.parse(Data([0x81, 0x7F] + Array(repeating: 0xFF, count: 8))))
        XCTAssertNil(WebSocketTransport.parse(Data([0x81, 0x7F, 0x7F] + Array(repeating: 0xFF, count: 7))))
    }
}

final class LiveRunPieceTests: XCTestCase {
    func testClaudeToolResultsRemainVisible() {
        let event = #"""
        {"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"call-1",
        "content":"Permission denied","is_error":true}]}}
        """#
        let formatted = StreamJSONFormatter.format(event)
        XCTAssertNotNil(formatted)
        XCTAssertTrue(formatted?.contains("call-1") == true)
        XCTAssertTrue(formatted?.contains("Permission denied") == true)
    }

    func testGrokQueueAcknowledgmentMatchesTheInstalledLeaderResponse() {
        XCTAssertEqual(GrokACPRun.interjectionDelivery(["result": ["status": "queued"]]), .queued)
        XCTAssertEqual(GrokACPRun.interjectionDelivery(["accepted": true]), .accepted)
        XCTAssertEqual(GrokACPRun.interjectionDelivery(["accepted": false]),
                       .failed("Grok did not accept the interjection."))
        XCTAssertEqual(GrokACPRun.interjectionDelivery(["result": ["status": "unknown"]]),
                       .unconfirmed("Grok did not confirm whether the message was queued."))
    }

    func testGrokDoesNotGrantRequestedPermissions() {
        for options in [[], [["optionId": "yes", "kind": "allow_once"]],
                        [["optionId": "always", "kind": "allow_always"],
                         ["optionId": "no", "kind": "reject_once"]]] {
            let answer = GrokACPRun.answer("session/request_permission", ["options": options]) as? [String: Any]
            XCTAssertEqual((answer?["outcome"] as? [String: Any])?["outcome"] as? String, "cancelled")
        }
        XCTAssertNil(GrokACPRun.answer("fs/read_text_file", [:]))
    }

    func testCodexItemDescriptions() {
        XCTAssertEqual(CodexDaemonRun.describe(started: ["type": "commandExecution", "command": "ls"]), "-> $ ls")
        XCTAssertEqual(CodexDaemonRun.describe(started: ["type": "mcpToolCall", "tool": "search"]), "-> search")
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
}
