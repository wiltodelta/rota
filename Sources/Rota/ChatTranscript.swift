import AppKit
import RotaCore
import SwiftUI

/// One native text buffer lets selection span paragraphs, lists, code and multiple messages.
struct ChatTranscript: View {
    @Environment(AppModel.self) private var model
    let items: [TranscriptItem]
    let running: Bool
    let record: RunRecord
    @State private var activity: [Int: Bool] = [:]

    var body: some View {
        let style = TranscriptStyle(family: model.chatText.family, codeFamily: model.chatText.codeFamily,
                                    size: model.chatText.size)
        NativeTranscript(document: TranscriptDocument(style: style).make(items: items, record: record, running: running,
                                                            activity: activity)) { id in
            let live = running && TranscriptTurn.group(items).last?.id == id
            activity[id] = !(activity[id] ?? live)
        }
    }
}

private struct NativeTranscript: NSViewRepresentable {
    let document: NSAttributedString
    let toggle: (Int) -> Void

    func makeNSView(context: Context) -> TranscriptScrollView { TranscriptScrollView() }

    func updateNSView(_ view: TranscriptScrollView, context: Context) {
        view.activityToggled = toggle
        view.update(document)
    }
}

/// The harness, and the model when the routine picked one, by the title its CLI lists.
enum ModelLabel {
    static func name(harness: Harness, routine: Routine, models: [Harness: [ModelOption]],
                     record: RunRecord? = nil) -> String {
        if let actual = record?.metadata?.model { return harness.title + "  " + actual }
        let requested = record?.configuration.map(\.model) ?? (harness == routine.harness ? routine.model : nil)
        guard let id = requested else { return harness.title }
        let title = models[harness]?.first { $0.id == id }?.title ?? id
        return "\(harness.title)  \(title)"
    }
}
