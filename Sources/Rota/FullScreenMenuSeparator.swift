import AppKit

/// SwiftUI drops trailing dividers before AppKit appends its full-screen command.
@MainActor
enum FullScreenMenuSeparator {
    static func update(_ menu: NSMenu) {
        for item in menu.items {
            if let submenu = item.submenu { update(submenu) }
        }
        guard let index = menu.items.firstIndex(where: { $0.action == #selector(NSWindow.toggleFullScreen(_:)) }),
              index > 0 else { return }
        let previous = menu.item(at: index - 1)
        if previous?.isSeparatorItem == true, previous?.isHidden == false { return }
        menu.insertItem(.separator(), at: index)
    }
}
