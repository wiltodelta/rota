import SwiftUI

/// A message sent with one click from under the chat: a short title on its
/// button and the text the session receives.
struct QuickReply: Codable, Hashable, Identifiable {
    var id = UUID()
    var title: String
    var message: String

    /// The replies Rota ships. Fixed ids let Restore Default Replies add back
    /// only the ones the user deleted.
    static let defaults = [
        QuickReply(id: UUID(uuidString: "6F1C2A3B-0001-4C1A-9E1A-52A2D9A4B001")!, title: "Commit", message: "Commit"),
        QuickReply(id: UUID(uuidString: "6F1C2A3B-0002-4C1A-9E1A-52A2D9A4B002")!, title: "Commit and Push",
                   message: "Commit and push"),
        QuickReply(id: UUID(uuidString: "6F1C2A3B-0003-4C1A-9E1A-52A2D9A4B003")!, title: "Continue",
                   message: "Continue"),
    ]

    /// Option-Command-1 to 9 for the first nine, in the Session menu.
    static func shortcut(at index: Int) -> KeyboardShortcut? {
        index < 9 ? KeyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: [.command, .option]) : nil
    }

    var text: String { message.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The button's name: the title, else the message's first line.
    var label: String {
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? String(text.prefix { !$0.isNewline }) : name
    }
}

extension AppSettings {
    /// The replies with something to send, in the order Settings lists them.
    var sendableReplies: [QuickReply] { quickReplies.filter { !$0.text.isEmpty } }

    var missingDefaultReplies: [QuickReply] {
        QuickReply.defaults.filter { reply in !quickReplies.contains { $0.id == reply.id } }
    }

    /// Each removed default returns to its shipped position, as far as the list allows.
    func restoreDefaultReplies() {
        let present = Set(quickReplies.map(\.id))
        for (index, reply) in QuickReply.defaults.enumerated() where !present.contains(reply.id) {
            quickReplies.insert(reply, at: min(index, quickReplies.count))
        }
    }

    static func storedReplies(_ defaults: UserDefaults) -> [QuickReply] {
        defaults.data(forKey: "quickReplies").flatMap { try? JSONDecoder().decode([QuickReply].self, from: $0) }
            ?? QuickReply.defaults
    }

}

/// The quick replies above the message field: each button sends its message at once
/// and leaves the draft alone. Buttons wrap onto another line in a narrow window.
struct QuickReplyBar: View {
    @Environment(\.interfaceScale) private var metrics
    let replies: [QuickReply]
    let enabled: Bool
    let send: (QuickReply) -> Void

    var body: some View {
        SessionFilterFlow(spacing: metrics.points(6)) {
            ForEach(Array(replies.enumerated()), id: \.element.id) { index, reply in
                button(reply, index: index)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Quick Replies")
        .accessibilityIdentifier("quickReplies")
    }

    private func button(_ reply: QuickReply, index: Int) -> some View {
        Button { send(reply) } label: {
            // A label wider than the window truncates; the flow proposes the row's width.
            Text(reply.label).interfaceFont(.callout).lineLimit(1)
                .padding(.horizontal, metrics.points(10))
                .frame(minHeight: metrics.points(26))
                .modifier(ControlSurface(shape: Capsule()))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help("Send \u{201C}\(reply.text)\u{201D}"
              + (QuickReply.shortcut(at: index) == nil ? "" : " (Option-Command-\(index + 1))"))
        .accessibilityIdentifier("quickReply-\(index + 1)")
    }
}

/// Settings > Chat: the replies under every chat, editable, removable and restorable.
struct QuickRepliesSection: View {
    @Environment(\.interfaceScale) private var metrics
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var settings = model.settings
        Section {
            ForEach($settings.quickReplies) { $reply in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    TextField("Title", text: $reply.title, prompt: Text("Title"))
                        .frame(width: metrics.points(150))
                        .accessibilityIdentifier("quickReplyTitle")
                    TextField("Message", text: $reply.message, prompt: Text("Message to send"), axis: .vertical)
                        .lineLimit(1...4)
                        .accessibilityIdentifier("quickReplyMessage")
                    Button {
                        let id = reply.id
                        settings.quickReplies.removeAll { $0.id == id }
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .help("Remove this reply")
                    .accessibilityLabel("Remove \(reply.label)")
                    .accessibilityIdentifier("removeQuickReply")
                }
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
            }
            HStack {
                Button(interfaceTitle: "Add Reply") {
                    settings.quickReplies.append(QuickReply(title: "", message: ""))
                }
                .accessibilityIdentifier("addQuickReply")
                if !settings.missingDefaultReplies.isEmpty {
                    Button(interfaceTitle: "Restore Default Replies") { settings.restoreDefaultReplies() }
                        .accessibilityIdentifier("restoreQuickReplies")
                }
            }
        } header: {
            Text("Quick Replies")
        } footer: {
            Text("Buttons above the message field send these at once, the first nine also "
                 + "with Option-Command-1 to 9.")
                .foregroundStyle(Color.secondaryText)
        }
    }
}
