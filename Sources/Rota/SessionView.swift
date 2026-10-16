import AppKit
import RotaCore
import SwiftUI

/// One session as a chat: the routine's prompt, what the agent said and did,
/// and the user's messages, with a field to write the next one.
struct SessionView: View {
    @Environment(AppModel.self) private var model
    let record: RunRecord
    let routine: Routine
    @State private var log = ""
    /// Messages sent from this view that the session has not shown yet.
    @State private var outbox: [Outgoing] = []

    private var running: Bool { model.scheduler.isActive(record) }

    /// The record as the scheduler has it now, with a reply request that came after the view opened.
    private var current: RunRecord {
        _ = model.scheduler.historyVersion
        return model.scheduler.current(record.id, routineID: record.routineID) ?? record
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            Divider()
            if let question = current.attention {
                AttentionBanner(text: question, canReply: model.scheduler.canMessage(current)) {
                    model.scheduler.dismissAttention(current)
                }
            }
            let items = Transcript.parse(log, shell: record.harness == .shell)
            ChatTranscript(items: items, running: running, record: record,
                           sending: outbox.filter { !$0.delivered(in: items) }.map(\.text))
            Composer(record: record) { text in
                outbox.append(Outgoing(text: text, seen: Outgoing.count(text, in: items)))
            }
        }
        .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(routine.name)
        .task(id: RefreshKey(record: record.id, running: running, version: model.scheduler.historyVersion)) {
            // Follow the log while the session works; read it once otherwise.
            repeat {
                log = readLog()
                try? await Task.sleep(for: .seconds(1))
            } while running && !Task.isCancelled
            // Open and finished: read. A session finishing while open is read too.
            model.scheduler.markRead(record)
        }
    }

    private struct RefreshKey: Equatable {
        let record: UUID
        let running: Bool
        let version: Int
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(record.startedAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.callout)
                Text([record.harness.title, record.trigger == .catchUp ? "missed slot, run late" : nil,
                      record.outcome.title].compactMap { $0 }.joined(separator: " \u{00B7} "))
                    .font(.caption)
                    .foregroundStyle(record.outcome.isFailure ? Color.errorText : Color.secondaryText)
            }
            Spacer()
            if let path = record.logPath {
                Button("Show Log in Finder", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
                .labelStyle(.iconOnly)
                .help("Show log in Finder")
            }
            if model.scheduler.terminalCommand(for: record) != nil {
                Button(running ? "Open in Terminal" : "Continue in Terminal", systemImage: "terminal") {
                    ChatOpener.open(record, workingDirectory: routine.workingDirectory, scheduler: model.scheduler,
                                    terminal: model.settings.terminalApp)
                }
                .accessibilityIdentifier("openTerminal")
            }
            // A session that takes messages has Stop beside its field.
            if running && !model.scheduler.canMessage(record) {
                Button("Stop", systemImage: "stop.fill") { model.scheduler.stop(routine.id) }
                    .accessibilityIdentifier("stopSession")
            }
        }
    }

    /// The last 400 KB: a whole session for any routine so far, without loading a runaway log.
    private func readLog() -> String {
        guard let path = record.logPath, let handle = FileHandle(forReadingAtPath: path) else { return "" }
        defer { try? handle.close() }
        let limit: UInt64 = 400_000
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > limit ? size - limit : 0)
        return lossyUTF8((try? handle.readToEnd()) ?? Data())
    }
}

/// The field under the chat, as super.engineering draws it: one rounded gray
/// box holding the message and, under it, what the session runs on, Stop while
/// it runs, and Send. Return sends, Option-Return starts a new line. It talks to
/// the live session where the harness allows it, continues a finished session
/// otherwise, and says where to go when neither works.
private struct Composer: View {
    @Environment(AppModel.self) private var model
    let record: RunRecord
    /// Called with each message sent, so the chat can show it until the session does.
    let sent: (String) -> Void
    private var text: String {
        get { model.sessionDrafts[record.id] ?? "" }
        nonmutating set { model.sessionDrafts[record.id] = newValue.isEmpty ? nil : newValue }
    }
    @FocusState private var focused: Bool

    private var running: Bool { model.scheduler.isActive(record) }
    private var canSend: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        Group {
            if model.scheduler.canMessage(record) {
                box
            } else if let note {
                Text(note)
                    .font(.callout)
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
    }

    private var box: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(placeholder, text: Binding(get: { text }, set: { text = $0 }), axis: .vertical)
                .font(model.chatText.body)
                .lineLimit(2...8)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit(send)
                .help("\(effect) Return sends, Option-Return starts a new line.")
                .accessibilityIdentifier("composer")
            HStack(spacing: 8) {
                HStack(spacing: 5) {
                    HarnessLogo(harness: record.harness)
                    Text(ModelLabel.name(record: record, models: model.settings.models))
                    if let effort = record.effort {
                        Text(effort.capitalized).foregroundStyle(Color.secondaryText)
                    }
                }
                .font(.callout)
                .foregroundStyle(Color.secondaryText)
                .lineLimit(1)
                Spacer(minLength: 8)
                // As super.engineering's: while the session works, its clock, and Stop in Send's
                // place until there is something to send.
                if running, let since = model.scheduler.runStartedAt(record) {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text(Self.clock(context.date.timeIntervalSince(since)))
                            .font(.callout.monospacedDigit())
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
        return record.harness == .grok ? "Answered after the current turn." : "Joins the current turn."
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

    private func send() {
        let message = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !message.isEmpty else { return }
        sent(message)
        model.scheduler.message(message, to: record)
        text = ""
    }
}

/// Stop while the session works: a square in a circle, an arc running round it.
private struct StopRingButton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            TimelineView(.animation(paused: reduceMotion)) { context in
                let turn = reduceMotion ? 0 :
                    context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.2) / 1.2
                ZStack {
                    Circle().fill(Color.primary.opacity(0.08))
                    Image(systemName: "stop.fill")
                        .font(.system(size: 11, weight: .bold))
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
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(foreground)
                .frame(width: 28, height: 28)
                .background(filled ? fill : .clear, in: Circle())
                .overlay { if !filled { Circle().strokeBorder(Color.secondary.opacity(0.5)) } }
        }
        .buttonStyle(.plain)
    }
}

/// What the session asked the user, above its chat until they answer or dismiss it.
/// A session that takes no message (a command, or one whose routine runs again)
/// cannot be answered here, so the banner asks for a look and a Done instead.
private struct AttentionBanner: View {
    let text: String
    let canReply: Bool
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.bubble.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(canReply ? "Needs your reply" : "Needs your attention").font(.callout.weight(.semibold))
                    .accessibilityIdentifier("attentionBanner")
                Text(text).font(.callout).textSelection(.enabled)
            }
            Spacer(minLength: 8)
            Button(canReply ? "Dismiss" : "Done", action: dismiss)
                .help(canReply ? "Clear the mark without replying" : "Clear the mark")
                .accessibilityIdentifier("dismissAttention")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        // A card inside the column: an edge-to-edge band shows through the translucent sidebar.
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        // The chat's column, so the card lines up with the messages under it.
        .padding(.horizontal, 24)
        .padding(.top, 12)
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
    }
}
