@testable import Rota
import AppKit
import RotaCore
import XCTest

@MainActor
final class TranscriptSelectionTests: XCTestCase {
    override func setUp() async throws {
        _ = NSApplication.shared
    }

    private func view(_ document: NSAttributedString) -> TranscriptScrollView {
        let view = TranscriptScrollView()
        view.frame = NSRect(x: 0, y: 0, width: 520, height: 300)
        view.update(document)
        return view
    }

    func testSelectionSpansMarkdownAndMultipleMessagesAndCopiesExactly() throws {
        let log = """
            \(Transcript.userLines("First user message"))
            First paragraph with **bold**.

            - First item
            - Second item

            ```swift
            let message = "Привет"
            ```
            \(Transcript.userLines("Second user message"))
            Second response.
            """
        let record = RunRecord(routineID: "preview", trigger: .manual, harness: .codex,
                               startedAt: Date(timeIntervalSince1970: 0), outcome: .succeeded)
        let style = TranscriptStyle(family: "", codeFamily: "", size: 14)
        let document = TranscriptDocument(style: style).make(items: Transcript.parse(log), record: record,
                                                            running: false, activity: [:])
        let text = document.string as NSString
        let start = text.range(of: "First paragraph").location
        let end = NSMaxRange(text.range(of: "Second response."))
        let selection = NSRange(location: start, length: end - start)
        let preview = view(document)
        let window = NSWindow(contentRect: preview.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = preview
        let native = preview.transcript
        XCTAssertTrue(window.makeFirstResponder(native))
        native.setSelectedRange(selection)
        let expected = text.substring(with: selection)
        XCTAssertTrue(expected.contains("First paragraph with bold.\n"))
        XCTAssertTrue(expected.contains("• First item\n• Second item\n"))
        XCTAssertTrue(expected.contains("let message = \"Привет\""))
        XCTAssertTrue(expected.contains("Second user message"))
        XCTAssertEqual(native.selectedRange(), selection)
        XCTAssertFalse(native.isEditable)
        XCTAssertTrue(native.isSelectable)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.clearContents() }
        XCTAssertEqual(native.string, document.string)
        XCTAssertTrue(native.writeSelection(to: pasteboard, types: native.writablePasteboardTypes))
        XCTAssertEqual(pasteboard.string(forType: .string), expected)
        XCTAssertFalse(document.string.contains("Copy Code"))
        XCTAssertFalse(document.string.contains("Copy answer"))
    }

    func testStreamingAppendKeepsSelectionWithoutSelectingNewText() {
        let old = "Header\nFirst line\nSecond line"
        let preview = view(NSAttributedString(string: old))
        let selection = (old as NSString).range(of: "First line\nSecond line")
        preview.transcript.setSelectedRange(selection)
        preview.update(NSAttributedString(string: old + "\nA new answer"))
        XCTAssertEqual(preview.transcript.selectedRange(), selection)
        XCTAssertEqual((preview.transcript.string as NSString).substring(with: selection), "First line\nSecond line")
    }

    func testInsertedActivityMovesSelectionAndPreservesUnicode() {
        let old = "You\nПривет 𠀀\nSecond message"
        let preview = view(NSAttributedString(string: old))
        let selected = "Привет 𠀀\nSecond message"
        let selection = (old as NSString).range(of: selected)
        preview.transcript.setSelectedRange(selection)
        let added = "Expanded activity\n"
        preview.update(NSAttributedString(string: added + old))
        let adjusted = preview.transcript.selectedRange()
        XCTAssertEqual(adjusted.location, selection.location + added.utf16.count)
        XCTAssertEqual((preview.transcript.string as NSString).substring(with: adjusted), selected)
    }

    func testFontChangeAndUnchangedRefreshPreserveSelection() {
        let text = "One\nTwo\nThree"
        let document = NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 14)])
        let preview = view(document)
        let selection = (text as NSString).range(of: "Two\nThree")
        preview.transcript.setSelectedRange(selection)
        preview.update(document)
        XCTAssertEqual(preview.transcript.selectedRange(), selection)
        preview.update(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 20)]))
        XCTAssertEqual(preview.transcript.selectedRange(), selection)
    }

    func testShorterDocumentKeepsSelectionInBounds() {
        let preview = view(NSAttributedString(string: "One\nTwo\nThree"))
        preview.transcript.setSelectedRange(NSRange(location: 4, length: 9))
        preview.update(NSAttributedString(string: "One\nTwo"))
        XCTAssertLessThanOrEqual(NSMaxRange(preview.transcript.selectedRange()), preview.transcript.string.utf16.count)
    }
}
