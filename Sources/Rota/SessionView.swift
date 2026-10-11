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
                AttentionBanner(text: question) { model.scheduler.dismissAttention(current) }
            }
            ChatTranscript(items: Transcript.parse(log, shell: record.harness == .shell), running: running)
            Composer(record: record)
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
                    .foregroundStyle(record.outcome.isFailure ? .red : .secondary)
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
            if running {
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

private struct ChatTranscript: View {
    @Environment(AppModel.self) private var model
    let items: [TranscriptItem]
    let running: Bool

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(items) { item in
                        ChatItemView(item: item)
                    }
                    if running {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Working").foregroundStyle(.secondary)
                        }
                        .font(model.chatText.small)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(20)
                .frame(maxWidth: 820)
                .frame(maxWidth: .infinity)
            }
            .onChange(of: items.count) { proxy.scrollTo("end", anchor: .bottom) }
            .onAppear { proxy.scrollTo("end", anchor: .bottom) }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

private struct ChatItemView: View {
    @Environment(AppModel.self) private var model
    let item: TranscriptItem

    var body: some View {
        let text = model.chatText
        switch item.kind {
        case .user:
            HStack {
                Spacer(minLength: 60)
                Text(item.text)
                    .font(text.body)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
            }
        case .agent:
            MarkdownText(source: item.text)
        case .tool:
            Label(item.text, systemImage: "wrench.and.screwdriver")
                .font(text.smallCode)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.tail)
                // Two lines keep the chat readable; the whole call is a hover away.
                .help(item.text)
        case .status:
            Text(item.text)
                .font(text.small)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        case .error:
            Label(item.text, systemImage: "exclamationmark.triangle.fill")
                .font(text.body)
                .foregroundStyle(.red)
        case .output:
            Text(item.text)
                .font(text.code)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
        }
    }
}

/// The field under the chat: one rounded box holding the message, Stop while
/// the session runs, and Send. Return sends, Option-Return starts a new line.
/// It talks to the live session where the harness allows it, continues a
/// finished session otherwise, and says where to go when neither works.
private struct Composer: View {
    @Environment(AppModel.self) private var model
    let record: RunRecord
    @State private var text = ""
    @FocusState private var focused: Bool

    private var running: Bool { model.scheduler.isActive(record) }
    private var canSend: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        Group {
            if model.scheduler.canMessage(record) {
                VStack(alignment: .leading, spacing: 6) {
                    field
                    HStack {
                        Text(effect)
                        Spacer(minLength: 12)
                        Text("Return to send, Option-Return for a new line")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 4)
                }
            } else if let note {
                Text(note)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        // The chat's column, so the field lines up with the messages above it.
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 14)
        .frame(maxWidth: 820)
        .frame(maxWidth: .infinity)
        // The chat's own background, so the field floats on it rather than on a band.
        .background(Color(nsColor: .textBackgroundColor))
        .task(id: record.id) { focused = true }
    }

    private var field: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(placeholder, text: $text, axis: .vertical)
                .font(model.chatText.body)
                .lineLimit(1...8)
                .textFieldStyle(.plain)
                .focused($focused)
                .onSubmit(send)
                .padding(.vertical, 5)
                .accessibilityIdentifier("composer")
            if running {
                RoundButton(symbol: "stop.fill", fill: Color.secondary.opacity(0.18), foreground: .primary) {
                    model.scheduler.stop(record.routineID)
                }
                .help("Stop the session")
                .accessibilityLabel("Stop")
                .accessibilityIdentifier("composerStop")
            }
            RoundButton(symbol: "arrow.up",
                        fill: canSend ? Color.accentColor : Color.secondary.opacity(0.25),
                        foreground: canSend ? .white : .secondary, action: send)
                .disabled(!canSend)
                .keyboardShortcut(.return, modifiers: .command)
                .help("Send (Return)")
                .accessibilityLabel("Send")
                .accessibilityIdentifier("send")
        }
        .padding(.leading, 14)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 18))
        .overlay {
            RoundedRectangle(cornerRadius: 18)
                .strokeBorder(focused ? Color.accentColor.opacity(0.6) : Color(nsColor: .separatorColor),
                              lineWidth: focused ? 1.5 : 1)
        }
        .shadow(color: .black.opacity(0.06), radius: 6, y: 2)
        .contentShape(RoundedRectangle(cornerRadius: 18))
        .onTapGesture { focused = true }
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
        model.scheduler.message(message, to: record)
        text = ""
    }
}

/// A 28 pt circular icon button, as the composer's Send and Stop.
private struct RoundButton: View {
    let symbol: String
    let fill: Color
    let foreground: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(foreground)
                .frame(width: 28, height: 28)
                .background(fill, in: Circle())
        }
        .buttonStyle(.plain)
    }
}

/// An agent message drawn block by block: headings, lists and code as such,
/// inline Markdown (bold, code spans, links) inside each.
private struct MarkdownText: View {
    @Environment(AppModel.self) private var model
    let source: String

    var body: some View {
        let text = model.chatText
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(MarkdownBlock.parse(source).enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let level, let content):
                    Text(inline(content))
                        .font(text.heading(level: level))
                        .padding(.top, 4)
                case .listItem(let marker, let content, let indent):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(marker).foregroundStyle(.secondary)
                        Text(inline(content))
                    }
                    .font(text.body)
                    .padding(.leading, CGFloat(indent) * 16)
                case .code(let content):
                    Text(content)
                        .font(text.code)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                case .paragraph(let content):
                    Text(inline(content)).font(text.body)
                }
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

/// What the session asked the user, above its chat until they answer or dismiss it.
private struct AttentionBanner: View {
    let text: String
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.bubble.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Needs your reply").font(.callout.weight(.semibold))
                    .accessibilityIdentifier("attentionBanner")
                Text(text).font(.callout).textSelection(.enabled)
            }
            Spacer(minLength: 8)
            Button("Dismiss", action: dismiss)
                .help("Clear the mark without replying")
                .accessibilityIdentifier("dismissAttention")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        // A card inside the column: an edge-to-edge band shows through the translucent sidebar.
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .padding(.horizontal, 20)
        .padding(.top, 12)
    }
}
