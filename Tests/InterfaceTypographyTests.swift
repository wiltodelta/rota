@testable import Rota
import AppKit
import SwiftUI
import XCTest

@MainActor
final class InterfaceTypographyTests: XCTestCase {
    func testChatSizeMigratesOnceAndIgnoresRetiredInterfaceZoom() throws {
        let suite = "rota-chat-size-test-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(150, forKey: "appZoomPercent")
        defaults.set(12, forKey: "chatFontSize")
        let chat = ChatTextSettings(defaults: defaults)
        XCTAssertEqual(chat.size, 18)
        XCTAssertEqual(defaults.double(forKey: "chatTextPointSize"), 18)
        XCTAssertEqual(defaults.double(forKey: "chatFontSize"), 12)
        defaults.set(50, forKey: "appZoomPercent")
        XCTAssertEqual(ChatTextSettings(defaults: defaults).size, 18)
        chat.size = 21
        XCTAssertEqual(ChatTextSettings(defaults: defaults).size, 21)
    }

    func testChatSizeStaysWithinReadableLimitsAndResetsIndependently() throws {
        let suite = "rota-chat-size-test-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(200, forKey: "appZoomPercent")
        defaults.set(56, forKey: "chatFontSize")
        let chat = ChatTextSettings(defaults: defaults)
        XCTAssertEqual(chat.size, 28)
        for _ in 0..<40 { chat.bigger() }
        XCTAssertEqual(chat.size, 28)
        for _ in 0..<40 { chat.smaller() }
        XCTAssertEqual(chat.size, 10)
        chat.reset()
        XCTAssertEqual(chat.size, 14)
        XCTAssertEqual(defaults.integer(forKey: "appZoomPercent"), 200)
        chat.size = .nan
        XCTAssertEqual(chat.size, 14)
    }

    func testTranscriptUsesRealLargerFontsInTheNativeTextBuffer() {
        let base = TranscriptStyle(family: "", codeFamily: "", size: 14)
        let scaled = TranscriptStyle(family: "", codeFamily: "", size: 14 * 1.5)
        for (before, after) in [(base.font, scaled.font), (base.codeFont, scaled.codeFont),
                                (base.smallFont, scaled.smallFont)] {
            XCTAssertEqual(after.pointSize, before.pointSize * 1.5, accuracy: 0.001)
            XCTAssertEqual(after.fontName, before.fontName)
        }
        let view = NSTextView()
        view.textStorage?.setAttributedString(NSAttributedString(string: "Sharp text", attributes: scaled.attributes()))
        let actual = view.textStorage?.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        XCTAssertEqual(actual?.pointSize, 21)
        XCTAssertEqual(view.bounds.size, view.frame.size)
    }

    func testPrimaryButtonInkRemainsReadableWithSystemAccentColors() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            appearance.performAsCurrentDrawingAppearance {
                for accent in [NSColor.controlAccentColor, .systemBlue, .systemPurple, .systemPink,
                               .systemRed, .systemOrange, .systemYellow, .systemGreen, .systemGray] {
                    let rgb = accent.usingColorSpace(.sRGB)!
                    let channels = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent]
                    let weights = [0.2126, 0.7152, 0.0722]
                    let luminance = zip(channels, weights).reduce(0.0) { total, pair in
                        let channel = pair.0
                        return total + pair.1 * (channel <= 0.04045 ? channel / 12.92
                                                 : pow((channel + 0.055) / 1.055, 2.4))
                    }
                    let ink = AccentInk.ink(for: accent)
                    let contrast = ink == .white ? 1.05 / (luminance + 0.05) : (luminance + 0.05) / 0.05
                    XCTAssertGreaterThanOrEqual(contrast, 4.5, "Accent: \(accent), appearance: \(name)")
                }
            }
        }
    }

    func testChatTextResizeReflowsWithoutEnlargingTheInterfaceGeometry() throws {
        let view = TranscriptScrollView()
        view.frame = NSRect(x: 0, y: 0, width: 300, height: 180)
        let text = String(repeating: "A readable paragraph wraps within the chat column. ", count: 12)
        func document(size: CGFloat) -> NSAttributedString {
            NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: size)])
        }
        view.update(document(size: 14))
        let frame = view.frame
        let insets = view.transcript.textContainerInset
        let columnWidth = try XCTUnwrap(view.transcript.textContainer).containerSize.width
        let textHeight = view.transcript.frame.height
        let selected = NSRange(location: 0, length: 10)
        view.transcript.setSelectedRange(selected)

        view.update(document(size: 28))
        XCTAssertGreaterThan(view.transcript.frame.height, textHeight)
        XCTAssertEqual(view.frame, frame)
        XCTAssertEqual(view.transcript.textContainerInset, insets)
        XCTAssertEqual(view.transcript.textContainer?.containerSize.width, columnWidth)
        XCTAssertEqual(view.transcript.selectedRange(), selected)
    }

    func testShrinkingSelectedChatTextKeepsAllFittingTextVisible() throws {
        let view = TranscriptScrollView()
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        let text = String(repeating: "A readable paragraph wraps within the chat column. ", count: 10)
        func document(_ size: CGFloat) -> NSAttributedString {
            NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: size)])
        }
        view.update(document(28))
        let selected = NSRange(location: text.utf16.count - 10, length: 10)
        view.transcript.setSelectedRange(selected)
        XCTAssertGreaterThan(view.contentView.bounds.origin.y, view.transcript.frame.minY)
        view.update(document(7))
        let layout = try XCTUnwrap(view.transcript.layoutManager)
        let container = try XCTUnwrap(view.transcript.textContainer)
        layout.ensureLayout(for: container)
        let glyphs = layout.usedRect(for: container).offsetBy(dx: view.transcript.textContainerInset.width,
                                                              dy: view.transcript.textContainerInset.height)
        XCTAssertLessThan(glyphs.maxY, view.contentSize.height)
        XCTAssertTrue(view.transcript.visibleRect.contains(glyphs),
                      "Visible: \(view.transcript.visibleRect), glyphs: \(glyphs)")
        XCTAssertEqual(view.transcript.selectedRange(), selected)
    }
    func testPickerKeepsNativeAccessibilityAndSystemFont() throws {
        let picker = InterfacePicker("Font", value: "System", selection: Binding.constant("")) {
            Text("System").tag("")
        }
        let host = NSHostingView(rootView: picker)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 200),
                              styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        func button(in view: NSView) -> NSButton? {
            if let button = view as? NSButton { return button }
            return view.subviews.lazy.compactMap { button(in: $0) }.first
        }
        let native = try XCTUnwrap(button(in: host))
        XCTAssertEqual(native.font?.pointSize, NSFont.preferredFont(forTextStyle: .body).pointSize)
        XCTAssertEqual(native.accessibilityRole(), .popUpButton)
        XCTAssertTrue(native.isAccessibilityElement())
        XCTAssertEqual(native.accessibilityLabel(), "Font")
        XCTAssertEqual(native.accessibilityValue() as? String, "System")
        XCTAssertNotNil(native.menu)
        XCTAssertGreaterThanOrEqual(native.frame.height, 20)
    }
}
