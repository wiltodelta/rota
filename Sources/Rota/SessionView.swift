import AppKit
import RotaCore
import SwiftUI

/// One session as a chat: the routine's prompt, what the agent said and did,
/// and the user's messages, with a field to write the next one.
struct SessionView: View {
    @Environment(AppModel.self) private var model
    let record: RunRecord
    let routine: Routine
    @State private var transcript = TranscriptSnapshot()
    @State private var reader = TranscriptSessionReader()
    @State private var loadingEarlier = false
    @State private var pageRequest = 0
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
            if let problem = transcript.problem {
                Text(problem)
                    .font(.callout)
                    .foregroundStyle(Color.secondaryText)
                    .padding(12)
                    .accessibilityIdentifier("transcriptProblem")
            }
            let items = transcript.items
            ChatTranscript(items: items, running: running, record: current,
                           sending: outbox.filter { !$0.delivered(in: items) }.map(\.text),
                           structured: transcript.structured, hasEarlier: transcript.hasEarlier,
                           loadingEarlier: loadingEarlier, loadEarlier: loadEarlier)
            ChatComposer(record: current) { text in
                outbox.append(Outgoing(text: text, seen: Outgoing.count(text, in: items)))
            }
        }
        .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(routine.name)
        .task(id: RefreshKey(record: record.id, running: running, version: model.scheduler.historyVersion)) {
            // Follow the log while the session works; read it once otherwise.
            repeat {
                if let path = record.logPath {
                    let request = pageRequest
                    let next = await reader.read(log: URL(fileURLWithPath: path), shell: record.harness == .shell,
                                           finished: !running)
                    guard !Task.isCancelled else { return }
                    if request == pageRequest, next != transcript { transcript = next }
                }
                try? await Task.sleep(for: .seconds(1))
            } while running && !Task.isCancelled
            // Open and finished: read. A session finishing while open is read too.
            model.scheduler.markRead(record)
        }
    }

    private func loadEarlier() {
        guard !loadingEarlier, let path = record.logPath else { return }
        loadingEarlier = true
        pageRequest += 1
        Task {
            let next = await reader.read(log: URL(fileURLWithPath: path), shell: record.harness == .shell,
                                         finished: !running, earlier: true)
            guard !Task.isCancelled else { return }
            transcript = next
            loadingEarlier = false
        }
    }

    private struct RefreshKey: Equatable {
        let record: UUID
        let running: Bool
        let version: Int
    }

    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                sessionSummary
                Spacer(minLength: 12)
                showRoutine
                sessionActions
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 12) {
                    sessionSummary
                    Spacer(minLength: 12)
                    showRoutine
                }
                HStack(spacing: 12) {
                    Spacer(minLength: 0)
                    sessionActions
                }
            }
        }
    }

    private var sessionSummary: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(record.startedAt.formatted(date: .abbreviated, time: .shortened))
                .font(.callout)
            Text([record.harness.title, record.trigger == .catchUp ? "missed slot, run late" : nil,
                  record.outcome.title].compactMap { $0 }.joined(separator: " \u{00B7} "))
                .font(.caption)
                .foregroundStyle(record.outcome.isFailure ? Color.errorText : Color.secondaryText)
        }
    }

    private var showRoutine: some View {
        Button("Show Routine", systemImage: "calendar") { model.selection = .routine(routine.id) }
            .fixedSize()
            .help("Show \(routine.name)'s schedule, settings, and sessions")
            .accessibilityIdentifier("showSessionRoutine")
    }

    @ViewBuilder
    private var sessionActions: some View {
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
        Button("Delete Session…", systemImage: "trash", role: .destructive) {
            model.sessionToDelete = record
        }
        .labelStyle(.iconOnly)
        .help("Delete this session and its logs")
        .disabled(!model.scheduler.canDelete(current))
        .accessibilityIdentifier("deleteSession")
        // A session that takes messages has Stop beside its field.
        if running && !model.scheduler.canMessage(record) {
            Button("Stop", systemImage: "stop.fill") { model.scheduler.stop(routine.id) }
                .accessibilityIdentifier("stopSession")
        }
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
