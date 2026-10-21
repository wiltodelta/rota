@testable import RotaCore
import XCTest

final class MarkdownImageTests: XCTestCase {
    func testInlineImagesRetainSurroundingTextAndIgnoreCode() {
        let source = "Before ![Proof](/tmp/example.png) after\n\n```md\n![Code](/tmp/code.png)\n```"
        let blocks = MarkdownBlock.parse(source)
        let content = MarkdownImageReference.content("Before ![Proof](/tmp/example.png) after")
        XCTAssertEqual(content.count, 3)
        XCTAssertEqual(MarkdownImageReference.references(in: blocks).map(\.url.path), ["/tmp/example.png"])
    }

    func testCopiesRemainAvailableAfterTheOriginalDisappears() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = folder.appendingPathComponent("proof.png")
        try Data("synthetic image bytes".utf8).write(to: original)
        let log = folder.appendingPathComponent("session.log")
        let store = SessionImageStore(log: log, workingDirectory: folder)
        let reference = MarkdownImageReference(url: URL(string: "proof.png")!, alt: "Proof")
        try store.capture([reference])
        let saved = try XCTUnwrap(store.archived(reference.url))
        XCTAssertNotEqual(saved, original)
        XCTAssertEqual(try Data(contentsOf: saved), try Data(contentsOf: original))
        try store.capture([reference])
        XCTAssertEqual(store.archived(reference.url), saved, "A repeated reference reuses the session copy")
        try FileManager.default.removeItem(at: original)
        XCTAssertEqual(try Data(contentsOf: saved), Data("synthetic image bytes".utf8))
    }
    func testReusedImagePathsKeepEachMessagesOwnVersion() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("screenshot.png")
        let reference = MarkdownImageReference(url: source, alt: "Proof")
        let store = SessionImageStore(log: folder.appendingPathComponent("session.log"))
        for itemID in [1, 2] {
            try Data("version \(itemID)".utf8).write(to: source)
            try store.capture([reference], itemID: itemID)
        }
        for itemID in [1, 2] {
            let archived = try XCTUnwrap(store.archived(source, itemID: itemID))
            XCTAssertEqual(try Data(contentsOf: archived), Data("version \(itemID)".utf8))
        }
    }

}
