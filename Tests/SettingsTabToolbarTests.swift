import AppKit
import SwiftUI
@testable import Rota
import XCTest

@MainActor
final class SettingsTabToolbarTests: XCTestCase {
    func testExistingNativeToolbarTabsFollowZoomAndKeepSelection() async throws {
        _ = NSApplication.shared
        let name = "rota-settings-tabs-test-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let scale = InterfaceScaleSettings(defaults: defaults)
        let tabs = ScalableSettingsTabController(scale: scale)
        for (title, symbol) in [("General", "gearshape"), ("Chat", "textformat.size"), ("Agents", "terminal")] {
            let content = NSHostingController(rootView: Text(title).frame(width: 520, height: 400))
            let item = NSTabViewItem(viewController: content)
            item.identifier = title
            item.label = title
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            tabs.addTabViewItem(item)
        }
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        defer { window.close() }
        tabs.viewDidAppear()
        for factor in InterfaceScaleSettings.levels {
            scale.factor = factor
            for _ in 0..<8 {
                await withCheckedContinuation { continuation in
                    DispatchQueue.main.async { continuation.resume() }
                }
                window.update()
                window.contentView?.superview?.layoutSubtreeIfNeeded()
            }
            let toolbar = try XCTUnwrap(window.toolbar)
            XCTAssertEqual(toolbar.displayMode, .iconOnly)
            let tab = try XCTUnwrap(toolbar.items.compactMap { $0.view as? SettingsTabItemView }.first)
            XCTAssertEqual(tab.caption.font?.pointSize ?? 0, 13 * factor, accuracy: 0.01)
            XCTAssertEqual(tab.frame.height, 68 * factor, accuracy: 0.5)
            XCTAssertEqual(tab.button.frame.height, tab.frame.height, accuracy: 0.5)
            let views = toolbar.items.compactMap { $0.view as? SettingsTabItemView }
            let centers = views.map { $0.caption.convert($0.caption.bounds, to: nil).midY }
            XCTAssertLessThanOrEqual((centers.max() ?? 0) - (centers.min() ?? 0), 0.5)
        }
        let toolbar = try XCTUnwrap(window.toolbar)
        let views = toolbar.items.compactMap { $0.view as? SettingsTabItemView }
        let agents = try XCTUnwrap(views.first { $0.caption.stringValue == "Agents" })
        agents.button.performClick(nil)
        XCTAssertEqual(tabs.selectedTabViewItemIndex, 2)
        XCTAssertEqual(toolbar.selectedItemIdentifier?.rawValue, "Agents")
    }
}
