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
    @State private var outbox: [(id: String, message: ChatMessage)] = []
    @State private var eventReader = SessionEventReader()
    @State private var readerID: UUID?
    @State private var structuredItems: [TranscriptItem]?

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
            if let reason = current.eventError {
                Label("Could not save session history: " + reason,
                               systemImage: "exclamationmark.triangle.fill")
                    .interfaceFont(.callout)
                    .padding(12)
            }
            if let question = current.attention, current.requests?.isEmpty != false {
                AttentionBanner(text: question, canReply: model.scheduler.canMessage(current)) {
                    model.scheduler.dismissAttention(current)
                }
            }
            if running, let request = current.requests?.first {
                SessionRequestView(request: request) { response in
                    model.scheduler.respond(to: request.id, in: current, response: response)
                }
                .id(request.id)
                .layoutPriority(1)
            }
            let items = conversationItems
            ChatTranscript(items: items, running: running)
                .frame(minHeight: 44)
            Composer(record: current, routine: routine, draft: model.draft(for: record),
                     failedMessage: Self.failedMessage(in: items)) { message, id in
                outbox.append((id, message))
            }
        }
        .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(routine.name)
        .task(id: RefreshKey(record: record.id, running: running, version: model.scheduler.historyVersion)) {
            if readerID != record.id {
                eventReader = SessionEventReader()
                readerID = record.id
                structuredItems = nil
                outbox = []
            }
            // Streamed events append incrementally; legacy logs remain readable.
            repeat {
                readSession()
                try? await Task.sleep(for: .seconds(1))
            } while running && !Task.isCancelled
            // Open and finished: read. A session finishing while open is read too.
            model.scheduler.markRead(record)
        }
    }

    private var conversationItems: [TranscriptItem] {
        var items = structuredItems ?? Transcript.parse(log, shell: record.harness == .shell)
        for message in outbox where !items.contains(where: { $0.sourceID == message.id }) {
            var item = TranscriptItem(id: items.count, kind: .user, text: message.message.text,
                                      turnID: items.last?.turnID ?? message.id)
            item.attachments = message.message.attachments
            item.sourceID = message.id
            item.delivery = running ? .pending : .cancelled
            items.append(item)
        }
        return items
    }

    private static func failedMessage(in items: [TranscriptItem]) -> ChatMessage? {
        guard let last = items.last(where: { $0.kind == .user }) else { return nil }
        switch last.delivery {
        case .failed, .cancelled: return ChatMessage(text: last.text, attachments: last.attachments)
        default: return nil
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
                    .interfaceFont(.callout)
                Text([record.trigger == .catchUp ? "missed slot, run late" : nil,
                      current.outcome.title].compactMap { $0 }.joined(separator: " \u{00B7} "))
                    .interfaceFont(.caption)
                    .foregroundStyle(current.outcome.isFailure ? Color.errorText : Color.secondaryText)
            }
            Spacer(minLength: 8)
            if let path = record.logPath {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                } label: {
                    Label("Show Log in Finder", systemImage: "folder")
                }
                .labelStyle(.iconOnly)
                .help("Show log in Finder")
            }
            if model.scheduler.terminalCommand(for: record) != nil {
                Button {
                    ChatOpener.open(record, workingDirectory: routine.workingDirectory, scheduler: model.scheduler,
                                    terminal: model.settings.terminalApp)
                } label: {
                    Label(running ? "Open in Terminal" : "Continue in Terminal", systemImage: "terminal")
                }
                .accessibilityIdentifier("openTerminal")
                .labelStyle(.iconOnly)
                .help(running ? "Open in Terminal" : "Continue in Terminal")
            }
            // A session that takes messages has Stop beside its field.
            if running && !model.scheduler.canMessage(record) {
                Button { model.scheduler.stop(routine.id) } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                    .accessibilityIdentifier("stopSession")
            }
        }
    }

    private func readSession() {
        guard record.harness.isAgent, let path = record.logPath else {
            log = readLog()
            return
        }
        do {
            if try eventReader.read(from: SessionEventReader.file(for: URL(fileURLWithPath: path))) {
                structuredItems = eventReader.transcript.items
            } else {
                structuredItems = nil
                log = readLog()
            }
        } catch {
            structuredItems = eventReader.transcript.items + [
                TranscriptItem(id: eventReader.transcript.items.count, kind: .error,
                               text: "Could not read session events: " + error.localizedDescription)
            ]
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
                Text(canReply ? "Needs your reply" : "Needs your attention").interfaceFont(.callout, weight: .semibold)
                    .accessibilityIdentifier("attentionBanner")
                Text(text).interfaceFont(.callout).textSelection(.enabled)
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

/// A harness's own mark (`HarnessLogos.xcassets`, sources in `docs/harness-logos.md`):
/// Claude in its orange, the others in the text color; a shell gets the terminal glyph.
struct HarnessLogo: View {
    let harness: Harness

    var body: some View {
        Group {
            if harness == .shell {
                Image(systemName: "apple.terminal")
            } else {
                Image("harness-" + harness.rawValue)
                    .resizable()
                    .renderingMode(.template)
                    .scaledToFit()
            }
        }
        .foregroundStyle(harness == .claude ? Color(red: 0xD9 / 255, green: 0x77 / 255, blue: 0x57 / 255)
                         : Color.primary)
        .frame(width: 14,
               height: 14)
        .accessibilityHidden(true)
    }
}
