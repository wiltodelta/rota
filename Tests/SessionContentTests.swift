import AppKit
import Foundation
import UniformTypeIdentifiers
@testable import RotaCore
import XCTest

final class SessionContentTests: XCTestCase {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("rota-content-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func fixture(_ mode: LaunchMode) throws -> (LaunchSpec, RunJournal) {
        let root = try folder()
        let log = root.appendingPathComponent("session.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let spec = LaunchSpec(executable: "/bin/false", prompt: "Inspect", arguments: [],
                              workingDirectory: root.path, environment: ["HOME": root.path], mode: mode,
                              timeout: nil, log: log, resume: mode == .codexDaemon ? "thread" : nil)
        return (spec, RunJournal(output: try FileHandle(forWritingTo: log),
                                events: RunEvents(session: { _ in }, finished: { _ in }),
                                transcript: try TranscriptJournal(log: log, resuming: false, logSize: 0),
                                images: SessionImageStore(log: log)))
    }

    private func items(_ spec: LaunchSpec, _ journal: RunJournal) -> [TranscriptItem] {
        journal.finish(.succeeded)
        var reader = TranscriptReader()
        return reader.read(log: spec.log, finished: true).items
    }

    func testCodexTerminalRetainsArrayOutputAndItsNeighbors() throws {
        for type in ["function_call_output", "custom_tool_call_output"] {
            let row: [String: Any] = ["type": "response_item", "payload": ["type": type, "output": [
                ["type": "input_text", "text": "first"], ["type": "future_kind"],
                ["type": "input_text", "text": "last"]]]]
            XCTAssertEqual(try NativeTranscript.events(JSONSerialization.data(withJSONObject: row), harness: .codex),
                           [.item(.output, "first\nlast")])
        }
    }

    func testClaudeAndGrokToolImagesRetainTextAndOrder() throws {
        let image: [String: Any] = ["type": "image", "source": ["type": "base64", "media_type": "image/png",
                                                                 "data": "aW1hZ2U="]]
        let row: [String: Any] = ["type": "user", "message": ["content": [["type": "tool_result", "content": [
            ["type": "text", "text": "Before"], image, ["type": "text", "text": "After"]]]]]]
        let item = try XCTUnwrap(StreamJSONFormatter.items(JSONSerialization.data(withJSONObject: row)).first)
        let output = try XCTUnwrap(ToolOutput.decode(item.text))
        XCTAssertEqual(output.parts.map(\.kind), [.text, .image, .text])
        XCTAssertEqual(output.parts.map(\.text), ["Before", "data:image/png;base64,aW1hZ2U=", "After"])
        let grok = try XCTUnwrap(GrokToolOutput.text(["type": "content", "content": ["type": "image",
                                                              "mimeType": "image/png", "data": "aW1hZ2U="]]))
        XCTAssertEqual(ToolOutput.decode(grok)?.parts.first?.text, output.parts[1].text)
    }

    func testInlineToolImageIsSavedWithoutBase64InTheJournal() throws {
        let (spec, journal) = try fixture(.claudeStream)
        journal.record(.output, ToolOutput.image("data:image/png;base64,aW1hZ2U="))
        let item = try XCTUnwrap(items(spec, journal).first { $0.kind == .output })
        let part = try XCTUnwrap(ToolOutput.decode(item.text)?.parts.first)
        let url = try XCTUnwrap(URL(string: part.text))
        XCTAssertTrue(url.isFileURL)
        XCTAssertEqual(try Data(contentsOf: url), Data("image".utf8))
        XCTAssertFalse(item.text.contains("aW1hZ2U="))
        XCTAssertFalse(try String(contentsOf: spec.log, encoding: .utf8).contains("aW1hZ2U="))
    }

    func testInlineToolImagesKeepTheirNativeFileTypeForOpening() throws {
        for format in [NSBitmapImageRep.FileType.png, .jpeg] {
            let (spec, journal) = try fixture(.claudeStream)
            let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 4, pixelsHigh: 4,
                bitsPerSample: 8, samplesPerPixel: 3, hasAlpha: false, isPlanar: false,
                colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
            let data = try XCTUnwrap(bitmap.representation(using: format, properties: [:]))
            // Provider MIME labels cannot override the format of the actual bytes.
            journal.record(.output, ToolOutput.image("data:image/unknown;base64," + data.base64EncodedString()))
            let item = try XCTUnwrap(items(spec, journal).first { $0.kind == .output })
            let part = try XCTUnwrap(ToolOutput.decode(item.text)?.parts.first)
            let file = try XCTUnwrap(URL(string: part.text))
            let type = try XCTUnwrap(file.resourceValues(forKeys: [.contentTypeKey]).contentType)
            XCTAssertTrue(type.conforms(to: .image), "Saved images must open as images rather than generic data")
            XCTAssertEqual(type, format == .png ? .png : .jpeg)
            XCTAssertEqual(try Data(contentsOf: file), data)
        }
    }

    func testCodexResultsSurviveReplayWithoutDuplicates() throws {
        let (spec, journal) = try fixture(.codexDaemon)
        let run = CodexDaemonRun(spec: spec, journal: journal)
        let file = URL(fileURLWithPath: spec.workingDirectory).appendingPathComponent("generated.png")
        try Data("image".utf8).write(to: file)
        let native: [[String: Any]] = [
            ["id": "edit", "type": "fileChange", "changes": [["path": "sample.txt", "diff": "-before\n+after"]]],
            ["id": "view", "type": "imageView", "path": file.path],
            ["id": "generate", "type": "imageGeneration", "savedPath": file.path, "status": "completed"],
            ["id": "mcp", "type": "mcpToolCall", "result": ["content": [
                ["type": "text", "text": "Screenshot"], ["type": "image", "mimeType": "image/png",
                  "data": "aW1hZ2U="]]]],
            ["id": "child-start", "type": "subAgentActivity", "kind": "started", "agentPath": "/root/review"],
            ["id": "child-end", "type": "subAgentActivity", "kind": "completed", "agentPath": "/root/review"],
            ["id": "collab", "type": "collabAgentToolCall", "agentsStates": ["child": ["status": "errored",

                "message": "Private child transcript"]]]]
        for _ in 0..<2 {
            for item in native {
                run.handle("item/started", ["threadId": "thread", "item": item])
                run.handle("item/completed", ["threadId": "thread", "item": item])
            }
        }
        let recorded = items(spec, journal)
        let results = recorded.filter { $0.kind == .output }
        XCTAssertEqual(results.count, 5)
        XCTAssertEqual(ToolOutput.decode(try XCTUnwrap(results.first).text)?.parts,
                       [.init(kind: .diff, text: "-before\n+after", path: "sample.txt")])
        XCTAssertEqual(results.filter { ToolOutput.decode($0.text)?.parts.first?.kind == .image }.count, 3)
        try FileManager.default.removeItem(at: file)
        for item in results {
            for part in ToolOutput.decode(item.text)?.parts ?? [] where part.kind == .image {
                let url = try XCTUnwrap(URL(string: part.text))
                let archived = SessionImageStore(log: spec.log).archived(url, itemID: item.id) ?? url
                XCTAssertEqual(try Data(contentsOf: archived), Data("image".utf8))
            }
        }
        XCTAssertTrue(recorded.contains { $0.kind == .status && $0.text == "Agent /root/review: working" })
        XCTAssertTrue(recorded.contains { $0.kind == .status && $0.text == "Agent /root/review: completed" })
        XCTAssertTrue(recorded.contains { $0.kind == .status && $0.text == "Agent child: failed" })
        XCTAssertFalse(recorded.contains { $0.text.contains("Private child transcript") })
    }

    func testAntigravityErrorAfterActiveToolIsVisibleOnce() throws {
        var stream = AntigravityStream()
        func row(_ state: String) throws -> Data {
            try JSONSerialization.data(withJSONObject: ["event": "step_update", "step_update": [
                "step_type": "tool", "step_index": 2, "state": state, "tool_name": "Inspect",
                "tool_info": ["error": ["message": "Tool failed"]]]])
        }
        _ = stream.events(try row("ACTIVE"))
        XCTAssertEqual(stream.events(try row("ERROR")), [.item(.error, "Tool failed", step: 2)])
        let archived: [String: Any] = ["type": "ERROR_MESSAGE", "status": "DONE", "step_index": 3,
                                      "error": "Native failure"]
        var decoder = AntigravityTranscript()
        XCTAssertEqual(decoder.read(archived), [.item(.error, "Native failure")])
        XCTAssertEqual(decoder.read(archived), [])
        XCTAssertEqual(AntigravityTranscript.events(["type": "GENERIC", "status": "ERROR", "error": "Failed",
                                                     "content": "Diagnostic output"]),
                       [.item(.error, "Failed\nDiagnostic output")])
    }

    func testAntigravityArchiveOnlyErrorsReachTheJournal() throws {
        let (spec, journal) = try fixture(.antigravityStream)
        let run = AntigravityRun(spec: spec, journal: journal)
        let session = UUID().uuidString
        let archive = try XCTUnwrap(AntigravityQuestionArchive(session: session,
            home: URL(fileURLWithPath: spec.workingDirectory)))
        try FileManager.default.createDirectory(at: archive.file.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        let row: [String: Any] = ["type": "ERROR_MESSAGE", "status": "DONE", "step_index": 3,
                                  "error": "Native failure"]
        try (JSONSerialization.data(withJSONObject: row) + Data([10])).write(to: archive.file)
        run.handle(try JSONSerialization.data(withJSONObject: ["event": "init", "conversation_id": session]))
        run.handle(try JSONSerialization.data(withJSONObject: ["event": "result",
                                                              "result": ["status": "SUCCESS"]]))
        var reader = TranscriptReader()
        XCTAssertEqual(reader.read(log: spec.log, finished: false).items.filter { $0.kind == .error }.map(\.text),
                       ["Native failure"])
        run.handle(try JSONSerialization.data(withJSONObject: ["event": "result", "result": [
            "status": "ERROR", "error": "Native failure"]]))
        XCTAssertEqual(items(spec, journal).filter { $0.kind == .error }.map(\.text), ["Native failure"])
    }

    func testSubagentSummariesUseNativeLifecycleWithoutChildMessages() throws {
        var stream = AntigravityStream()
        let row: [String: Any] = ["event": "step_update", "step_update": ["step_type": "subagent",
            "state": "DONE", "subagent_info": ["subagents": [["conversation_id": "child", "role": "Reviewer",
                "initial_prompt": "Private child instructions"]]]]]
        let data = try JSONSerialization.data(withJSONObject: row)
        XCTAssertEqual(stream.events(data), [.item(.status, "Agent Reviewer: started")])
        XCTAssertEqual(stream.events(data), [])
        for (kind, status) in [("subagent_spawned", "working"), ("subagent_finished", "completed")] {
            let update: [String: Any] = ["sessionUpdate": kind, "subagent_id": "child",
                                         "output": "Private child answer", "status": "completed"]
            let native: [String: Any] = ["method": "_x.ai/session/update", "params": ["update": update]]
            XCTAssertEqual(try NativeTranscript.events(JSONSerialization.data(withJSONObject: native), harness: .grok),
                           [.item(.status, "Agent child: " + status)])
        }
        XCTAssertEqual(SubagentStatus.grok(["sessionUpdate": "subagent_finished", "subagent_id": "child",
                                            "status": "failed"]), "Agent child: failed")
    }

    func testCompressedCodexFollowsNativeExpansionAndKeepsItsCheckpoint() throws {
        let home = try folder()
        let session = UUID().uuidString.lowercased()
        let archive = home.appendingPathComponent(".codex/archived_sessions")
        let active = home.appendingPathComponent(".codex/sessions/2026/10/30")
        for path in [archive, active] {
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        }
        let compressed = archive.appendingPathComponent("rollout-2026-10-29T12-00-00-\(session).jsonl.zst")
        try Data("owned compressed fixture".utf8).write(to: compressed)
        XCTAssertEqual(NativeTranscript.locate(.codex, session: session, home: home)?.resolvingSymlinksInPath(),
                       compressed.resolvingSymlinksInPath())
        let since = try Date("2026-10-30T12:00:00.000Z",
                             strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true))
        var transcript = try NativeTranscript(url: compressed, harness: .codex, since: since, home: home)
        XCTAssertEqual(try transcript.read(), [])
        let expanded = active.appendingPathComponent(compressed.deletingPathExtension().lastPathComponent)
        let old = #"""
        {"timestamp":"2026-10-29T12:00:00.000Z","type":"response_item",
        "payload":{"type":"message","role":"assistant","content":[{"text":"Old answer"}]}}
        """#.replacingOccurrences(of: "\n", with: "")
        let new = old.replacingOccurrences(of: "2026-10-29", with: "2026-10-30")
            .replacingOccurrences(of: "Old answer", with: "New answer")
        try Data((old + "\n" + new + "\n").utf8).write(to: expanded)
        XCTAssertEqual(try transcript.read(), [.item(.agent, "New answer")])
        XCTAssertEqual(transcript.url.resolvingSymlinksInPath(), expanded.resolvingSymlinksInPath())
        XCTAssertEqual(NativeTranscript.locate(.codex, session: session, home: home)?.resolvingSymlinksInPath(),
                       expanded.resolvingSymlinksInPath())
        var restored = try NativeTranscript(url: expanded, harness: .codex, offset: transcript.checkpoint,
                                             since: transcript.since, home: home)
        XCTAssertEqual(try restored.read(), [])
        let file = try FileHandle(forWritingTo: expanded)
        try file.seekToEnd()
        try file.write(contentsOf: Data((new.replacingOccurrences(of: "New answer", with: "Next answer") + "\n").utf8))
        try file.close()
        XCTAssertEqual(try restored.read(), [.item(.agent, "Next answer")])
    }
}
