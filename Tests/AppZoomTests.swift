@testable import Rota
import AppKit
import SwiftUI
import XCTest

@MainActor
final class AppZoomTests: XCTestCase {
    func testZoomPersistsIndependentlyAndStopsAtLimits() throws {
        let suite = "rota-zoom-test-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let zoom = AppZoomSettings(defaults: defaults)
        let chat = ChatTextSettings(defaults: defaults)
        chat.size = 18
        XCTAssertEqual(zoom.percent, 100)
        zoom.increase()
        XCTAssertEqual(zoom.scale, 1.1)
        XCTAssertEqual(AppZoomSettings(defaults: defaults).percent, 110)
        XCTAssertEqual(chat.size, 18)
        zoom.percent = 200
        zoom.increase()
        XCTAssertEqual(zoom.percent, 200)
        zoom.percent = 50
        zoom.decrease()
        XCTAssertEqual(zoom.percent, 50)
        zoom.reset()
        XCTAssertEqual(zoom.percent, 100)
        XCTAssertEqual(ChatTextSettings(defaults: defaults).size, 18)
        defaults.set(900, forKey: "appZoomPercent")
        XCTAssertEqual(AppZoomSettings(defaults: defaults).percent, 200)
    }

    func testSystemFontStylesScaleInPointsAndKeepTheirFaces() {
        for style in [Font.TextStyle.body, .headline, .callout, .caption] {
            let base = InterfaceTypography.font(style, scale: 1)
            for scale in [0.5, 1.1, 2] {
                let scaled = InterfaceTypography.font(style, scale: scale)
                XCTAssertEqual(scaled.pointSize, base.pointSize * scale, accuracy: 0.001)
                XCTAssertEqual(scaled.fontName, base.fontName)
            }
        }
    }

    func testChatStepUsesAppScaleAndResetLeavesAppZoomAlone() throws {
        let suite = "rota-zoom-test-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let zoom = AppZoomSettings(defaults: defaults)
        let chat = ChatTextSettings(defaults: defaults)
        chat.bigger(appScale: zoom.scale)
        XCTAssertEqual(chat.effectiveScale(appScale: zoom.scale), 1.1, accuracy: 1e-7)
        zoom.increase()
        XCTAssertEqual(chat.effectiveScale(appScale: zoom.scale), 1.21, accuracy: 1e-7)
        chat.bigger(appScale: zoom.scale)
        XCTAssertEqual(chat.effectiveScale(appScale: zoom.scale), 1.32, accuracy: 1e-7)
        chat.smaller(appScale: zoom.scale)
        XCTAssertEqual(chat.effectiveScale(appScale: zoom.scale), 1.21, accuracy: 1e-7)
        chat.reset(appScale: zoom.scale)
        XCTAssertEqual(chat.effectiveSize(appScale: zoom.scale), 14, accuracy: 1e-7)
        XCTAssertEqual(zoom.percent, 110)
        XCTAssertEqual(ChatTextSettings(defaults: defaults).size, chat.size)
    }

    func testChatEffectiveLimitsRemainTheSameAtBothAppZoomLimits() throws {
        let suite = "rota-zoom-test-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let chat = ChatTextSettings(defaults: defaults)
        chat.size = 56
        XCTAssertEqual(chat.effectiveScale(appScale: 2), 2)
        chat.size = 3.5
        XCTAssertEqual(chat.effectiveScale(appScale: 0.5), 0.5)
        for appScale in [0.5, 1.1, 2] {
            chat.reset(appScale: appScale)
            for _ in 0..<40 { chat.bigger(appScale: appScale) }
            XCTAssertEqual(chat.effectiveScale(appScale: appScale), 2, accuracy: 1e-7)
            XCTAssertFalse(chat.canIncrease(appScale: appScale))
            let upperSize = chat.size
            chat.bigger(appScale: appScale)
            XCTAssertEqual(chat.size, upperSize)
            for _ in 0..<40 { chat.smaller(appScale: appScale) }
            XCTAssertEqual(chat.effectiveScale(appScale: appScale), 0.5, accuracy: 1e-7)
            XCTAssertFalse(chat.canDecrease(appScale: appScale))
        }
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

    func testTranscriptZoomChangesLayoutWithoutChangingTextSelectionOrChatFont() throws {
        let view = TranscriptScrollView()
        view.frame = NSRect(x: 0, y: 0, width: 300, height: 300)
        let base = TranscriptStyle(family: "", codeFamily: "", size: 14)
        view.update(NSAttributedString(string: "Selectable text", attributes: base.attributes(indent: 16)))
        view.transcript.setSelectedRange(NSRange(location: 0, length: 10))
        for scale in [0.5, 1.5, 2] {
            let style = TranscriptStyle(family: "", codeFamily: "", size: 14, interfaceScale: scale)
            view.interfaceScale = scale
            view.update(NSAttributedString(string: "Selectable text", attributes: style.attributes(indent: 16)))
            let attributes = try XCTUnwrap(view.transcript.textStorage?.attributes(at: 0, effectiveRange: nil))
            let paragraph = try XCTUnwrap(attributes[.paragraphStyle] as? NSParagraphStyle)
            XCTAssertEqual(paragraph.paragraphSpacing, 8 * scale)
            XCTAssertEqual(paragraph.headIndent, 16 * scale)
            XCTAssertEqual((attributes[.font] as? NSFont)?.pointSize, 14)
            XCTAssertEqual(view.transcript.textContainerInset, NSSize(width: 24 * scale, height: 20 * scale))
            XCTAssertEqual(view.transcript.selectedRange(), NSRange(location: 0, length: 10))
            XCTAssertEqual(view.transcript.bounds.size, view.transcript.frame.size)
        }
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
                    let ink = InterfaceButtonStyle.ink(for: accent)
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
        XCTAssertEqual(view.interfaceScale, 1)
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
    func testPickerKeepsNativeAccessibilityAndRealScaledFontAtEveryZoom() throws {
        for scale in [0.5, 1.0, 2.0] {
            let picker = InterfacePicker("Font", value: "System", selection: Binding.constant("")) {
                Text("System").tag("")
            }.environment(\.interfaceTextScale, scale)
            let host = NSHostingView(rootView: picker)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520 * scale, height: 200),
                                  styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            func button(in view: NSView) -> NSButton? {
                if let button = view as? NSButton { return button }
                return view.subviews.lazy.compactMap { button(in: $0) }.first
            }
            let native = try XCTUnwrap(button(in: host))
            XCTAssertEqual(native.font?.pointSize, InterfaceTypography.font(.body, scale: scale).pointSize)
            XCTAssertEqual(native.accessibilityRole(), .popUpButton)
            XCTAssertTrue(native.isAccessibilityElement())
            XCTAssertEqual(native.accessibilityLabel(), "Font")
            XCTAssertEqual(native.accessibilityValue() as? String, "System")
            XCTAssertNotNil(native.menu)
            XCTAssertGreaterThanOrEqual(native.frame.height, 20)
        }
    }
}
