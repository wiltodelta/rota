@testable import RotaCore
import Darwin
import XCTest

final class ClaudeHookTests: XCTestCase {
    private func question(session: String = "session") -> [String: Any] {
        ["session_id": session, "hook_event_name": "PreToolUse", "tool_name": "AskUserQuestion",
         "tool_input": ["questions": [["question": "Which sections?", "multiSelect": true,
            "options": [["label": "Summary", "description": "Show totals"], ["label": "Details"]]]]]]
    }

    func testQuestionsPreserveInputsAndPassExplicitAnswersThroughTheHook() throws {
        let hook = try XCTUnwrap(ClaudeHookRequest(question(), session: "session"))
        XCTAssertTrue(hook.request.questions[0].multiple)
        XCTAssertEqual(hook.request.questions[0].options, ["Summary", "Details"])
        let response = hook.answer(.init(choice: "submit", answers: ["0": "Summary, Details"]))
        let output = try XCTUnwrap(response["hookSpecificOutput"] as? [String: Any])
        XCTAssertEqual(output["permissionDecision"] as? String, "allow")
        let updated = try XCTUnwrap(output["updatedInput"] as? [String: Any])
        XCTAssertEqual(updated["answers"] as? [String: String], ["Which sections?": "Summary, Details"])
        XCTAssertNotNil(updated["questions"])
        XCTAssertNil(output["updatedPermissions"])
    }

    func testForeignMalformedAndUnsupportedHooksCannotCreateForms() {
        XCTAssertNil(ClaudeHookRequest(question(session: "other"), session: "session"))
        var payload = question()
        payload["tool_input"] = [:]
        XCTAssertNil(ClaudeHookRequest(payload, session: "session"))
        payload = question()
        payload["tool_name"] = "Bash"
        XCTAssertNil(ClaudeHookRequest(payload, session: "session"))
    }

    func testOneTimePermissionAndDenialNeverWritePolicy() throws {
        let payload: [String: Any] = ["session_id": "session", "hook_event_name": "PermissionRequest",
            "tool_name": "Bash", "tool_input": ["command": "echo sample"]]
        let hook = try XCTUnwrap(ClaudeHookRequest(payload, session: "session"))
        XCTAssertTrue(hook.request.detail.contains("echo sample"))
        let allowed = try XCTUnwrap(hook.answer(.init(choice: "allow"))["hookSpecificOutput"] as? [String: Any])
        let decision = try XCTUnwrap(allowed["decision"] as? [String: Any])
        XCTAssertEqual(decision["behavior"] as? String, "allow")
        XCTAssertNil(decision["updatedPermissions"])
        let denied = try XCTUnwrap(hook.answer(.init(choice: "deny"))["hookSpecificOutput"] as? [String: Any])
        XCTAssertEqual((denied["decision"] as? [String: Any])?["behavior"] as? String, "deny")
    }

    func testMissingConnectionReturnsDenialRatherThanAnImplicitApproval() throws {
        let result = ClaudeHookClient.response(event: "PreToolUse",
            input: try JSONSerialization.data(withJSONObject: question()),
            socket: URL(fileURLWithPath: "/tmp/rota-hook-missing-" + UUID().uuidString))
        let output = try XCTUnwrap(result["hookSpecificOutput"] as? [String: Any])
        XCTAssertEqual(output["permissionDecision"] as? String, "deny")
    }

    func testActualSocketCarriesTheBrokerAnswerAndConsumesItOnce() throws {
        let folder = URL(fileURLWithPath: "/tmp/rota-hook-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let queue = DispatchQueue(label: "rota.hook.reply.test")
        let server = try ClaudeHookServer(folder: folder, queue: queue)
        defer { queue.sync { server.close() } }
        let received = expectation(description: "request received")
        let answered = expectation(description: "answer received by client")
        nonisolated(unsafe) var identity: String?
        nonisolated(unsafe) var output: [String: Any]?
        let broker = SessionRequests { _ in }
        server.received = { id, payload, reply in
            var hook = ClaudeHookRequest(payload, session: "session")!
            hook.request.id = id
            identity = id
            broker.add(hook.request, answer: { reply(hook.answer($0)) }, cancel: {})
            received.fulfill()
        }
        let bytes = try JSONSerialization.data(withJSONObject: question())
        let socket = URL(fileURLWithPath: server.path)
        DispatchQueue.global().async {
            output = ClaudeHookClient.response(event: "PreToolUse", input: bytes, socket: socket)
            answered.fulfill()
        }
        wait(for: [received], timeout: 2)
        let id = try XCTUnwrap(identity)
        queue.sync {
            XCTAssertFalse(broker.answer(id, .init(choice: "submit")))
            XCTAssertTrue(broker.answer(id, .init(choice: "submit", answers: ["0": "Summary"])))
            XCTAssertFalse(broker.answer(id, .init(choice: "submit", answers: ["0": "Details"])))
        }
        wait(for: [answered], timeout: 2)
        let specific = try XCTUnwrap(output?["hookSpecificOutput"] as? [String: Any])
        let updated = try XCTUnwrap(specific["updatedInput"] as? [String: Any])
        XCTAssertEqual(updated["answers"] as? [String: String], ["Which sections?": "Summary"])
    }

    func testDeferredSocketReplyAndDisconnectCancelTheOwningRequest() throws {
        let folder = URL(fileURLWithPath: "/tmp/rota-hook-" + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let queue = DispatchQueue(label: "rota.hook.test")
        let server = try ClaudeHookServer(folder: folder, queue: queue)
        defer { queue.sync { server.close() } }
        let received = expectation(description: "request reached the broker")
        let cancelled = expectation(description: "client EOF cancelled the form")
        let broker = SessionRequests { requests in
            if requests.isEmpty { cancelled.fulfill() } else { received.fulfill() }
        }
        server.received = { id, payload, reply in
            var hook = ClaudeHookRequest(payload, session: "session")!
            hook.request.id = id
            broker.add(hook.request, answer: { reply(hook.answer($0)) }, cancel: {})
        }
        server.disconnected = { broker.cancel($0, notifyProvider: false) }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = try ControlServer.address(server.path)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(connected, 0)
        let data = try JSONSerialization.data(withJSONObject: ["id": 1, "method": "claude-hook", "params": question()])
            + Data([10])
        XCTAssertEqual(data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, $0.count) }, data.count)
        wait(for: [received], timeout: 2)
        Darwin.close(fd)
        wait(for: [cancelled], timeout: 2)
        queue.sync { XCTAssertTrue(broker.isEmpty) }
    }
}
