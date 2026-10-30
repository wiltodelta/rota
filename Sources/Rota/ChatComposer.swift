import AppKit
import RotaCore
import SwiftUI

/// The field under the chat: a rounded glass shell with a dense reading backing,
/// holding the message and, under it, what the session runs on, Stop while
/// it runs, and Send. Return sends, Option-Return starts a new line. It talks to
/// the live session where the harness allows it, continues a finished session
/// otherwise, and says where to go when neither works.
struct ChatComposer: View {
    @Environment(\.interfaceScale) private var metrics
    @Environment(AppModel.self) private var model
    let record: RunRecord
    /// Called with each message sent, so the chat can show it until the session does.
    let sent: (String) -> Void
    private var input: Binding<String> {
        Binding(get: { model.sessionDrafts[record.id] ?? "" }, set: { value in
            model.sessionDrafts[record.id] = value.isEmpty ? nil : value
        })
    }

    private var text: String {
        get { input.wrappedValue }
        nonmutating set { input.wrappedValue = newValue }
    }
    @FocusState private var focused: Bool
    @State private var legacyModel: String?
    @State private var resolvedConfiguration: SessionConfiguration?
    @State private var resolvingConfiguration = false
    @State private var staging = false
    @State private var choosingFiles = false
    @State private var attachmentError: String?
    @State private var dropTargeted = false

    private var attachments: [ChatAttachment] {
        model.sessionAttachments[record.id] ?? []
    }

    private var hasQuestion: Bool { record.questions?.isEmpty == false }
    private var running: Bool { model.scheduler.isActive(record) }
    private var canSend: Bool {
        model.scheduler.canMessage(record) && !record.hasBlockingQuestion && !staging
            && (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !attachments.isEmpty)
    }

    var body: some View {
        Group {
            if hasQuestion || model.scheduler.canMessage(record) {
                box
            } else if let note {
                Text(note)
                    .interfaceFont(.callout)
                    .foregroundStyle(Color.secondaryText)
                    .frame(maxWidth: .infinity)
            }
        }
        // The chat's column, so the box lines up with the messages above it.
        .padding(.horizontal, metrics.points(24))
        .padding(.top, metrics.points(hasQuestion ? 2 : 6))
        .padding(.bottom, metrics.points(hasQuestion ? 8 : 16))
        .frame(maxWidth: metrics.points(760))
        .frame(maxWidth: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
        .task(id: record.id) {
            focused = true
            resolvedConfiguration = nil
            legacyModel = nil
            resolvingConfiguration = false
            if record.harness == .claude, !running, record.reportedEffort == nil,
               let routine = model.scheduler.routine(record.routineID) {
                resolvingConfiguration = true
                let executable = model.settings.executable(for: .claude)
                let resolved = await Task.detached {
                    ClaudeConfiguration.read(executable: executable, directory: routine.workingDirectory,
                                             model: record.model, effort: record.effort, resume: record.sessionID)
                }.value
                guard !Task.isCancelled else { return }
                resolvedConfiguration = resolved?.session
                resolvingConfiguration = false
            }
            if record.reportedModel == nil, record.model == nil, resolvedConfiguration?.model == nil,
               let path = record.logPath {
                legacyModel = await Task.detached {
                    SessionConfiguration.recordedModel(log: URL(fileURLWithPath: path))
                }.value
            }
        }
    }

    private var box: some View {
        VStack(alignment: .leading, spacing: metrics.points(hasQuestion ? 6 : 10)) {
            if !attachments.isEmpty {
                AttachmentChips(attachments: attachments, remove: removeAttachment)
            }
            TextField(placeholder, text: input, axis: .vertical)
                .font(model.chatText.body)
                .lineSpacing(model.chatText.bodyLineSpacing)
                .lineLimit(hasQuestion ? 1...3 : 2...8)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit(send)
                .help(inputHelp)
                .accessibilityLabel("Message")
                .accessibilityIdentifier("composer")
            GlassControls(spacing: metrics.points(8)) {
                HStack(spacing: metrics.points(8)) {
                    HStack(spacing: metrics.points(6)) {
                        HarnessLogo(harness: record.harness)
                        Text(ModelLabel.model(record: record, models: model.settings.models,
                                              fallback: resolvedConfiguration?.model ?? legacyModel))
                            .truncationMode(.middle)
                        if let effort = resolvingConfiguration ? "Resolving…"
                            : ModelLabel.effort(record, fallback: resolvedConfiguration?.effort) {
                            Text("·")
                            Text(effort).fixedSize()
                        }
                    }
                    .interfaceFont(.callout)
                    .foregroundStyle(Color.secondaryText)
                    .lineLimit(1)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("composerModel")
                    .help("The model and reasoning effort for this session.")
                    Spacer(minLength: 8)
                    if staging {
                        ProgressView().controlSize(.small).frame(width: metrics.points(28), height: metrics.points(28))
                    } else {
                        RoundButton(symbol: "paperclip", filled: false, fill: .accentColor,
                                    foreground: Color.secondaryText, action: chooseAttachments)
                            .disabled(choosingFiles)
                            .help("Attach files, or drag them into this message")
                            .accessibilityLabel("Attach Files")
                            .accessibilityIdentifier("attachFiles")
                    }
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
                                    foreground: canSend ? .white : Color.secondaryText, action: send)
                            .disabled(!canSend)
                            .keyboardShortcut(.return, modifiers: .command)
                            .help("Send (Return)")
                            .accessibilityLabel("Send")
                            .accessibilityIdentifier("send")
                    }
                }
            }
            if record.hasBlockingQuestion {
                Text("Answer the question to send. Your draft is kept.")
                    .interfaceFont(.caption).foregroundStyle(Color.secondaryText)
                    .accessibilityIdentifier("composerBlockingNote")
            }
            if !model.scheduler.canMessage(record), !record.hasBlockingQuestion, let note {
                Text(note).interfaceFont(.caption).foregroundStyle(Color.secondaryText)
            }
            if let attachmentError {
                Text(attachmentError).interfaceFont(.caption).foregroundStyle(Color.errorText)
                    .accessibilityIdentifier("attachmentError")
            }
        }
        .padding(.horizontal, metrics.points(16))
        .padding(.top, metrics.points(hasQuestion ? 10 : 14))
        .padding(.bottom, metrics.points(hasQuestion ? 8 : 10))
        .background {
            ComposerSurface(shape: RoundedRectangle(cornerRadius: metrics.points(20)))
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .overlay {
            RoundedRectangle(cornerRadius: metrics.points(20))
                .strokeBorder(focused || dropTargeted ? Color.accentColor.opacity(0.5) : Color.primary.opacity(0.08),
                              lineWidth: focused || dropTargeted ? 1.5 : 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: metrics.points(20)))
        .onTapGesture { focused = true }
        .dropDestination(for: URL.self) { urls, _ in
            guard !urls.isEmpty, !staging else { return false }
            addAttachments(urls)
            return true
        } isTargeted: { dropTargeted = $0 }
    }

    private func chooseAttachments() {
        guard !choosingFiles else { return }
        choosingFiles = true
        Task {
            defer { choosingFiles = false }
            let panel = NSOpenPanel()
            panel.title = "Attach Files"
            panel.prompt = "Attach"
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = true
            if await panel.begin() == .OK { addAttachments(panel.urls) }
        }
    }

    private func addAttachments(_ urls: [URL]) {
        guard !staging else { return }
        staging = true
        attachmentError = nil
        Task {
            defer { staging = false }
            do {
                let store = try model.scheduler.history.attachments(for: record)
                let files = try await Task.detached { try store.stage(urls) }.value
                guard model.scheduler.current(record.id, routineID: record.routineID) != nil else {
                    for file in files { try? store.discard(file) }
                    return
                }
                model.sessionAttachments[record.id, default: []].append(contentsOf: files)
                focused = true
            } catch {
                attachmentError = "Could not attach files: \(error.localizedDescription)"
            }
        }
    }

    private func removeAttachment(_ attachment: ChatAttachment) {
        do {
            try model.scheduler.history.attachments(for: record).discard(attachment)
            model.sessionAttachments[record.id]?.removeAll { $0.id == attachment.id }
            attachmentError = nil
        } catch {
            attachmentError = "Could not remove the attachment: \(error.localizedDescription)"
        }
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

    private var inputHelp: String {
        return "\(effect) Return sends, Option-Return starts a new line."
    }

    /// What sending does here, which differs by harness and state.
    private var effect: String {
        guard running else { return "Sends a new turn in this session." }
        return [.grok, .antigravity].contains(record.harness)
            ? "Answered after the current turn." : "Joins the current turn."
    }

    /// Why there is no field.
    private var note: String? {
        if record.needsReconciliation == true {
            return "Checking the native session before starting more work. Rota will retry automatically."
        }
        if running, model.scheduler.current(record.id)?.terminalState != nil {
            return "Reply and approve actions in Terminal. Messages sync here automatically."
        }
        switch record.harness {
        case .shell:
            return running ? "Open in Terminal to type into the command." : nil
        default:
            return model.scheduler.active[record.routineID] != nil && !running
                ? "Another session of this routine is running." : nil
        }
    }

    private func send() {
        guard canSend else { return }
        do {
            let message = try ChatMessage(text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                                          attachments: attachments).encoded()
            guard model.scheduler.message(message, to: record) else {
                attachmentError = "The session cannot take a message right now. Your draft is kept."
                return
            }
            sent(message)
            text = ""
            model.sessionAttachments[record.id] = nil
            attachmentError = nil
        } catch {
            attachmentError = "Could not prepare the message: \(error.localizedDescription)"
        }
    }
}

/// Decoration stays separate from the editor so appearance changes preserve its draft and focus.
private struct ComposerSurface: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast
    let shape: RoundedRectangle

    var body: some View {
        if #available(macOS 26, *), !reduceTransparency, contrast != .increased {
            ZStack {
                shape.fill(Color(nsColor: .textBackgroundColor).opacity(0.9))
                Color.clear.glassEffect(.regular, in: shape)
            }
        } else {
            shape.fill(Color(nsColor: .controlBackgroundColor))
                .overlay {
                    if contrast == .increased { shape.strokeBorder(Color.primary.opacity(0.5)) }
                }
        }
    }
}

/// Stop while the session works: a square in a circle, an arc running round it.
private struct StopRingButton: View {
    @Environment(\.interfaceScale) private var metrics
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            TimelineView(.animation(paused: reduceMotion)) { context in
                let turn = reduceMotion ? 0 :
                    context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.2) / 1.2
                ZStack {
                    Image(systemName: "stop.fill")
                        .interfaceSystemFont(size: 11, weight: .bold)
                        .foregroundStyle(Color.errorText)
                    Circle()
                        .trim(from: 0, to: 0.28)
                        .stroke(Color.orange, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .rotationEffect(.degrees(turn * 360))
                        .padding(metrics.points(1))
                }
                .frame(width: metrics.points(28), height: metrics.points(28))
                .modifier(ControlSurface(shape: Circle()))
            }
        }
        .buttonStyle(.plain)
    }
}

/// A compact circular control, with an accent tint when a message is ready to send.
private struct RoundButton: View {
    @Environment(\.interfaceScale) private var metrics
    let symbol: String
    let filled: Bool
    let fill: Color
    let foreground: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .interfaceSystemFont(size: 13, weight: .bold)
                .foregroundStyle(foreground)
                .frame(width: metrics.points(28), height: metrics.points(28))
                .modifier(ControlSurface(shape: Circle(), tint: filled ? fill : nil))
        }
        .buttonStyle(.plain)
    }
}
