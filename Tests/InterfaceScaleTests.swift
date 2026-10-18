import AppKit
import SwiftUI
@testable import Rota
import XCTest

@MainActor
final class InterfaceScaleTests: XCTestCase {
    func testZoomPersistsAndResetPreservesChatPreferences() throws {
        let name = "rota-scale-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(18.0, forKey: "chatFontSize")
        defaults.set("Fixture Font", forKey: "chatFontFamily")
        let scale = InterfaceScaleSettings(defaults: defaults)
        let chat = ChatTextSettings(defaults: defaults, interfaceScale: scale)
        XCTAssertEqual(scale.factor, 1)
        scale.increase()
        scale.increase()
        XCTAssertEqual(scale.factor, 1.25)
        XCTAssertEqual(chat.effectiveSize(chat.size), 22.5)
        XCTAssertEqual(InterfaceScaleSettings(defaults: defaults).factor, 1.25)
        scale.reset()
        XCTAssertEqual(chat.effectiveSize(chat.size), 18)
        XCTAssertEqual(chat.family, "Fixture Font")
        XCTAssertEqual(defaults.double(forKey: "chatFontSize"), 18)
        XCTAssertEqual(InterfaceScaleSettings(defaults: defaults).factor, 1)
    }

    func testRenderedTypographyFollowsZoomAtBothBackingScales() throws {
        _ = NSApplication.shared
        let name = "rota-scale-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let scale = InterfaceScaleSettings(defaults: defaults)
        for backingScale in [1.0, 2.0] {
            func render(_ factor: Double) throws -> CGImage {
                scale.factor = factor
                let renderer = ImageRenderer(content: Text("Aa Example 0123")
                    .interfaceFont(.body).interfaceScale(scale))
                renderer.scale = backingScale
                return try XCTUnwrap(renderer.cgImage)
            }
            let normal = try render(1)
            let enlarged = try render(1.5)
            XCTAssertGreaterThan(Double(enlarged.width), Double(normal.width) * 1.4)
            XCTAssertGreaterThan(Double(enlarged.height), Double(normal.height) * 1.3)
        }
    }

    func testNativePickerUsesTheZoomedFontAndSendsTheSelectedValue() throws {
        _ = NSApplication.shared
        var selected: String?
        let picker = InterfacePicker(title: "Model", selection: Binding(
            get: { selected }, set: { selected = $0 }
        ), choices: [.item("Default", nil), .separator, .item("Model 2", "model-2")], identifier: "model")
        let host = NSHostingView(rootView: picker.environment(\.interfaceScale, InterfaceScale(factor: 1.5)))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 80),
                              styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let button = try XCTUnwrap(popup(in: host))
        XCTAssertEqual(try XCTUnwrap(button.font).pointSize, NSFont.systemFontSize * 1.5)
        XCTAssertTrue(button.item(at: 1)?.isSeparatorItem == true)
        button.selectItem(at: 2)
        XCTAssertEqual(button.indexOfSelectedItem, 2, "The fixture must actually select the non-default item")
        XCTAssertTrue(NSApp.sendAction(try XCTUnwrap(button.action), to: button.target, from: button))
        XCTAssertEqual(selected, "model-2")
    }

    func testChangingScaleUpdatesAnExistingHostedControl() async throws {
        _ = NSApplication.shared
        let name = "rota-scale-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let scale = InterfaceScaleSettings(defaults: defaults)
        let picker = InterfacePicker(title: "Model", selection: .constant("model-2"),
                                     choices: [.item("Model 2", "model-2")])
        let host = NSHostingView(rootView: picker.interfaceScale(scale))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 80),
                              styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        let button = try XCTUnwrap(popup(in: host))
        XCTAssertEqual(try XCTUnwrap(button.font).pointSize, NSFont.systemFontSize)
        scale.factor = 1.5
        XCTAssertEqual(scale.factor, 1.5, "The fixture must mutate the shared setting")
        for _ in 0..<2 {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
        host.layoutSubtreeIfNeeded()
        XCTAssertTrue(popup(in: host) === button, "Zoom must preserve the hosted control's identity")
        XCTAssertEqual(try XCTUnwrap(button.font).pointSize, NSFont.systemFontSize * 1.5)
    }

    func testSettingsPaneReportsItsNewSizeAfterZoom() async throws {
        _ = NSApplication.shared
        let name = "rota-scale-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let scale = InterfaceScaleSettings(defaults: defaults)
        let controller = SettingsPaneController(rootView: Text("Settings").settingsPane().interfaceScale(scale))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 100),
                              styleMask: [], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentViewController = controller
        controller.view.layoutSubtreeIfNeeded()
        XCTAssertEqual(controller.preferredContentSize.width, 520)
        scale.factor = 1.5
        for _ in 0..<4 {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
            controller.view.layoutSubtreeIfNeeded()
        }
        XCTAssertEqual(controller.preferredContentSize.width, 780)
    }

    func testPickerValuesKeepTheSameGapToTheirArrows() throws {
        _ = NSApplication.shared
        var trailingEdges: [CGFloat] = []
        for selected in ["System", "JetBrains Mono"] {
            let picker = InterfacePicker(title: "Font", selection: .constant(selected), choices: [
                .item("System", "System"), .item("JetBrains Mono", "JetBrains Mono"),
                .item("A considerably longer font name", "long")
            ])
            let host = NSHostingView(rootView: Form { picker }.formStyle(.grouped)
                .frame(width: 520, height: 100).environment(\.interfaceScale, InterfaceScale(factor: 1.5)))
            host.appearance = NSAppearance(named: .aqua)
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 100),
                                  styleMask: [], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            defer { window.close() }
            window.contentView = host
            host.layoutSubtreeIfNeeded()
            let button = try XCTUnwrap(popup(in: host))
            XCTAssertEqual(button.title, selected, "The fixture must render both selected values")
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let backingScale = CGFloat(bitmap.pixelsWide) / host.bounds.width
            let rect = button.convert(button.bounds, to: host)
            let top = host.isFlipped ? rect.minY : host.bounds.height - rect.maxY
            // Exclude the arrow; compare the visible trailing edge of each value.
            let start = Int(rect.minX * backingScale)
            let end = Int((rect.maxX - 30) * backingScale)
            let rows = Int((top + rect.height / 4) * backingScale)..<Int((top + rect.height * 3 / 4) * backingScale)
            var lastInk: Int?
            for x in start..<end {
                for y in rows {
                    guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                    if color.alphaComponent > 0.5,
                       max(color.redComponent, color.greenComponent, color.blueComponent) < 0.3 { lastInk = x }
                }
            }
            trailingEdges.append(CGFloat(try XCTUnwrap(lastInk)) / backingScale)
        }
        XCTAssertEqual(trailingEdges[0], trailingEdges[1], accuracy: 2,
                       "Short and long values must end at the same distance from their arrows")
    }

    func testInvalidStoredAndAssignedValuesCannotEscapeSupportedLevels() throws {
        let name = "rota-scale-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("1.25", forKey: "interfaceScale")
        XCTAssertEqual(InterfaceScaleSettings(defaults: defaults).factor, 1.25,
                       "Launch argument overrides arrive as strings")
        defaults.set(500.0, forKey: "interfaceScale")
        let scale = InterfaceScaleSettings(defaults: defaults)
        XCTAssertEqual(scale.factor, 1.5)
        XCTAssertFalse(scale.canIncrease)
        scale.increase()
        XCTAssertEqual(scale.factor, 1.5)
        scale.factor = .nan
        XCTAssertEqual(scale.factor, 1)
        scale.factor = 0.01
        XCTAssertEqual(scale.factor, 0.8)
        XCTAssertFalse(scale.canDecrease)
        scale.decrease()
        XCTAssertEqual(scale.factor, 0.8)
        scale.factor = 1.24
        XCTAssertEqual(scale.factor, 1.25)
    }

    private func popup(in view: NSView) -> NSPopUpButton? {
        if let button = view as? NSPopUpButton { return button }
        return view.subviews.lazy.compactMap { self.popup(in: $0) }.first
    }
}
