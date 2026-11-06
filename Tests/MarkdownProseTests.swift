import AppKit
@testable import Rota
import RotaCore
import XCTest

@MainActor
final class MarkdownProseTests: XCTestCase {
    private let settings = ChatTextSettings(defaults: UserDefaults(suiteName: "MarkdownProseTests")!)

    func testProseBlocksShareOneViewBetweenCodeTablesAndImages() {
        let blocks = MarkdownBlock.parse("""
            ## Summary
            First line.
            - item

            ```
            ls
            ```
            After code.

            ![chart](chart.png)

            Last.
            """)
        let shapes = MarkdownProse.parts(blocks).map { part -> String in
            switch part {
            case .prose(let run): return "prose\(run.count)"
            case .block(let block): if case .code = block { return "code" } else { return "block" }
            }
        }
        XCTAssertEqual(shapes, ["prose3", "code", "prose1", "block", "prose1"])
    }

    func testSelectionCopiesReadableTextWithHangingListIndent() {
        let blocks = MarkdownBlock.parse("""
            # Title
            One **bold** and [link](https://example.com) `code`
            continued.
            - item
              - nested
            """)
        let text = MarkdownProse.attributed(blocks, text: settings)
        XCTAssertEqual(text.string, "Title\nOne bold and link code\u{2028}continued.\n•\titem\n•\tnested")

        let bold = (text.string as NSString).range(of: "bold")
        let font = text.attribute(.font, at: bold.location, effectiveRange: nil) as? NSFont
        XCTAssertTrue(font.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } ?? false)
        let link = (text.string as NSString).range(of: "link")
        XCTAssertEqual(text.attribute(.link, at: link.location, effectiveRange: nil) as? URL,
                       URL(string: "https://example.com"))

        let code = (text.string as NSString).range(of: "code")
        XCTAssertEqual((text.attribute(.font, at: code.location, effectiveRange: nil) as? NSFont)?.isFixedPitch, true)

        let nested = (text.string as NSString).range(of: "nested")
        let style = text.attribute(.paragraphStyle, at: nested.location, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(style?.firstLineHeadIndent, 16)
        XCTAssertGreaterThan(style?.headIndent ?? 0, 16)
        XCTAssertEqual(style?.tabStops.first?.location, style?.headIndent)
        let title = text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle
        XCTAssertEqual(title?.paragraphSpacingBefore, 0)
    }

    func testMeasurementKeepsDisplayedWrappingAtTheFrameWidth() throws {
        let view = ProseTextView.make()
        view.textStorage?.setAttributedString(MarkdownProse.inline(String(repeating: "word ", count: 80),
                                                                   text: settings, font: settings.appKitBody))
        view.setFrameSize(NSSize(width: 200, height: 500))
        let container = try XCTUnwrap(view.textContainer)
        let layout = try XCTUnwrap(view.layoutManager)
        layout.ensureLayout(for: container)
        let displayedHeight = layout.usedRect(for: container).height

        _ = view.fittingSize(width: 2000)
        _ = view.fittingSize(width: nil)
        // SwiftUI can keep the same frame after probing other widths.
        view.setFrameSize(view.frame.size)
        layout.ensureLayout(for: container)
        XCTAssertEqual(container.size.width, 200)
        XCTAssertEqual(layout.usedRect(for: container).height, displayedHeight, accuracy: 0.01)
        XCTAssertEqual(view.fittingSize(width: 200).height, ceil(displayedHeight))
    }

    func testZeroWidthProposalNeedsNoTextLayout() {
        let view = ProseTextView.make()
        view.textStorage?.setAttributedString(MarkdownProse.inline(String(repeating: "word ", count: 80),
                                                                   text: settings, font: settings.appKitBody))
        XCTAssertEqual(view.fittingSize(width: 0), .zero)
    }

    func testMeasurementTracksTextStorageEditsAtTheSameWidth() {
        let view = ProseTextView.make()
        view.textStorage?.setAttributedString(MarkdownProse.inline("Short.", text: settings,
                                                                   font: settings.appKitBody))
        let short = view.fittingSize(width: 200)
        view.textStorage?.setAttributedString(MarkdownProse.inline(String(repeating: "word ", count: 80),
                                                                   text: settings, font: settings.appKitBody))
        let long = view.fittingSize(width: 200)
        XCTAssertGreaterThan(long.height, short.height * 3)
        view.textStorage?.addAttribute(.font, value: NSFont.systemFont(ofSize: 28),
                                      range: NSRange(location: 0, length: view.string.utf16.count))
        XCTAssertGreaterThan(view.fittingSize(width: 200).height, long.height)
    }

    func testTextViewHeightFollowsWidth() {
        let view = ProseTextView.make()
        view.textStorage?.setAttributedString(MarkdownProse.inline(String(repeating: "word ", count: 80),
                                                                   text: settings, font: settings.appKitBody))
        let wide = view.fittingSize(width: 2000)
        let narrow = view.fittingSize(width: 200)
        XCTAssertEqual(narrow.width, 200)
        XCTAssertGreaterThan(narrow.height, wide.height * 3)
    }
}
