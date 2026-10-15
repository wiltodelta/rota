import SwiftUI

/// Observe preferences in a view so shortcut availability updates between menu openings.
struct ZoomMenuItems: View {
    @State private var model = AppModel.shared

    var body: some View {
        Group {
            Button("Increase Chat Text Size") {
                model.chatText.bigger()
            }
                .keyboardShortcut("=", modifiers: [.command, .option])
                .disabled(!model.chatText.canIncrease)
            Button("Decrease Chat Text Size") {
                model.chatText.smaller()
            }
                .keyboardShortcut("-", modifiers: [.command, .option])
                .disabled(!model.chatText.canDecrease)
            Button("Reset Chat Text Size") {
                model.chatText.reset()
            }
                .keyboardShortcut("0", modifiers: [.command, .option])
        }
    }
}
