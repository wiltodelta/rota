import AppKit
import RotaCore
import SwiftUI
import UniformTypeIdentifiers

/// The field under the chat, as super.engineering draws it: one rounded gray
/// box holding the message and, under it, what the session runs on, Stop while
/// it runs, and Send. Return sends, Option-Return starts a new line. It talks to
/// the live session where the harness allows it, continues a finished session
/// otherwise, and says where to go when neither works.
struct Composer: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(AppModel.self) private var model
    let record: RunRecord
    let routine: Routine
    @Bindable var draft: ChatDraft
    let failedMessage: ChatMessage?
    /// Called with each message sent, so the chat can show it until the session does.
    let sent: (ChatMessage, String) -> Void
    @State private var choosingFiles = false
    @State private var attachmentError: String?
    @FocusState private var focused: Bool

    private var running: Bool { model.scheduler.isActive(record) }
    private var answeringRequest: Bool { record.requests?.isEmpty == false }
    private var compact: Bool { answeringRequest || !draft.attachments.isEmpty || attachmentError != nil }

    private var visibleLines: ClosedRange<Int> { compact ? 1...2 : 2...8 }
    private var canSend: Bool {
        !draft.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !draft.attachments.isEmpty
    }

    var body: some View {
        Group {
            if model.scheduler.canMessage(record) {
                box
            } else if let note {
                Text(note)
                    .interfaceFont(.callout)
                    .foregroundStyle(Color.secondaryText)
                    .frame(maxWidth: .infinity)
            }
        }
        // The chat's column, so the box lines up with the messages above it.
        .padding(.horizontal, 24)
        .padding(.top, 6)
        .padding(.bottom, 16)
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .task(id: record.id) { focused = true }
        .fileImporter(isPresented: $choosingFiles, allowedContentTypes: [.item],
                      allowsMultipleSelection: true) { result in
            do { try addAttachments(result.get()) } catch { attachmentError = error.localizedDescription }
        }
        .onDrop(of: [UTType.fileURL.identifier], isTargeted: nil) { providers in
            guard model.scheduler.canMessage(record) else { return false }
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, error in
                    Task { @MainActor in
                        do {
                            if let error { throw error }
                            if let url { try addAttachments([url]) }
                        } catch { attachmentError = error.localizedDescription }
                    }
                }
            }
            return !providers.isEmpty
        }
    }

    private var box: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let failedMessage, draft.text.isEmpty, draft.attachments.isEmpty {
                let notice = Label("Message not delivered", systemImage: "exclamationmark.triangle.fill")
                let restore = Button("Restore Message") {
                    draft.text = failedMessage.text; draft.attachments = failedMessage.attachments; focused = true
                }
                .accessibilityIdentifier("restoreMessage")
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) {
                        notice.fixedSize()
                        Spacer(minLength: 8)
                        restore.fixedSize()
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        notice.fixedSize(horizontal: false, vertical: true)
                        restore
                    }
                }
                .interfaceFont(.callout)
            }
            if let attachmentError {
                Label(attachmentError, systemImage: "exclamationmark.triangle.fill")
                    .interfaceFont(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("attachmentError")
            }
            if !draft.attachments.isEmpty {
                ChatAttachmentStrip(files: draft.attachments) { id in draft.attachments.removeAll { $0.id == id } }
            }
            input
            HStack(spacing: 8) {
                Button { choosingFiles = true } label: { Image(systemName: "paperclip") }
                    .frame(width: 28, height: 28)
                    .help("Attach files and images (up to 10 files, 20 MB each)")
                    .accessibilityLabel("Attach Files…")
                    .accessibilityIdentifier("attachFiles")
                HStack(spacing: 5) {
                    HarnessLogo(harness: record.harness)
                    Text(ModelLabel.name(harness: record.harness, routine: routine,
                                         models: model.settings.models, record: record))
                        .foregroundStyle(Color.primary.opacity(0.82))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .truncationMode(.middle)
                        .help(ModelLabel.modelID(harness: record.harness, routine: routine, record: record)
                              ?? record.harness.title)
                        .accessibilityIdentifier("composerModel")
                    if let effort = record.metadata?.effort ?? record.configuration?.effort {
                        Text(effort.capitalized).foregroundStyle(Color.secondaryText)
                    }
                }
                .interfaceFont(.callout)
                .foregroundStyle(Color.secondaryText)
                .lineLimit(1)
                Spacer(minLength: 8)
                // As super.engineering's: while the session works, its clock, and Stop in Send's
                // place until there is something to send.
                if running, let since = model.scheduler.runStartedAt(record) {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(Self.clock(context.date.timeIntervalSince(since)))
                            .interfaceFont(.callout).monospacedDigit()
                            .foregroundStyle(Color.secondaryText)
                    }
                }
                if running && !canSend {
                    StopRingButton { model.scheduler.stop(record.routineID) }
                        .help("Stop the session")
                        .accessibilityLabel("Stop")
                        .accessibilityIdentifier("composerStop")
                } else {
                    RoundButton(symbol: "arrow.up", filled: canSend, fill: Color.accentColor,
                                foreground: canSend ? AccentInk.accentInk(for: colorScheme)
                                    : Color.secondaryText, action: send)
                        .disabled(!canSend)
                        .keyboardShortcut(.return, modifiers: .command)
                        .help("Send (Return)")
                        .accessibilityLabel("Send")
                        .accessibilityIdentifier("send")
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 20))
        .overlay {
            RoundedRectangle(cornerRadius: 20)
                .strokeBorder(focused ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.08),
                              lineWidth: focused ? 1.5 : 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 20))
        .onTapGesture { focused = true }
    }

    private var input: some View {
        TextField(placeholder, text: $draft.text, axis: .vertical)
            .font(model.chatText.body())
            .lineLimit(visibleLines)
            .textFieldStyle(.plain)
            .focused($focused)
            .onSubmit(send)
            .help("\(effect) Return sends, Option-Return starts a new line.")
            .accessibilityIdentifier("composer")
    }

    /// "0:21", "12:05", "1:02:05".
    static func clock(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        let minutes = String(format: "%02d", seconds / 60 % 60)
        let rest = String(format: "%02d", seconds % 60)
        return seconds >= 3600 ? "\(seconds / 3600):\(minutes):\(rest)" : "\(seconds / 60):\(rest)"
    }

    private var placeholder: String {
        running ? "Message the running session" : "Continue this session"
    }

    /// What sending does here, which differs by harness and state.
    private var effect: String {
        guard running else { return "Sends a new turn in this session." }
        return "Joins the current turn when the harness accepts it."
    }

    /// Why there is no field.
    private var note: String? {
        switch record.harness {
        case .shell:
            return running ? "Open in Terminal to type into the command." : nil
        default:
            return model.scheduler.active[record.routineID] != nil && !running
                ? "Another session of this routine is running." : nil
        }
    }

    private func addAttachments(_ urls: [URL]) throws {
        let new = try urls.filter { url in !draft.attachments.contains { $0.url == url } }.map(ChatAttachment.inspect)
        guard draft.attachments.count + new.count <= 10 else {
            throw AttachmentError.invalid("Attach up to 10 files per message.")
        }
        draft.attachments += new
        attachmentError = nil
    }

    private func send() {
        let message = ChatMessage(text: draft.text.trimmingCharacters(in: .whitespacesAndNewlines),
                                  attachments: draft.attachments)
        guard canSend else { return }
        do {
            guard let id = try model.scheduler.message(message, to: record) else { return }
            sent(message, id)
            draft.text = ""
            draft.attachments = []
            attachmentError = nil
        } catch { attachmentError = error.localizedDescription }
    }
}

/// Stop while the session works: a square in a circle, an arc running round it.
private struct StopRingButton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            TimelineView(.animation(paused: reduceMotion)) { context in
                let turn = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.2) / 1.2
                ZStack {
                    Circle().fill(Color.primary.opacity(0.08))
                    Image(systemName: "stop.fill").interfaceFont(size: 11, weight: .bold)
                        .foregroundStyle(Color.errorText)
                    Circle()
                        .trim(from: 0, to: 0.28)
                        .stroke(Color.orange, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(turn * 360))
                        .padding(1)
                }
                .frame(width: 28, height: 28)
            }
        }
        .buttonStyle(.plain)
    }
}

/// A 28 pt circular icon button, as the composer's Send and Stop: filled when
/// it acts, an outlined circle when it waits, as super.engineering's Send does.
private struct RoundButton: View {
    let symbol: String
    let filled: Bool
    let fill: Color
    let foreground: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol).interfaceFont(size: 13, weight: .bold)
                .foregroundStyle(foreground)
                .frame(width: 28, height: 28)
                .background(filled ? fill : .clear, in: Circle())
                .overlay { if !filled { Circle().strokeBorder(Color.secondary.opacity(0.5)) } }
        }
        .buttonStyle(.plain)
    }
}
