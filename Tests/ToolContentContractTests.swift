import Foundation
@testable import RotaCore
import XCTest

/// Synthetic protocol examples, not copies of personal sessions. Sources and boundaries:
/// docs/harness-output-contract.md. These assertions run through native adapters as well as the shared decoder.
final class ToolContentContractTests: XCTestCase {
    private let future: [String: Any] = [
        "type": "future_result", "title": "Inspection result", "text": "Readable summary",
        "mimeType": "application/octet-stream", "uri": "https://example.com/result",
        "data": "PRIVATE_BINARY", "_meta": ["private": "PRIVATE_METADATA"]]
    private let notice = "Couldn't display tool content (future_result).\nInspection result\n"
        + "application/octet-stream\nhttps://example.com/result\nReadable summary"

    func testUnknownToolContentSurvivesEveryBlockAdapter() throws {
        let blocks: [[String: Any]] = [["type": "text", "text": "Before"], future,
                                      ["type": "text", "text": "After"]]
        let expected = "Before\n" + notice + "\nAfter"
        let claude: [String: Any] = ["type": "user", "message": ["content": [
            ["type": "tool_result", "content": blocks]]]]
        let data = try JSONSerialization.data(withJSONObject: claude)
        XCTAssertEqual(StreamJSONFormatter.items(data).map(\.text), [expected])
        XCTAssertEqual(try NativeTranscript.events(data, harness: .claude), [.item(.output, expected)])
        for type in ["function_call_output", "custom_tool_call_output"] {
            let row: [String: Any] = ["type": "response_item", "payload": ["type": type, "output": blocks]]
            XCTAssertEqual(try NativeTranscript.events(JSONSerialization.data(withJSONObject: row), harness: .codex),
                           [.item(.output, expected)])
        }
        XCTAssertEqual(CodexItemOutput.entries(["type": "mcpToolCall", "result": ["content": blocks]])
            .map(\.text), ["Before", notice, "After"])
        XCTAssertEqual(CodexItemOutput.entries(["type": "dynamicToolCall", "contentItems": blocks])
            .map(\.text), ["Before", notice, "After"])
        XCTAssertEqual(CodexItemOutput.entries(["type": "functionCallOutput", "output": blocks])
            .map(\.text), [expected])
        XCTAssertEqual(CodexItemOutput.entries(["type": "functionCallOutput", "output": "Literal result"])
            .map(\.text), ["Literal result"])
        for method in ["session/update", "_x.ai/session/update"] {
            let row: [String: Any] = ["method": method, "params": ["update": [
                "sessionUpdate": "tool_call_update", "content": blocks.map { ["type": "content", "content": $0] }]]]
            XCTAssertEqual(try NativeTranscript.events(JSONSerialization.data(withJSONObject: row), harness: .grok),
                           [.item(.output, "Before"), .item(.output, notice), .item(.output, "After")])
        }
    }

    func testResourceLinksKeepTheirDisplayMetadataAsLiteralText() {
        let link: [String: Any] = ["type": "resource_link", "name": "report.txt", "title": "Report",
                                  "uri": "https://example.com/report", "mimeType": "text/plain"]
        let expected = "Report\nreport.txt\ntext/plain\nhttps://example.com/report"
        XCTAssertEqual(ToolOutput.content([link]), expected)
        XCTAssertEqual(GrokToolOutput.text(["type": "content", "content": link]), expected)
        XCTAssertEqual(ToolOutput.content([["type": "resource_link"]]),
                       "Couldn't display tool content (resource_link).")
    }

    func testUnsupportedBinaryResultsExposeMetadataWithoutTheirBytes() {
        let binary: [String: Any] = ["type": "resource", "resource": [
            "uri": "file:///tmp/synthetic-report.pdf", "mimeType": "application/pdf", "blob": "PRIVATE_BINARY"]]
        XCTAssertEqual(ToolOutput.content([binary]),
                       "Couldn't display tool content (resource).\napplication/pdf\nfile:///tmp/synthetic-report.pdf")
        XCTAssertEqual(ToolOutput.content([["type": "audio", "mimeType": "audio/wav", "data": "PRIVATE_BINARY"]]),
                       "Couldn't display tool content (audio).\naudio/wav")
        XCTAssertEqual(ToolOutput.content([["type": "future_result", "uri": "data:audio/wav;base64,PRIVATE_BINARY"]]),
                       "Couldn't display tool content (future_result).")
        XCTAssertEqual(GrokToolOutput.text(["type": "future_wrapper", "text": "Available details"]),
                       "Couldn't display tool content (future_wrapper).\nAvailable details")
    }

    func testACPImageURIAndUnreadableImageHaveVisibleResults() {
        let url = "file:///tmp/synthetic-tool-image.png"
        let result = ToolOutput.content([["type": "image", "uri": url]]) ?? ""
        XCTAssertEqual(ToolOutput.decode(result)?.parts, [.init(kind: .image, text: url, path: "Tool image")])
        XCTAssertEqual(ToolOutput.content([["type": "image", "source": ["data": "PRIVATE_BINARY"]]]),
                       "Couldn't display tool content (image).")
    }

    func testBothClaudeHostsAndCodexPersistUnsupportedContentOnce() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("rota-contract-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let row: [String: Any] = ["type": "user", "message": ["content": [
            ["type": "tool_result", "content": [future]]]]]
        let data = try JSONSerialization.data(withJSONObject: row)
        for (index, mode) in [LaunchMode.claudeStream, .claudeInteractive, .codexDaemon].enumerated() {
            let log = folder.appendingPathComponent("session-\(index).log")
            FileManager.default.createFile(atPath: log.path, contents: nil)
            let spec = LaunchSpec(executable: "/bin/false", prompt: "Inspect", arguments: [],
                workingDirectory: folder.path, environment: [:], mode: mode, timeout: nil, log: log,
                resume: mode == .codexDaemon ? "thread" : nil)
            let journal = RunJournal(output: try FileHandle(forWritingTo: log),
                events: RunEvents(session: { _ in }, finished: { _ in }),
                transcript: try TranscriptJournal(log: log, resuming: false, logSize: 0))
            switch mode {
            case .claudeStream: ClaudeStreamRun(spec: spec, journal: journal).handle(lossyUTF8(data))
            case .claudeInteractive:
                ClaudeInteractiveRun(spec: spec, journal: journal, session: "synthetic", folder: folder)
                    .handle(entry: data)
            case .codexDaemon:
                let run = CodexDaemonRun(spec: spec, journal: journal)
                for _ in 0..<2 {
                    run.handle("item/completed", ["threadId": "thread", "item": ["type": "mcpToolCall", "id": "call",
                                                        "result": ["content": [future]]]])
                }
            default: XCTFail("Unexpected test mode")
            }
            journal.finish(.succeeded)
            var reader = TranscriptReader()
            let result = reader.read(log: log, finished: true)
            XCTAssertTrue(result.structured)
            XCTAssertNil(result.problem)
            XCTAssertEqual(result.items.filter { $0.kind == .output }.map(\.text), [notice], "\(mode)")
            for file in [log, TranscriptReader.journalURL(for: log)] {
                XCTAssertFalse(try String(contentsOf: file, encoding: .utf8).contains("PRIVATE_"))
            }
        }
    }
}
