import Foundation
@testable import RotaCore
import XCTest

/// A deterministic in-memory vendor. It runs the real RPC adapter without a CLI or model.
final class HarnessPeer: MessageTransport, @unchecked Sendable {
    var onMessage: ((Data) -> Void)?
    var onClose: (() -> Void)?
    var receive: (([String: Any]) -> Void)?
    func send(_ data: Data) {
        guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        receive?(value)
    }
    func close() {}
    func reply(_ request: [String: Any], result: [String: Any] = [:], error: String? = nil) {
        var response: [String: Any] = ["id": request["id"] ?? 0]
        if let error { response["error"] = ["code": -32000, "message": error] } else { response["result"] = result }
        deliver(response)
    }
    func deliver(_ value: [String: Any]) {
        if let data = try? JSONSerialization.data(withJSONObject: value) { onMessage?(data) }
    }
}

final class HarnessLifecycleTests: XCTestCase {
    private func fixture(_ mode: LaunchMode, finished: @escaping (RunOutcome) -> Void,
                         session: @escaping (String) -> Void = { _ in },
                         reconciliation: @escaping () -> Void = {}) throws -> (LaunchSpec, RunJournal) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let log = folder.appendingPathComponent("run.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let spec = LaunchSpec(executable: "/bin/false", prompt: "synthetic", arguments: [],
                              workingDirectory: folder.path, environment: [:], mode: mode, timeout: nil,
                              log: log)
        return (spec, RunJournal(output: try FileHandle(forWritingTo: log),
                                events: RunEvents(session: session, finished: finished,
                                                  reconciliationRequired: reconciliation)))
    }

    func testCodexFailedStartReplyReservesTheKnownNativeThread() throws {
        let reserved = expectation(description: "unknown turn stays reserved")
        let ended = expectation(description: "client failed")
        let (spec, journal) = try fixture(.codexDaemon, finished: { _ in ended.fulfill() },
                                           reconciliation: { reserved.fulfill() })
        let peer = JSONRPCPeer(transport: HarnessPeer())
        let runner = CodexDaemonRun(spec: spec, journal: journal, peer: peer)
        runner.threadStarted(.success(["thread": ["id": "owned-thread"]]))
        runner.turnStarted(.failure(JSONRPCError(message: "connection closed")))
        wait(for: [reserved, ended], timeout: 2)
    }

    func testGrokLostPromptReplyReservesTheNativeSession() throws {
        let reserved = expectation(description: "native work may still run")
        let ended = expectation(description: "client failed")
        let (spec, journal) = try fixture(.grokACP, finished: { _ in ended.fulfill() },
                                           reconciliation: { reserved.fulfill() })
        let transport = HarnessPeer()
        transport.receive = { request in
            switch request["method"] as? String {
            case "initialize": transport.reply(request)
            case "session/new": transport.reply(request, result: ["sessionId": "owned-session"])
            case "session/prompt": transport.reply(request, error: "connection closed")
            default: break
            }
        }
        let runner = GrokACPRun.start(spec, journal: journal, transport: transport)
        wait(for: [reserved, ended], timeout: 2)
        withExtendedLifetime(runner) {}
    }

    func testGrokFollowUpFailureCannotBecomeSuccess() throws {
        let ended = expectation(description: "all accepted prompts settled")
        var run: GrokACPRun?
        let (spec, journal) = try fixture(.grokACP, finished: {
            XCTAssertEqual($0, .failed(exitCode: 1))
            ended.fulfill()
        }, session: { _ in run?.send("follow-up") })
        let transport = HarnessPeer()
        var first: [String: Any]?
        transport.receive = { request in
            switch request["method"] as? String {
            case "initialize": transport.reply(request)
            case "session/new": transport.reply(request, result: ["sessionId": "owned-session"])
            case "session/prompt":
                if let first {
                    transport.reply(first, result: ["stopReason": "end_turn"])
                    transport.reply(request, error: "synthetic follow-up failure")
                } else { first = request }
            default: break
            }
        }
        run = GrokACPRun.start(spec, journal: journal, transport: transport)
        wait(for: [ended], timeout: 2)
        withExtendedLifetime(run) {}
    }

    func testCodexStopBeforeTurnReplyStillInterruptsTheTurn() throws {
        let interrupted = expectation(description: "native turn interrupted")
        let ended = expectation(description: "confirmed cancellation")
        let (spec, journal) = try fixture(.codexDaemon, finished: {
            XCTAssertEqual($0, .cancelled)
            ended.fulfill()
        })
        let transport = HarnessPeer()
        let peer = JSONRPCPeer(transport: transport)
        let runner = CodexDaemonRun(spec: spec, journal: journal, peer: peer)
        transport.receive = { request in
            if request["method"] as? String == "turn/interrupt" {
                let params = request["params"] as? [String: String]
                XCTAssertEqual(params?["turnId"], "owned-turn")
                interrupted.fulfill()
                runner.handle("turn/completed", ["threadId": "owned-thread",
                    "turn": ["id": "owned-turn", "status": "interrupted"]])
            }
        }
        runner.threadStarted(.success(["thread": ["id": "owned-thread"]]))
        runner.stop()
        runner.turnStarted(.success(["turn": ["id": "owned-turn"]]))
        wait(for: [interrupted, ended], timeout: 2)
    }

    func testClaudeSuccessfulAnswerClearsATransientAPIError() throws {
        let ended = expectation(description: "recovered turn")
        let (spec, journal) = try fixture(.claudeInteractive, finished: {
            XCTAssertEqual($0, .interrupted, "The API failure was recovered; no orderly /exit was requested")
            ended.fulfill()
        })
        let runner = ClaudeInteractiveRun(spec: spec, journal: journal, session: "synthetic",
                                         folder: spec.log.deletingLastPathComponent())
        runner.handle(entry: Data(#"""
            {"type":"assistant","isApiErrorMessage":true,"message":{"content":[{"type":"text","text":"retrying"}]}}
            """#.utf8))
        runner.handle(entry: Data(#"""
            {"type":"assistant","message":{"model":"synthetic","content":[{"type":"text","text":"recovered"}]}}
            """#.utf8))
        runner.finish(status: 0)
        wait(for: [ended], timeout: 2)
    }

    func testClaudePreservesToolResultsAndReasoningAsDistinctItems() throws {
        let reasoning = StreamJSONFormatter.items(Data(#"""
            {"type":"assistant","message":{"content":[{"type":"thinking","thinking":"visible reasoning"}]}}
            """#.utf8))
        XCTAssertEqual(reasoning.first?.kind.rawValue, "reasoning")
        XCTAssertEqual(reasoning.first?.text, "visible reasoning")
        let output = StreamJSONFormatter.items(Data(#"""
            {"type":"user","message":{"content":[{"type":"tool_result","content":[{"type":"text","text":"tool output"}]}]}}
            """#.utf8))
        XCTAssertEqual(output.first?.kind, .output)
        XCTAssertEqual(output.first?.text, "tool output")
    }
}
