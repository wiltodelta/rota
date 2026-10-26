import AppKit
@testable import Rota
import RotaCore
import XCTest

@MainActor
final class ChatTextSettingsTests: XCTestCase {
    func testBundledFontsRenderMarkdownWithRealBoldItalicAndCodeFaces() throws {
        let name = "rota-font-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let settings = ChatTextSettings(defaults: defaults)
        let text = MarkdownProse.attributed(MarkdownBlock.parse("""
            ## Heading
            Regular **bold** *italic* ***both*** `code` Кириллица
            """), text: settings)
        for (word, family, traits) in [
            ("Heading", "IBM Plex Sans", NSFontTraitMask.boldFontMask),
            ("Regular", "IBM Plex Sans", []),
            ("bold", "IBM Plex Sans", .boldFontMask),
            ("italic", "IBM Plex Sans", .italicFontMask),
            ("both", "IBM Plex Sans", [.boldFontMask, .italicFontMask]),
            ("code", "JetBrains Mono", []),
            ("Кириллица", "IBM Plex Sans", []),
        ] {
            let range = (text.string as NSString).range(of: word)
            XCTAssertNotEqual(range.location, NSNotFound)
            let font = try XCTUnwrap(text.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont)
            XCTAssertEqual(font.familyName, family, word)
            XCTAssertTrue(NSFontManager.shared.traits(of: font).isSuperset(of: traits), word)
        }
        XCTAssertTrue(ChatTextSettings.families.contains("IBM Plex Sans"))
        XCTAssertTrue(ChatTextSettings.monospacedFamilies.contains("JetBrains Mono"))
    }

    func testExistingFontChoicesIncludingSystemRemainSelected() throws {
        let name = "rota-font-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        for (family, code) in [("Helvetica", "Menlo"), ("", "")] {
            defaults.set(family, forKey: "chatFontFamily")
            defaults.set(code, forKey: "chatCodeFontFamily")
            let settings = ChatTextSettings(defaults: defaults)
            XCTAssertEqual(settings.family, family)
            XCTAssertEqual(settings.codeFamily, code)
            if family.isEmpty {
                XCTAssertEqual(settings.appKitBody, NSFont.systemFont(ofSize: 14))
            }
        }
    }

    func testLegacySizeMigratesOnceWithoutChangingTheBodySize() throws {
        let name = "rota-font-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(18.0, forKey: "chatFontSize")
        let settings = ChatTextSettings(defaults: defaults)
        XCTAssertEqual(settings.scale, 18.0 / 14, accuracy: 0.00001)
        XCTAssertEqual(settings.appKitBody.pointSize, 18, accuracy: 0.00001)
        XCTAssertEqual(defaults.double(forKey: "chatTextScale"), settings.scale)
        settings.scale = 1.2
        defaults.set(28.0, forKey: "chatFontSize")
        XCTAssertEqual(ChatTextSettings(defaults: defaults).scale, 1.2)
        XCTAssertEqual(defaults.double(forKey: "chatFontSize"), 28)
    }

    func testChatZoomComposesWithInterfaceZoomAndLaysOutProseAndCode() throws {
        let name = "rota-font-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let interface = InterfaceScaleSettings(defaults: defaults)
        let settings = ChatTextSettings(defaults: defaults, interfaceScale: interface)
        XCTAssertEqual(settings.scale, 1)
        interface.factor = 1.1
        settings.scale = 1.2
        let factor = 1.1 * 1.2
        XCTAssertEqual(interface.factor, 1.1, "Chat zoom must leave the interface alone")
        XCTAssertEqual(settings.appKitBody.pointSize, 14 * factor, accuracy: 0.001)
        XCTAssertEqual(settings.appKitCode.pointSize, 12.5 * factor, accuracy: 0.001)
        XCTAssertEqual(settings.appKitHeading(level: 1).pointSize, 19 * factor, accuracy: 0.001)

        let source = "First line.\nSecond line.\nThird line."
        let prose = MarkdownProse.attributed([.paragraph(source)], text: settings)
        for (text, height) in [(prose, 22 * factor), (MarkdownProse.code(source, text: settings), 20 * factor)] {
            let view = ProseTextView.make()
            view.textStorage?.setAttributedString(text)
            _ = view.fittingSize(width: 1000)
            let layout = try XCTUnwrap(view.layoutManager)
            var positions: [CGFloat] = []
            let range = NSRange(location: 0, length: layout.numberOfGlyphs)
            layout.enumerateLineFragments(forGlyphRange: range) { rect, _, _, _, _ in
                positions.append(rect.minY)
            }
            XCTAssertEqual(positions.count, 3)
            for index in 1..<positions.count {
                XCTAssertEqual(positions[index] - positions[index - 1], height, accuracy: 0.01)
            }
        }
        interface.reset()
        XCTAssertEqual(settings.scale, 1.2, "Resetting interface zoom must keep the chat preference")
        XCTAssertEqual(settings.appKitBody.pointSize, 16.8, accuracy: 0.001)
    }

    func testInvalidScalesCannotBreakTypographyAndLegacyBoundsRemainReadable() throws {
        let name = "rota-font-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        for (stored, expected) in [(Double.nan, 1.0), (-100, 0.7), (100, 2)] {
            defaults.set(stored, forKey: "chatTextScale")
            let settings = ChatTextSettings(defaults: defaults)
            XCTAssertEqual(settings.scale, expected)
            settings.scale = .infinity
            XCTAssertEqual(settings.scale, 1)
            settings.scale = -1
            XCTAssertEqual(settings.scale, 0.7)
        }
        defaults.removeObject(forKey: "chatTextScale")
        defaults.set(10.0, forKey: "chatFontSize")
        XCTAssertEqual(ChatTextSettings(defaults: defaults).appKitBody.pointSize, 10, accuracy: 0.001)
        defaults.removeObject(forKey: "chatTextScale")
        defaults.set(28.0, forKey: "chatFontSize")
        XCTAssertEqual(ChatTextSettings(defaults: defaults).appKitBody.pointSize, 28, accuracy: 0.001)
    }
}
