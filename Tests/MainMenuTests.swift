import AppKit
@testable import Rota
import XCTest

@MainActor
final class MainMenuTests: XCTestCase {
    func testFullScreenHasOneSeparatorAfterMenuRebuilds() throws {
        let menu = NSMenu()
        menu.addItem(withTitle: "Actual Size", action: nil, keyEquivalent: "0")
        let fullScreen = menu.addItem(withTitle: "Localized full screen",
                                      action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        XCTAssertEqual(menu.numberOfItems, 2)
        MainMenu.separateFullScreen(in: menu)
        XCTAssertEqual(menu.numberOfItems, 3)
        XCTAssertEqual(try XCTUnwrap(menu.items.dropFirst().first).isSeparatorItem, true)
        XCTAssertTrue(menu.items.last === fullScreen)
        MainMenu.separateFullScreen(in: menu)
        XCTAssertEqual(menu.numberOfItems, 3)
        guard menu.numberOfItems == 3 else { return XCTFail("Missing separator") }
        menu.removeItem(at: 1)
        XCTAssertEqual(menu.numberOfItems, 2, "The fixture must simulate SwiftUI rebuilding its command group")
        MainMenu.separateFullScreen(in: menu)
        XCTAssertTrue(menu.item(at: 1)?.isSeparatorItem == true)
    }

    func testMenusWithoutAPrecedingCommandStayUnchanged() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Localized full screen", action: #selector(NSWindow.toggleFullScreen(_:)),
                     keyEquivalent: "f")
        MainMenu.separateFullScreen(in: menu)
        XCTAssertEqual(menu.numberOfItems, 1)
        let other = NSMenu()
        other.addItem(withTitle: "Actual Size", action: nil, keyEquivalent: "0")
        MainMenu.separateFullScreen(in: other)
        XCTAssertEqual(other.numberOfItems, 1)
    }
}
