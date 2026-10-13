import SwiftUI

/// Observe preferences in a view so shortcut availability updates between menu openings.
struct ZoomMenuItems: View {
    @State private var model = AppModel.shared

    var body: some View {
        Group {
            Button("Increase App Zoom") { model.appZoom.increase() }
                .keyboardShortcut("=")
                .disabled(model.appZoom.percent >= AppZoomSettings.range.upperBound)
            Button("Decrease App Zoom") { model.appZoom.decrease() }
                .keyboardShortcut("-")
                .disabled(model.appZoom.percent <= AppZoomSettings.range.lowerBound)
            Button("Reset App Zoom") { model.appZoom.reset() }
                .keyboardShortcut("0")
            Divider()
            Button("Increase Chat Text Size") {
                model.chatText.bigger(appScale: model.appZoom.scale)
            }
                .keyboardShortcut("=", modifiers: [.command, .option])
                .disabled(!model.chatText.canIncrease(appScale: model.appZoom.scale))
            Button("Decrease Chat Text Size") {
                model.chatText.smaller(appScale: model.appZoom.scale)
            }
                .keyboardShortcut("-", modifiers: [.command, .option])
                .disabled(!model.chatText.canDecrease(appScale: model.appZoom.scale))
            Button("Reset Chat Text Size") {
                model.chatText.reset(appScale: model.appZoom.scale)
            }
                .keyboardShortcut("0", modifiers: [.command, .option])
        }
    }
}
