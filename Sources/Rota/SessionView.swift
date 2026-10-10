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

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
            Divider()
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
                    ChatOpener.open(record, workingDirectory: routine.workingDirectory, scheduler: model.scheduler)
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

/// The message field. It talks to the live session where the harness allows it,
/// continues a finished session otherwise, and says where to go when neither works.
private struct Composer: View {
    @Environment(AppModel.self) private var model
    let record: RunRecord
    @State private var text = ""

    var body: some View {
        if model.scheduler.canMessage(record) {
            HStack(alignment: .bottom, spacing: 8) {
                TextField(placeholder, text: $text, axis: .vertical)
                    .font(model.chatText.body)
                    .lineLimit(1...6)
                    .textFieldStyle(.plain)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.separator))
                    .onSubmit(send)
                    .accessibilityIdentifier("composer")
                Button("Send", systemImage: "arrow.up.circle.fill", action: send)
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .font(.title)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .keyboardShortcut(.return, modifiers: .command)
                    .help("Send (Command-Return)")
                    .accessibilityIdentifier("send")
            }
            .padding(12)
            .background(.bar)
        } else if let note {
            Text(note)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(12)
                .background(.bar)
        }
    }

    private var placeholder: String {
        model.scheduler.isActive(record) ? "Message the running session" : "Continue this session"
    }

    /// Why there is no field.
    private var note: String? {
        let running = model.scheduler.isActive(record)
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
