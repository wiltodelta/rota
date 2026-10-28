import AppKit
import SwiftUI

/// SwiftUI drops a trailing command-group divider before AppKit adds Full Screen.
@MainActor
enum MainMenu {
    static func separateFullScreen(in menu: NSMenu) {
        guard let index = menu.items.firstIndex(where: { $0.action == #selector(NSWindow.toggleFullScreen(_:)) }),
              index > 0, !menu.items[index - 1].isSeparatorItem else { return }
        menu.insertItem(.separator(), at: index)
    }
}

/// View > Hide Sidebar / Show Sidebar, Control-Command-S as in Finder and Mail.
struct SidebarToggleCommand: View {
    @State private var model = AppModel.shared

    var body: some View {
        Button(model.sidebarShown ? "Hide Sidebar" : "Show Sidebar") { model.sidebarVisible.toggle() }
            .keyboardShortcut("s", modifiers: [.control, .command])
            // Settings' sections and Back live in the sidebar.
            .disabled(model.settingsPane != nil)
    }
}

/// The Routine menu: what a person does to the routine in front of them.
struct RoutineCommands: Commands {
    var body: some Commands {
        CommandMenu("Routine") {
            let model = AppModel.shared
            let routine = model.selectedRoutine
            let running = routine.map { model.scheduler.active[$0.id] != nil } ?? false
            Button("Run Now") {
                guard let routine else { return }
                model.scheduler.run(routine, trigger: .manual)
                model.selection = model.latest(of: routine.id)
            }
            .keyboardShortcut("r")
            .disabled(routine == nil || running)
            Button("Stop") { routine.map { model.scheduler.stop($0.id) } }
                .keyboardShortcut(".")
                .disabled(!running)
            Divider()
            Button("Edit Routine\u{2026}") { model.editSelectedRoutine() }
                .keyboardShortcut("e")
                .disabled(routine == nil)
        }
    }
}
