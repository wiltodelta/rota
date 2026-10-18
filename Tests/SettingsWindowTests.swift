import AppKit
import SwiftUI
@testable import Rota
import XCTest

@MainActor
final class SettingsWindowTests: XCTestCase {
    func testTallSettingsContentDoesNotForceTheWindowPastItsViewport() throws {
        _ = NSApplication.shared
        let pane = SettingsPaneController(rootView: Form {
            ForEach(0..<30) { index in LabeledContent("Setting \(index)", value: "Value") }
        }.settingsPane())
        let tabs = NSTabViewController()
        tabs.tabStyle = .toolbar
        tabs.addTabViewItem(NSTabViewItem(viewController: pane))
        let window = NSWindow(contentViewController: tabs)
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.setFrame(NSRect(x: 100, y: 100, width: 520, height: 600), display: true)
        window.contentView?.layoutSubtreeIfNeeded()
        XCTAssertLessThanOrEqual(window.frame.height, 600)
        let scroll = try XCTUnwrap(pane.view as? NSScrollView)
        let document = try XCTUnwrap(scroll.documentView)
        XCTAssertGreaterThan(document.frame.height, scroll.contentSize.height)
    }
}
