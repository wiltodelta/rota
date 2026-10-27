import Foundation
@testable import RotaCore
import XCTest

final class HarnessContractTests: XCTestCase {
    private func folder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("rota-contract-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder
    }

    private func journal(_ log: URL, resuming: Bool = false, finished: @escaping (RunOutcome) -> Void = { _ in }) throws
        -> RunJournal {
        if !resuming { FileManager.default.createFile(atPath: log.path, contents: nil) }
        let output = try FileHandle(forWritingTo: log)
        try output.seekToEnd()
        return RunJournal(output: output, events: RunEvents(session: { _ in }, finished: finished),
                          transcript: try TranscriptJournal(log: log, resuming: resuming, logSize: output.offsetInFile))
    }

    func testRestartReconcilesAnIncompleteNativeMessageAndKeepsItsIdentity() throws {
        let log = try folder().appendingPathComponent("session.log")
        let first = try journal(log)
        first.text("prefix ", nativeID: "message-1")
        let restored = try journal(log, resuming: true)
        restored.reconcileText("prefix suffix", kind: .agent, nativeID: "message-1")
        restored.reconcileText("prefix suffix", kind: .agent, nativeID: "message-1")
        restored.finish(.succeeded)
        var reader = TranscriptReader()
        let messages = reader.read(log: log, finished: true).items.filter { $0.kind == .agent }
        XCTAssertEqual(messages.map(\.text), ["prefix suffix"])
        XCTAssertEqual(messages.map(\.id), [0])
        XCTAssertTrue(messages.allSatisfy(\.isComplete))
    }

    func testDurableOutputRecoveryDoesNotLaunchAgainOrDuplicateMessages() throws {
        for mode in [LaunchMode.claudeStream, .antigravityStream] {
            let directory = try folder()
            let log = directory.appendingPathComponent("session.log")
            let peer = directory.appendingPathComponent("peer")
            let count = directory.appendingPathComponent("launch-count")
            let lines: [String]
            if mode == .claudeStream {
                lines = [#"{"type":"assistant","message":{"content":[{"type":"text","text":"known"}]}}"#,
                         #"{"type":"assistant","message":{"content":[{"type":"text","text":"unseen"}]}}"#,
                         #"{"type":"result","subtype":"success"}"#]
            } else {
                lines = [#"{"event":"step_update","step_update":{"step_type":"agent_response","text_delta":"known"}}"#,
                         #"{"event":"result","result":{"status":"SUCCESS"}}"#,
                         #"{"event":"step_update","step_update":{"step_type":"agent_response","text_delta":"unseen"}}"#,
                         #"{"event":"result","result":{"status":"SUCCESS"}}"#]
            }
            let script = "#!/bin/zsh\n[[ $1 == --version ]] && { echo fixture-v1; exit 0; }\n"
                + "echo launched >> " + shellQuote(count.path) + "\n"
                + lines.map { "print -r -- " + shellQuote($0) }.joined(separator: "\n") + "\n"
            try script.write(to: peer, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: peer.path)
            var spec = LaunchSpec(executable: peer.path, prompt: "", arguments: [], workingDirectory: directory.path,
                                  environment: [:], mode: mode, timeout: nil, log: log)
            let first = try journal(log)
            let capture = try DurableStream(spec: spec, arguments: [])
            capture.process?.waitUntilExit()
            let lease = try XCTUnwrap(RunLease.read(log))
            first.withSource(lease.id + "/0") {
                if mode == .claudeStream { first.record(.agent, "known") } else { first.text("known") }
            }
            first.endText()
            spec.resume = "synthetic-session"
            spec.adopt = true
            let ended = expectation(description: "spooled run recovered")
            let control = try ProcessLauncher().launch(spec, events: RunEvents(session: { _ in }, finished: {
                XCTAssertEqual($0, .succeeded)
                ended.fulfill()
            }))
            wait(for: [ended], timeout: 3)
            withExtendedLifetime(control) {}
            var reader = TranscriptReader()
            XCTAssertEqual(reader.read(log: log, finished: true).items.filter { $0.kind == .agent }.map(\.text),
                           ["known", "unseen"])
            XCTAssertEqual(try String(contentsOf: count, encoding: .utf8), "launched\n")
        }
    }

    func testCodexRestoresEveryHistoryPageAndSteersAnExistingTurn() throws {
        let log = try folder().appendingPathComponent("session.log")
        let ended = expectation(description: "existing turn ended")
        let journal = try journal(log, finished: { XCTAssertEqual($0, .succeeded); ended.fulfill() })
        let spec = LaunchSpec(executable: "/bin/false", prompt: "new message", arguments: [],
                              workingDirectory: log.deletingLastPathComponent().path, environment: [:],
                              mode: .codexDaemon, timeout: nil, log: log, resume: "thread")
        let transport = HarnessPeer()
        let peer = JSONRPCPeer(transport: transport)
        let runner = CodexDaemonRun(spec: spec, journal: journal, peer: peer)
        var pages = 0
        transport.receive = { request in
            switch request["method"] as? String {
            case "thread/turns/list":
                pages += 1
                if pages == 1 {
                    transport.reply(request, result: ["data": [["id": "old", "status": "completed", "items": [
                        ["id": "answer-1", "type": "agentMessage", "text": "first page"]]]], "nextCursor": "page-2"])
                } else {
                    XCTAssertEqual((request["params"] as? [String: Any])?["cursor"] as? String, "page-2")
                    transport.reply(request, result: ["data": [["id": "active", "status": "inProgress", "items": []]]])
                }
            case "turn/steer":
                XCTAssertEqual((request["params"] as? [String: Any])?["expectedTurnId"] as? String, "active")
                transport.reply(request)
                runner.handle("turn/completed", ["threadId": "thread", "turn": ["id": "active", "status": "completed"]])
            default: XCTFail("Recovery must not submit another turn: \(request["method"] ?? "unknown")")
            }
        }
        runner.threadStarted(.success(["thread": ["id": "thread", "status": ["type": "active"]]]))
        wait(for: [ended], timeout: 2)
        XCTAssertEqual(pages, 2)
        XCTAssertTrue(try String(contentsOf: log, encoding: .utf8).contains("first page"))
    }

    func testGrokLoadFollowsTheExistingPromptWithoutSubmittingAnother() throws {
        let log = try folder().appendingPathComponent("session.log")
        let ended = expectation(description: "adopted prompt completed")
        let journal = try journal(log, finished: { XCTAssertEqual($0, .succeeded); ended.fulfill() })
        var spec = LaunchSpec(executable: "/bin/false", prompt: "", arguments: [],
                              workingDirectory: log.deletingLastPathComponent().path, environment: [:],
                              mode: .grokACP, timeout: nil, log: log, resume: "owned-session")
        spec.adopt = true
        let transport = HarnessPeer()
        transport.receive = { request in
            switch request["method"] as? String {
            case "initialize": transport.reply(request)
            case "session/load":
                transport.reply(request, result: ["_meta": ["x.ai/runningPromptId": "native-prompt"]])
                transport.deliver(["method": "_x.ai/session_notification", "params": ["sessionId": "owned-session",
                    "update": ["sessionUpdate": "turn_completed", "prompt_id": "native-prompt",
                               "stop_reason": "end_turn"]]])
            default: XCTFail("Recovery must not prompt: \(request["method"] ?? "unknown")")
            }
        }
        let runner = GrokACPRun.start(spec, journal: journal, transport: transport)
        wait(for: [ended], timeout: 2)
        withExtendedLifetime(runner) {}
    }

    func testNativeImageInputsPreserveTheTextAndUseOnlyVerifiedImageFiles() throws {
        let directory = try folder()
        let png = directory.appendingPathComponent("pixel.png")
        let text = directory.appendingPathComponent("example.txt")
        let encoded = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jO1sAAAAASUVORK5CYII="
        try XCTUnwrap(Data(base64Encoded: encoded)).write(to: png)
        try Data("text attachment".utf8).write(to: text)
        let message = try ChatMessage(text: "Describe", attachments: [
            .init(name: "pixel.png", path: png.path), .init(name: "example.txt", path: text.path)]).encoded()
        for mode in [LaunchMode.claudeStream, .codexDaemon, .grokACP, .antigravityStream, .claudeInteractive] {
            let blocks = HarnessInput.blocks(message, for: mode)
            XCTAssertEqual(blocks.first?["text"] as? String, message)
            XCTAssertEqual(blocks.count, mode.capabilities.images == .fileReferences ? 1 : 2)
            if mode == .codexDaemon { XCTAssertEqual(blocks.last?["path"] as? String, png.path) }
            if mode == .grokACP { XCTAssertEqual(blocks.last?["mimeType"] as? String, "image/png") }
        }
        try Data("not an image".utf8).write(to: png)
        XCTAssertEqual(HarnessInput.blocks(message, for: .claudeStream).count, 1)
    }

    func testNativeImagesUseContentMIMEAndBoundInlinePayloads() throws {
        let image = try folder().appendingPathComponent("mislabeled.jpg")
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jO1sAAAAASUVORK5CYII="
        let data = try XCTUnwrap(Data(base64Encoded: png))
        try data.write(to: image)
        let message = try ChatMessage(text: "Describe", attachments: [
            .init(name: image.lastPathComponent, path: image.path)]).encoded()
        let block = HarnessInput.blocks(message, for: .claudeStream).last
        XCTAssertEqual((block?["source"] as? [String: Any])?["media_type"] as? String, "image/png")
        try (data + Data(repeating: 0, count: 4_000_000)).write(to: image)
        XCTAssertEqual(HarnessInput.blocks(message, for: .claudeStream).count, 1,
                       "Large inline images retain file references instead of exceeding partner API limits")
    }

    func testNativeImageFormatsRespectTheProvidersSupportedTypes() throws {
        let image = try folder().appendingPathComponent("pixel.gif")
        let gif = try XCTUnwrap(Data(base64Encoded: "R0lGODlhAQABAIAAAAAAAP///yH5BAEAAAAALAAAAAABAAEAAAIBRAA7"))
        try gif.write(to: image)
        let message = try ChatMessage(text: "Describe", attachments: [
            .init(name: image.lastPathComponent, path: image.path)]).encoded()
        XCTAssertEqual(HarnessInput.blocks(message, for: .grokACP).count, 1,
                       "Grok advertises JPEG and PNG; GIF remains a file reference")
        XCTAssertEqual(HarnessInput.blocks(message, for: .claudeStream).count, 2)
        XCTAssertEqual(HarnessInput.blocks(message, for: .codexDaemon).count, 2)
        // The global palette ends at byte 19; repeat the frame before its final GIF trailer.
        try (gif.dropLast() + gif[19...]).write(to: image)
        XCTAssertEqual(HarnessInput.blocks(message, for: .codexDaemon).count, 1,
                       "Codex's image API supports non-animated GIFs")
    }

    func testGrokCatalogUsesEachModelsAdvertisedEfforts() throws {
        let result = try XCTUnwrap(GrokCatalog.parse(["currentModelId": "flexible", "availableModels": [
            ["modelId": "flexible", "name": "Flexible", "_meta": ["supportsReasoningEffort": true,
                "reasoningEfforts": [["id": "minimal"], ["value": "high"]]]],
            ["modelId": "fixed", "_meta": ["supportsReasoningEffort": false, "reasoningEfforts": [["id": "high"]]]],
        ]]))
        XCTAssertEqual(result.first?.efforts, ["minimal", "high"])
        XCTAssertEqual(result.last?.efforts, [])
        XCTAssertEqual(result.first?.isDefault, true)
    }

    func testReasoningIsPreservedWithoutBecomingTheAnswer() {
        let thoughts = TranscriptItem(id: 1, kind: .reasoning, text: "visible reasoning")
        let answer = TranscriptItem(id: 2, kind: .agent, text: "answer")
        let turn = TranscriptTurn.group([thoughts, answer]).first
        XCTAssertEqual(turn?.work, [thoughts])
        XCTAssertEqual(turn?.answer, [answer])
        XCTAssertEqual(Transcript.parse(RunJournal.readable(.reasoning, thoughts.text)).first?.kind, .reasoning)
    }

    func testNativeHistoryAdaptersPreserveExposedReasoningAndToolOutput() throws {
        let payloads: [(Harness, String)] = [
            (.claude, #"{"type":"assistant","message":{"content":[{"type":"thinking","thinking":"reasoning"}]}}"#),
            (.codex, #"""
                {"type":"response_item","payload":{"type":"reasoning","summary":[{"type":"summary_text","text":"reasoning"}]}}
                """#),
            (.antigravity, #"""
                {"type":"PLANNER_RESPONSE","status":"DONE","step_index":1,"thinking":"reasoning","content":"answer"}
                """#),
        ]
        for (harness, json) in payloads {
            let events = try NativeTranscript.events(Data(json.utf8), harness: harness)
            XCTAssertTrue(events.contains(.item(.reasoning, "reasoning")))
        }
        let grok = #"""
            {"method":"session/update","params":{"update":{"sessionUpdate":"agent_thought_chunk","content":{"type":"text","text":"reasoning"}}}}
            """#
        XCTAssertEqual(try NativeTranscript.events(Data(grok.utf8), harness: .grok),
                       [.chunk("reasoning", kind: .reasoning)])
        let codex = #"{"type":"response_item","payload":{"type":"function_call_output","output":"output"}}"#
        XCTAssertEqual(try NativeTranscript.events(Data(codex.utf8), harness: .codex), [.item(.output, "output")])
    }

    func testAntigravityNativeRevisionsDoNotRepeatCompletedSteps() {
        var decoder = AntigravityTranscript()
        let row: [String: Any] = ["type": "PLANNER_RESPONSE", "status": "DONE", "step_index": 1,
                                  "thinking": "reasoning", "content": "answer"]
        XCTAssertEqual(decoder.read(row), [.item(.reasoning, "reasoning"), .item(.agent, "answer"), .state(.waiting)])
        XCTAssertTrue(decoder.read(row).isEmpty)
    }

    func testAntigravityTerminalRecoveryRemembersPreviouslyCompletedSteps() throws {
        let file = try folder().appendingPathComponent("native.jsonl")
        let old = #"{"type":"PLANNER_RESPONSE","status":"DONE","step_index":1,"content":"old"}"# + "\n"
        try Data(old.utf8).write(to: file)
        let checkpoint = UInt64(old.utf8.count)
        let next = #"{"type":"PLANNER_RESPONSE","status":"DONE","step_index":2,"content":"new"}"# + "\n"
        try Data((old + old + next).utf8).write(to: file)
        var transcript = try NativeTranscript(url: file, harness: .antigravity, offset: checkpoint)
        XCTAssertEqual(try transcript.read(), [.item(.agent, "new"), .state(.waiting)])
        let wrapped = #"""
            {"type":"USER_INPUT","status":"DONE","content":"<USER_REQUEST>\nActual question\n</USER_REQUEST>\n<ADDITIONAL_METADATA>\nPrivate runtime metadata\n</ADDITIONAL_METADATA>"}
            """#
        XCTAssertEqual(try NativeTranscript.events(Data(wrapped.utf8), harness: .antigravity),
                       [.item(.user, "Actual question"), .state(.working)])
    }

    func testHistoricalProvenanceDistinguishesCLIAndServingProcess() throws {
        var record = RunRecord(routineID: "synthetic", trigger: .manual, harness: .codex,
                               startedAt: Date(), outcome: .running)
        record.launchMode = .codexDaemon
        record.cliVersion = "codex-cli 1.2.3"
        record.serverVersion = "rota/1.2.4 (Mac OS 27.0.1; arm64)"
        XCTAssertNotNil(record.compatibilityNotice)
        let decoded = try JSONDecoder().decode(RunRecord.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(decoded, record)
        record.serverVersion = "rota/1.2.3 (Mac OS 27.0.1; arm64)"
        XCTAssertNil(record.compatibilityNotice, "The OS version is not the serving process version")
        record.serverVersion = "unreported"
        XCTAssertNil(record.compatibilityNotice, "An absent version is unknown, not proof of a mismatch")
    }
}
