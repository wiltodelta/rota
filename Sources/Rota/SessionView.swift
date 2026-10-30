import AppKit
import RotaCore
import SwiftUI

/// One session as a chat: the routine's prompt, what the agent said and did,
/// and the user's messages, with a field to write the next one.
struct SessionView: View {
    @Environment(\.interfaceScale) private var metrics
    @Environment(AppModel.self) private var model
    let record: RunRecord
    let routine: Routine
    @State private var transcript = TranscriptSnapshot()
    @State private var reader = TranscriptSessionReader()
    @State private var loadingEarlier = false
    @State private var pageRequest = 0
    /// Messages sent from this view that the session has not shown yet.
    @State private var outbox: [Outgoing] = []
    @State private var questionRevealRequest = 0
    @State private var questionDraft: QuestionDraft?
    @State private var questionDrafts: [String: QuestionDraft] = [:]

    private var running: Bool { model.scheduler.isActive(record) }

    /// The record as the scheduler has it now, with a reply request that came after the view opened.
    private var current: RunRecord {
        if let active = model.scheduler.active[record.routineID], active.id == record.id { return active }
        return record
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.horizontal, metrics.points(20))
                .padding(.vertical, metrics.points(12))
            Divider()
            if !running, current.harness.isAgent, SessionRestart.hitUsageLimit(in: transcript.items) {
                SessionLimitBanner(record: current)
            }
            if current.questions?.isEmpty != false, let question = current.attention {
                AttentionBanner(text: question, canReply: model.scheduler.canMessage(current)) {
                    model.scheduler.dismissAttention(current)
                }
            }
            if let problem = transcript.problem {
                Text(problem)
                    .interfaceFont(.callout)
                    .foregroundStyle(Color.secondaryText)
                    .padding(metrics.points(12))
                    .accessibilityIdentifier("transcriptProblem")
            }
            let items = transcript.items
            let questionID = questionDraft?.question.id
            ChatTranscript(items: items, running: running, record: current,
                           sending: outbox.filter { !$0.delivered(in: items) }.map(\.text),
                           structured: transcript.structured, hasEarlier: transcript.hasEarlier,
                           loadingEarlier: loadingEarlier, loadEarlier: loadEarlier,
                           questionDraft: questionDraft, questionRevealRequest: questionRevealRequest,
                           submitAnswer: { try submitAnswer($0, questionID: questionID) })
            if questionDraft != nil {
                HStack {
                    Text("Needs your reply").interfaceFont(.callout).foregroundStyle(Color.secondaryText)
                    Spacer(minLength: metrics.points(8))
                    Button { questionRevealRequest += 1 } label: {
                        Text("Show Question").interfaceFont(.callout)
                            .padding(.horizontal, metrics.points(10))
                            .frame(minHeight: metrics.points(28))
                            .modifier(ControlSurface(shape: Capsule()))
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("showQuestion")
                }
                .padding(.horizontal, metrics.points(24))
                .padding(.vertical, metrics.points(6))
                .frame(maxWidth: metrics.points(760))
                .frame(maxWidth: .infinity)
            }
            ChatComposer(record: current) { text in
                outbox.append(Outgoing(text: text, seen: Outgoing.count(text, in: items)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onChange(of: current.nextQuestion?.id, initial: true) { _, id in
            if let draft = questionDraft { questionDrafts[draft.question.id] = draft }
            let pending = Set(current.questions?.map(\.id) ?? [])
            questionDrafts = questionDrafts.filter { pending.contains($0.key) }
            questionDraft = id.flatMap { id in
                questionDrafts[id]
                    ?? current.questions?.first(where: { $0.id == id }).map { QuestionDraft(question: $0) }
            }
        }
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

    private func submitAnswer(_ answer: QuestionAnswer, questionID: String?) throws {
        guard let questionID else { throw ControlError("The question is no longer waiting for an answer.") }
        try model.scheduler.answerQuestion(questionID, on: current, answer: answer)
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
        GlassControls(spacing: metrics.points(12)) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: metrics.points(12)) {
                    sessionSummary
                    Spacer(minLength: 12)
                    showRoutine
                    sessionActions
                }
                VStack(alignment: .leading, spacing: metrics.points(8)) {
                    HStack(spacing: metrics.points(12)) {
                        sessionSummary
                        Spacer(minLength: 12)
                        showRoutine
                    }
                    HStack(spacing: metrics.points(12)) {
                        Spacer(minLength: 0)
                        sessionActions
                    }
                }
            }
        }
        .modifier(GlassActionStyle())
    }

    private var sessionSummary: some View {
        VStack(alignment: .leading, spacing: metrics.points(2)) {
            Text(record.startedAt.formatted(date: .abbreviated, time: .shortened))
                .interfaceFont(.callout)
            Text([record.harness.title, record.trigger == .catchUp ? "missed slot, run late" : nil,
                  current.statusTitle].compactMap { $0 }.joined(separator: " \u{00B7} "))
                .interfaceFont(.caption)
                .foregroundStyle(record.outcome.isFailure ? Color.errorText : Color.secondaryText)
        }
    }

    private var showRoutine: some View {
        Button(interfaceTitle: "Show Routine", systemImage: "calendar") { model.selection = .routine(routine.id) }
            .fixedSize()
            .help("Show \(routine.name)'s schedule, settings, and sessions")
            .accessibilityIdentifier("showSessionRoutine")
    }

    private var sessionActions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: metrics.points(12)) { actionButtons }.fixedSize()
            HStack(spacing: metrics.points(12)) { actionButtons.labelStyle(.iconOnly) }.fixedSize()
        }
    }

    /// Labeled actions first, then the icon-only utilities, with Delete last and apart from Stop.
    @ViewBuilder
    private var actionButtons: some View {
        if current.harness.isAgent {
            SessionRestartMenu(record: current)
        }
        // A session that takes messages has Stop beside its field.
        if running && !model.scheduler.canMessage(record) {
            Button(interfaceTitle: "Stop", systemImage: "stop.fill") { model.scheduler.stop(routine.id) }
                .accessibilityIdentifier("stopSession")
        }
        if model.scheduler.terminalCommand(for: record) != nil {
            Button(interfaceTitle: running ? "Open in Terminal" : "Continue in Terminal", systemImage: "terminal") {
                ChatOpener.open(record, workingDirectory: routine.workingDirectory, scheduler: model.scheduler,
                                terminal: model.settings.terminalApp)
            }
            .help(running ? "Open this session in Terminal" : "Continue this session in Terminal")
            .accessibilityIdentifier("openTerminal")
        }
        if let path = record.logPath {
            Button(interfaceTitle: "Show Log in Finder", systemImage: "folder") {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }
            .labelStyle(.iconOnly)
            .help("Show log in Finder")
        }
        Button(interfaceTitle: "Delete Session…", systemImage: "trash", role: .destructive) {
            model.sessionToDelete = record
        }
        .labelStyle(.iconOnly)
        .help("Delete this session and its logs")
        .disabled(!model.scheduler.canDelete(current))
        .accessibilityIdentifier("deleteSession")
    }

}

/// What the session asked the user, above its chat until they answer or dismiss it.
/// A session that takes no message (a command, or one whose routine runs again)
/// cannot be answered here, so the banner asks for a look and a Done instead.
private struct AttentionBanner: View {
    @Environment(\.interfaceScale) private var metrics
    let text: String
    let canReply: Bool
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: metrics.points(10)) {
            Image(systemName: "exclamationmark.bubble.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: metrics.points(2)) {
                Text(canReply ? "Needs your reply" : "Needs your attention")
                    .interfaceFont(.callout).fontWeight(.semibold)
                    .accessibilityIdentifier("attentionBanner")
                Text(text).interfaceFont(.callout).textSelection(.enabled)
            }
            Spacer(minLength: 8)
            Button(interfaceTitle: canReply ? "Dismiss" : "Done", action: dismiss)
                .help(canReply ? "Clear the mark without replying" : "Clear the mark")
                .accessibilityIdentifier("dismissAttention")
        }
        .padding(.horizontal, metrics.points(14))
        .padding(.vertical, metrics.points(10))
        // A card inside the column: an edge-to-edge band shows through the translucent sidebar.
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: metrics.points(10)))
        // The chat's column, so the card lines up with the messages under it.
        .padding(.horizontal, metrics.points(24))
        .padding(.top, metrics.points(12))
        .frame(maxWidth: metrics.points(760))
        .frame(maxWidth: .infinity)
    }
}
