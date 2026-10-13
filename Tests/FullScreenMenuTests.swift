import AppKit
@testable import Rota
import XCTest

@MainActor
final class FullScreenMenuTests: XCTestCase {
    func testFullScreenGetsAVisibleSeparatorAfterHiddenSwiftUIDivider() throws {
        let menu = NSMenu()
        menu.addItem(withTitle: "Reset Chat Text Size", action: nil, keyEquivalent: "")
        let hidden = NSMenuItem.separator()
        hidden.isHidden = true
        menu.addItem(hidden)
        let fullScreen = NSMenuItem(title: "Enter Full Screen",
                                    action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "")
        menu.addItem(fullScreen)
        FullScreenMenuSeparator.update(menu)
        FullScreenMenuSeparator.update(menu)
        let index = menu.index(of: fullScreen)
        let separator = try XCTUnwrap(menu.item(at: index - 1))
        XCTAssertTrue(separator.isSeparatorItem)
        XCTAssertFalse(separator.isHidden)
        XCTAssertEqual(menu.items.count, 4)
    }
}
