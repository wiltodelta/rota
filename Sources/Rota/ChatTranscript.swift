import AppKit
import RotaCore
import SwiftUI

/// One native text buffer lets selection span paragraphs, lists, code and multiple messages.
struct ChatTranscript: View {
    @Environment(AppModel.self) private var model
    let items: [TranscriptItem]
    let running: Bool
    @State private var activity: [Int: Bool] = [:]

    var body: some View {
        let style = TranscriptStyle(family: model.chatText.family, codeFamily: model.chatText.codeFamily,
                                    size: model.chatText.size)
        NativeTranscript(document: TranscriptDocument(style: style).make(items: items, running: running,
                                                            activity: activity)) { id in
            activity[id] = !(activity[id] ?? false)
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

/// The session's reported model wins over its immutable launch settings.
enum ModelLabel {
    static func modelID(harness: Harness, routine: Routine, record: RunRecord? = nil) -> String? {
        if let actual = nonempty(record?.metadata?.model) { return actual }
        if let configuration = record?.configuration { return nonempty(configuration.model) }
        return harness == routine.harness ? nonempty(routine.model) : nil
    }

    static func name(harness: Harness, routine: Routine, models: [Harness: [ModelOption]],
                     record: RunRecord? = nil) -> String {
        guard let id = modelID(harness: harness, routine: routine, record: record) else { return harness.title }
        let title = displayName(id, harness: harness, models: models)
        return "\(harness.title) \u{00B7} \(title)"
    }

    private static func displayName(_ id: String, harness: Harness, models: [Harness: [ModelOption]]) -> String {
        if let title = nonempty(models[harness]?.first(where: { $0.id == id })?.title), title != id { return title }
        let parts = id.split(separator: "-", omittingEmptySubsequences: false)
        guard harness == .claude, parts.count >= 3, parts.first == "claude",
              parts[1].allSatisfy({ $0.isASCII && $0.isLowercase }), !parts[1].isEmpty else { return id }
        var version = Array(parts.dropFirst(2))
        if version.count > 1, let snapshot = version.last, snapshot.count == 8,
           snapshot.allSatisfy({ $0.isASCII && $0.isNumber }) {
            version.removeLast()
        }
        guard (1...2).contains(version.count), version.allSatisfy({
            !$0.isEmpty && $0.count <= 2 && $0.allSatisfy { $0.isASCII && $0.isNumber }
        }) else { return id }
        return parts[1].capitalized + " " + version.joined(separator: ".")
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let text = value?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
        return text
    }
}
