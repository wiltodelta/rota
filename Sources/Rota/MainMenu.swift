import AppKit

/// SwiftUI drops a trailing command-group divider before AppKit adds Full Screen.
@MainActor
enum MainMenu {
    static func separateFullScreen(in menu: NSMenu) {
        guard let index = menu.items.firstIndex(where: { $0.action == #selector(NSWindow.toggleFullScreen(_:)) }),
              index > 0, !menu.items[index - 1].isSeparatorItem else { return }
        menu.insertItem(.separator(), at: index)
    }
}
