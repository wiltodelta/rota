@testable import RotaCore
import AppKit
import XCTest

final class ChatAttachmentTests: XCTestCase {
    private var folder: URL!

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("rota-attachments-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: folder) }

    func testNativeImageBlocksContainTheActualBytesAndFilesRemainReferences() throws {
        let imageURL = folder.appendingPathComponent("sample.png")
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.setColor(.red, atX: 0, y: 0)
        let bytes = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try bytes.write(to: imageURL)
        let documentURL = folder.appendingPathComponent("report.txt")
        try Data("report marker".utf8).write(to: documentURL)
        let message = ChatMessage(text: "Compare these",
                                  attachments: try [imageURL, documentURL].map(ChatAttachment.inspect))
        let wire = try XCTUnwrap(JSONSerialization.jsonObject(with: ClaudeStreamRun.userMessage(message))
                                 as? [String: Any])
        let content = try XCTUnwrap((wire["message"] as? [String: Any])?["content"] as? [[String: Any]])
        XCTAssertEqual(content.count, 2)
        XCTAssertTrue(try XCTUnwrap(content[0]["text"] as? String).contains(documentURL.path))
        let imageBlock = try XCTUnwrap(content.first { $0["type"] as? String == "image" })
        let source = try XCTUnwrap(imageBlock["source"] as? [String: String])
        XCTAssertEqual(source["media_type"], "image/png")
        XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(source["data"])), bytes)
        let codex = message.codexInput()
        let codexImage = try XCTUnwrap(codex.first { $0["type"] as? String == "localImage" })
        XCTAssertEqual(codexImage["path"] as? String, imageURL.path)
        XCTAssertTrue(message.fileReferenceText.contains(imageURL.path))
        let nativeACP = try message.acpContent(images: true)
        let acpImage = try XCTUnwrap(nativeACP.first { $0["type"] as? String == "image" })
        XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(acpImage["data"] as? String)), bytes)
        XCTAssertTrue(try XCTUnwrap(message.acpContent(images: false)[0]["text"] as? String).contains(imageURL.path))
    }

    func testRetentionCopiesBytesAndSurvivesOriginalRemovalIncludingSymlinks() throws {
        let source = folder.appendingPathComponent("original.txt")
        try Data("unchanged evidence".utf8).write(to: source)
        let link = folder.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        let message = ChatMessage(text: "", attachments: [try ChatAttachment.inspect(link)])
        let log = folder.appendingPathComponent("session.log")
        let retained = try ChatAttachmentStore.retain(message, log: log, messageID: "message-1")
        let copy = try XCTUnwrap(retained.attachments.first)
        XCTAssertNotEqual(copy.url, link)
        XCTAssertEqual(copy.id, message.attachments[0].id)
        try FileManager.default.removeItem(at: source)
        XCTAssertEqual(try String(contentsOf: copy.url, encoding: .utf8), "unchanged evidence")
    }

    func testAttachmentOnlyMessageAndJournalRoundTrip() throws {
        let file = folder.appendingPathComponent("report.txt")
        try Data("sample".utf8).write(to: file)
        let attachment = try ChatAttachment.inspect(file)
        let log = folder.appendingPathComponent("session.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        var spec = LaunchSpec(executable: "/bin/echo", prompt: "", arguments: [], workingDirectory: folder.path,
                              environment: [:], mode: .claudeStream, timeout: nil, log: log)
        spec.attachments = [attachment]
        let journal = try RunJournal(output: FileHandle(forWritingTo: log),
            events: RunEvents(session: { _ in }, finished: { _ in }), spec: spec, legacy: nil)
        journal.confirmUser(spec.chatMessage.claudeText)
        journal.finish(.succeeded)
        let reader = SessionEventReader()
        XCTAssertTrue(try reader.read(from: SessionEventReader.file(for: log)))
        let user = try XCTUnwrap(reader.transcript.items.first { $0.kind == .user })
        XCTAssertEqual(user.text, "")
        XCTAssertEqual(user.attachments, [attachment])
        XCTAssertEqual(user.delivery, .accepted)
        XCTAssertFalse(spec.chatMessage.codexInput().isEmpty)
    }

    func testRejectsMissingFilesFoldersAndTooManyAttachmentsBeforeRetaining() throws {
        XCTAssertThrowsError(try ChatAttachment.inspect(folder))
        XCTAssertThrowsError(try ChatAttachment.inspect(folder.appendingPathComponent("missing")))
        let file = folder.appendingPathComponent("report.txt")
        try Data("sample".utf8).write(to: file)
        let attachment = try ChatAttachment.inspect(file)
        let message = ChatMessage(text: "", attachments: Array(repeating: attachment, count: 11))
        XCTAssertThrowsError(try ChatAttachmentStore.retain(message, log: folder.appendingPathComponent("session.log"),
                                                          messageID: "too-many"))
        let retainedFolder = folder.appendingPathComponent("session.attachments")
        XCTAssertFalse(FileManager.default.fileExists(atPath: retainedFolder.path))
    }

    func testRemovingHistoryAlsoRemovesRetainedCopiesWithoutDeletingOriginals() throws {
        let source = folder.appendingPathComponent("report.txt")
        try Data("sample".utf8).write(to: source)
        let location = StorageLocation(root: folder.appendingPathComponent("data"),
                                       logs: folder.appendingPathComponent("logs"))
        let history = RunHistory(location: location)
        var record = RunRecord(routineID: "sample", trigger: .manual, harness: .codex,
                               startedAt: Date(timeIntervalSince1970: 0), outcome: .succeeded)
        let log = history.logFile(for: record)
        let message = ChatMessage(text: "", attachments: [try ChatAttachment.inspect(source)])
        let retained = try ChatAttachmentStore.retain(message,
                                                      log: log, messageID: "message")
        record.logPath = log.path
        try history.upsert(record)
        let copy = try XCTUnwrap(retained.attachments.first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.url.path))
        history.removeAll(for: "sample")
        XCTAssertFalse(FileManager.default.fileExists(atPath: copy.url.path))
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), "sample")
    }

    func testMisnamedNonImageIsNotSentAsAnImage() throws {
        let file = folder.appendingPathComponent("report.png")
        try Data("plain text".utf8).write(to: file)
        let attachment = try ChatAttachment.inspect(file)
        XCTAssertFalse(attachment.isImage)
    }
}
