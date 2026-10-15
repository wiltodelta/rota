@testable import Rota
import AppKit
@testable import RotaCore
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

    func testActivityStaysCollapsedWhileRunningAndNativeLinkRevealsPlanAndTools() throws {
        var projection = SessionTranscript()
        let turn = "preview-turn"
        for payload: SessionEvent.Payload in [
            .user(id: "prompt", text: "Review the report", delivery: .accepted),
            .metadata(SessionMetadata(model: "example-model")),
            .assistant(id: "commentary", text: "Checking the totals", phase: .work),
            .tool(id: "read", title: "Read sample.txt", input: nil, output: "Three tasks", status: "completed"),
            .plan([PlanStep(status: .completed, text: "Verify the totals")]),
            .assistant(id: "answer", text: "The totals match.", phase: .answer),
            .note(text: "A visible warning", error: true),
            .user(id: "follow-up", text: "Check another report", delivery: .failed("Session ended"))
        ] {
            projection.apply(SessionEvent(turnID: turn, payload: payload))
        }
        let document = TranscriptDocument(style: TranscriptStyle(family: "", codeFamily: "", size: 14))
        let collapsed = document.make(items: projection.items, running: true, activity: [:])
        XCTAssertTrue(collapsed.string.contains("› Activity · 1 tool call"))
        XCTAssertTrue(collapsed.string.contains("The totals match."))
        XCTAssertTrue(collapsed.string.contains("A visible warning"))
        XCTAssertTrue(collapsed.string.contains("Not delivered: Session ended"))
        XCTAssertTrue(collapsed.string.contains("Working…"))
        for hidden in ["Checking the totals", "Read sample.txt", "Verify the totals", "example-model"] {
            XCTAssertFalse(collapsed.string.contains(hidden), hidden)
        }
        let preview = view(collapsed)
        let selection = (collapsed.string as NSString).range(of: "The totals match.")
        preview.transcript.setSelectedRange(selection)
        let linkRange = (collapsed.string as NSString).range(of: "Activity")
        let link = try XCTUnwrap(collapsed.attribute(.link, at: linkRange.location, effectiveRange: nil))
        var toggled: Int?
        preview.activityToggled = { [weak preview] id in
            toggled = id
            preview?.update(document.make(items: projection.items, running: true, activity: [id: true]))
        }
        XCTAssertTrue(preview.textView(preview.transcript, clickedOnLink: link, at: linkRange.location))
        XCTAssertEqual(toggled, TranscriptTurn.group(projection.items).first?.id)
        for visible in ["⌄ Activity", "Checking the totals", "Read sample.txt", "Done: Verify the totals"] {
            XCTAssertTrue(preview.transcript.string.contains(visible), visible)
        }
        let selected = preview.transcript.selectedRange()
        XCTAssertEqual((preview.transcript.string as NSString).substring(with: selected), "The totals match.")
        preview.update(collapsed)
        XCTAssertEqual((preview.transcript.string as NSString).substring(with: preview.transcript.selectedRange()),
                       "The totals match.")
    }

    func testPlanOnlyTurnsHaveIndependentActivityLinks() {
        var projection = SessionTranscript()
        for id in ["first", "second"] {
            projection.apply(SessionEvent(turnID: id, payload: .plan([PlanStep(status: .pending, text: id)])))
        }
        let turns = TranscriptTurn.group(projection.items)
        XCTAssertEqual(turns.count, 2)
        XCTAssertNotEqual(turns[0].id, turns[1].id)
        let document = TranscriptDocument(style: TranscriptStyle(family: "", codeFamily: "", size: 14))
            .make(items: projection.items, running: false, activity: [turns[0].id: true])
        XCTAssertTrue(document.string.contains("To do: first"))
        XCTAssertFalse(document.string.contains("To do: second"))
        var links: [URL] = []
        document.enumerateAttribute(.link, in: NSRange(location: 0, length: document.length)) { value, _, _ in
            if let url = value as? URL { links.append(url) }
        }
        XCTAssertEqual(Set(links).count, 2)
    }

    func testExpandingActivityKeepsViewportInsteadOfFollowingTheAnswer() {
        let collapsed = "You\nReview the report\nActivity\nThe totals match."
        let expanded = "You\nReview the report\nActivity\n"
            + (0..<80).map { "Intermediate step \($0)" }.joined(separator: "\n")
            + "\nThe totals match."
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 14)]
        let preview = view(NSAttributedString(string: collapsed, attributes: attributes))
        let origin = preview.contentView.bounds.origin
        preview.activityToggled = { [weak preview] _ in
            preview?.update(NSAttributedString(string: expanded, attributes: attributes))
        }
        XCTAssertTrue(preview.textView(preview.transcript, clickedOnLink: URL(string: "rota-activity://0")!,
                                       at: 0))
        XCTAssertGreaterThan(preview.transcript.frame.height, preview.contentSize.height)
        XCTAssertEqual(preview.contentView.bounds.origin, origin)
    }

    func testFollowingTheEndShowsTheLastLineInAShortViewportAtLargeScale() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let attachments = try AttachmentTestFixture.create(in: folder).files.map(ChatAttachment.inspect)
        var projection = SessionTranscript()
        projection.apply(SessionEvent(turnID: "preview", payload: .user(id: "prompt", text: "Review the report",
                                                                       delivery: .accepted)))
        let answer = "The totals match.\n\n- Three tasks completed\n- No missing entries"
        projection.apply(SessionEvent(turnID: "preview",
                                      payload: .assistant(id: "answer", text: answer, phase: .answer)))
        projection.apply(SessionEvent(turnID: "preview", payload: .user(id: "follow-up", text: "Привет 𠀀",
                                                                       delivery: .failed("Session ended"))))
        projection.apply(SessionEvent(turnID: "preview", payload: .attachments(id: "follow-up", files: attachments)))
        projection.apply(SessionEvent(turnID: "preview", payload: .finished(.succeeded)))
        let document = TranscriptDocument(style: TranscriptStyle(family: "", codeFamily: "", size: 28))
            .make(items: projection.items, running: false, activity: [:])
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 580, height: 600))
        let window = NSWindow(contentRect: root.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = root
        for height in [44.0, 85.5] {
            let preview = TranscriptScrollView()
            preview.frame = NSRect(x: 0, y: 0, width: 580, height: height)
            root.addSubview(preview)
            preview.update(document)
            XCTAssertEqual(preview.contentSize.height, height, accuracy: 0.01)
            let text = preview.transcript
            let layout = try XCTUnwrap(text.layoutManager)
            let container = try XCTUnwrap(text.textContainer)
            let range = (text.string as NSString).range(of: "Succeeded")
            XCTAssertNotEqual(range.location, NSNotFound)
            let glyphs = layout.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let line = layout.boundingRect(forGlyphRange: glyphs, in: container)
                .offsetBy(dx: text.textContainerOrigin.x, dy: text.textContainerOrigin.y)
            XCTAssertGreaterThanOrEqual(line.minY, preview.contentView.bounds.minY, "Viewport height: \(height)")
            XCTAssertLessThanOrEqual(line.maxY, preview.contentView.bounds.maxY)
            preview.removeFromSuperview()
        }
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
        let style = TranscriptStyle(family: "", codeFamily: "", size: 14)
        let document = TranscriptDocument(style: style).make(items: Transcript.parse(log),
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
