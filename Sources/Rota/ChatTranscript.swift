import AppKit
import RotaCore
import SwiftUI

/// Normalized sessions display ordered entries with durable IDs. Legacy logs
/// keep their inferred turn layout until those sessions leave history.
struct ChatTranscript: View {
    @Environment(\.interfaceScale) private var metrics
    @Environment(AppModel.self) private var model
    let items: [TranscriptItem]
    let running: Bool
    let record: RunRecord
    /// Messages sent and not yet in the log.
    var sending: [String] = []
    var structured = false
    var hasEarlier = false
    var loadingEarlier = false
    var loadEarlier: () -> Void = {}
    var questionDraft: QuestionDraft?
    var submitAnswer: ((QuestionAnswer) throws -> Void)?
    @State private var expandedTools: Set<Int> = []
    @State private var following = true
    @State private var visibleItem: Int?
    @State private var viewport = TranscriptViewport()
    @State private var pageAnchor: TranscriptViewport.Anchor?

    private var working: Bool { running && record.terminalState != .waiting }

    private var closingNote: TranscriptItem? {
        guard !running, record.endedAt != nil, let last = items.last, last.kind == .status,
              last.text.hasPrefix(record.outcome.title + " after ") else { return nil }
        return last
    }

    var body: some View {
        let turns = structured ? [] : TranscriptTurn.group(items)
        let rows = structured ? WorkRow.group(items) : []
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    LazyVStack(alignment: .leading, spacing: metrics.points(22)) {
                        if hasEarlier {
                            Button(interfaceTitle: loadingEarlier ? "Loading…" : "Load Earlier Messages") {
                                following = false
                                pageAnchor = viewport.capture()
                                loadEarlier()
                            }
                            .disabled(loadingEarlier)
                            .frame(maxWidth: .infinity)
                            .accessibilityIdentifier("loadEarlierMessages")
                        }
                        if structured {
                            // The last status belongs to the footer, not a second transcript row.
                            ForEach(rows.dropLast(closingNote == nil ? 0 : 1)) { row in
                                VStack(alignment: .leading, spacing: 0) {
                                    switch row {
                                    case .note(let item):
                                        TranscriptRow(item: item, record: record)
                                            .accessibilityIdentifier("transcriptItem-\(item.id)")
                                    case .tools(let calls):
                                        ToolCallsView(calls: calls, expanded: Binding(
                                            get: { calls.contains { expandedTools.contains($0.id) } },
                                            set: { expanded in
                                                following = false
                                                viewport.cancel()
                                                let anchor = viewport.capture(id: row.id)
                                                if expanded { expandedTools.insert(row.id) } else {
                                                    expandedTools.subtract(calls.map(\.id))
                                                }
                                                if let anchor { viewport.restoreAfterLayout(anchor) }
                                            }))
                                    }
                                }
                                .id(row.id)
                                .background(TranscriptMarker(id: row.id, viewport: viewport))
                            }
                            if working {
                                WorkingLabel(since: model.scheduler.runStartedAt(record))
                            } else if record.endedAt != nil {
                                TurnFooter(record: record, status: closingNote?.text)
                            }
                        } else {
                            ForEach(Array(turns.enumerated()), id: \.element.id) { index, turn in
                                TurnView(turn: turn, isLast: index == turns.count - 1, running: working,
                                         only: turns.count == 1, record: record)
                            }
                        }
                        if !structured && turns.isEmpty && working {
                            WorkingLabel(since: model.scheduler.runStartedAt(record))
                        }
                        ForEach(Array(sending.enumerated()), id: \.offset) { _, text in
                            VStack(alignment: .trailing, spacing: metrics.points(4)) {
                                UserBubble(text: text).opacity(0.6)
                                Text("Sending\u{2026}").font(model.chatText.small).foregroundStyle(Color.secondaryText)
                            }
                            .frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        if let questionDraft, let submitAnswer {
                            QuestionCard(draft: questionDraft, submit: submitAnswer)
                                .id(Int.min + 1)
                                .background(TranscriptMarker(id: Int.min + 1, viewport: viewport))
                        }
                    }
                    .scrollTargetLayout()
                    Color.clear.frame(height: metrics.points(1))
                        .padding(.top, questionDraft == nil ? metrics.points(22) : 0)
                        .id(Int.min)
                }
                .padding(.horizontal, metrics.points(24))
                .padding(.top, metrics.points(20))
                .padding(.bottom, metrics.points(questionDraft == nil ? 20 : 6))
                .frame(maxWidth: metrics.points(760))
                .frame(maxWidth: .infinity)
            }
            // The lazy stack needs this binding to retain the reading position on prepends.
            .scrollPosition(id: $visibleItem, anchor: .top)
            .defaultScrollAnchor(.bottom, for: .initialOffset)
            .onScrollPhaseChange { _, phase, context in
                if phase == .interacting { viewport.cancel() }
                if phase == .interacting || phase == .decelerating || phase == .idle {
                    let geometry = context.geometry
                    following = geometry.contentOffset.y + geometry.containerSize.height
                        >= geometry.contentSize.height - 60
                    if !following { viewport.remember() }
                }
            }
            // Follow the session only while the reader is at its end, as super.engineering does;
            // scrolled up to read, they keep their place and get a button back down.
            .onScrollGeometryChange(for: ScrollSpot.self) { geometry in
                ScrollSpot(offset: geometry.contentOffset.y, height: geometry.contentSize.height,
                           atEnd: geometry.contentOffset.y + geometry.containerSize.height
                               >= geometry.contentSize.height - 60)
            } action: { old, new in
                if new.height != old.height {
                    // The session wrote more: a reader at the end stays there.
                    if following { proxy.scrollTo(Int.min, anchor: .bottom) }
                } else if new.offset != old.offset {
                    // The reader scrolled: following resumes only back at the end.
                    following = new.atEnd
                    if !following { viewport.remember() }
                }
            }
            .onChange(of: questionDraft.map { "\($0.question.id):\($0.fieldIndex)" }) { _, step in
                if step != nil {
                    following = true
                    viewport.cancel()
                    proxy.scrollTo(Int.min + 1, anchor: .top)
                }
            }
            .onChange(of: items) {
                guard !following else { return }
                if let anchor = pageAnchor {
                    // Materialize the old row after a prepend, then correct the lazy estimate.
                    let mapped = TranscriptViewport.Anchor(id: WorkRow.visibleID(for: anchor.id, in: rows),
                                                           offset: anchor.offset, point: anchor.point)
                    proxy.scrollTo(mapped.id, anchor: mapped.point)
                    viewport.restoreAfterLayout(mapped)
                    pageAnchor = nil
                } else if let anchor = viewport.anchorForUpdate() {
                    viewport.restoreAfterLayout(anchor)
                }
            }
            .onChange(of: metrics) {
                if following {
                    proxy.scrollTo(Int.min, anchor: .bottom)
                } else if let anchor = viewport.anchorForUpdate() {
                    proxy.scrollTo(anchor.id, anchor: anchor.point)
                    viewport.restoreAfterLayout(anchor)
                }
            }
            .onDisappear { viewport.cancel() }
            .onChange(of: items.count + sending.count) { if following { proxy.scrollTo(Int.min, anchor: .bottom) } }
            .onAppear { proxy.scrollTo(Int.min, anchor: .bottom) }
            .overlay(alignment: .bottom) {
                // A pending form occupies this viewport; the floating jump button
                // would cover its fields at the minimum window height.
                if !following, questionDraft == nil {
                    Button {
                        following = true
                        viewport.cancel()
                        proxy.scrollTo(Int.min, anchor: .bottom)
                    } label: {
                        Image(systemName: "arrow.down")
                            .interfaceSystemFont(size: 13, weight: .semibold)
                            .frame(width: metrics.points(30), height: metrics.points(30))
                            .background(.regularMaterial, in: Circle())
                            .overlay { Circle().strokeBorder(Color.primary.opacity(0.1)) }
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, metrics.points(12))
                    .help("Scroll to the latest")
                    .accessibilityLabel("Scroll to the latest")
                    .accessibilityIdentifier("scrollToLatest")
                }
            }
        }
        .environment(\.sessionLogURL, record.logPath.map { URL(fileURLWithPath: $0) })
        .background(Color(nsColor: .textBackgroundColor))
    }
}

/// A normalized transcript keeps the adapter's order. It never infers a final
/// answer from the position of the last tool call.
private struct TranscriptRow: View {
    @Environment(\.interfaceScale) private var metrics
    @Environment(AppModel.self) private var model
    let item: TranscriptItem
    let record: RunRecord
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.points(8)) {
            switch item.kind {
            case .user: UserBubble(text: item.text)
            case .agent:
                // The message as the agent wrote it, Markdown included.
                AgentHeader(record: record, copy: item.text, hovering: hovering)
                AnswerView(item: item)
            case .tool:
                HStack(alignment: .firstTextBaseline, spacing: metrics.points(6)) {
                    Image(systemName: "wrench.and.screwdriver")
                    Text(item.text).textSelection(.enabled)
                }
                .font(model.chatText.small)
                .foregroundStyle(Color.secondaryText)
            case .plan: PlanCard(steps: PlanStep.parse(item.text))
            case .output: CodeBox(text: item.text)
            case .status, .error:
                if let title = TranscriptService.title(item.text) {
                    DisclosureGroup(title) {
                        Text(item.text).font(model.chatText.smallCode).textSelection(.enabled)
                    }
                    .font(model.chatText.small)
                    .foregroundStyle(Color.secondaryText)
                    .accessibilityIdentifier("serviceEvent-\(item.id)")
                } else {
                    NoteView(item: item)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onHover { hovering = $0 }
    }
}

private struct TurnView: View {
    @Environment(\.interfaceScale) private var metrics
    @Environment(AppModel.self) private var model
    let turn: TranscriptTurn
    let isLast: Bool
    let running: Bool
    /// The session's only turn, whose length is the session's.
    let only: Bool
    let record: RunRecord
    @State private var hovering = false

    private var live: Bool { isLast && running }
    private var finished: Bool { isLast && !running && record.endedAt != nil }

    /// The status line the footer shows, when the turn ends on one.
    private var closingNote: TranscriptItem? {
        guard finished, let last = turn.notes.last, last.kind == .status else { return nil }
        return last
    }

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.points(12)) {
            if let prompt = turn.prompt {
                UserBubble(text: prompt.text)
            }
            // The agent's part alone shows its Copy button; the prompt has its own.
            VStack(alignment: .leading, spacing: metrics.points(12)) {
                if !turn.work.isEmpty || !turn.answer.isEmpty || live {
                    AgentHeader(record: record, copy: turn.answerMessages.map(\.text).joined(separator: "\n\n"),
                                hovering: hovering)
                        .padding(.top, metrics.points(4))
                }
                if !turn.work.isEmpty || live {
                    WorkSection(items: turn.work, live: live, since: model.scheduler.runStartedAt(record),
                                label: workLabel)
                }
                if let plan = turn.plan {
                    PlanCard(steps: PlanStep.parse(plan.text))
                }
                ForEach(turn.answerMessages) { AnswerView(item: $0) }
                ForEach(turn.notes.filter { $0 != closingNote }) { NoteView(item: $0) }
                if finished {
                    TurnFooter(record: record, status: closingNote?.text)
                }
            }
            .onHover { hovering = $0 }
        }
    }

    /// "Worked for 3m 12s" for a finished session's only turn, else the count of calls.
    private var workLabel: String {
        if only, finished, let ended = record.endedAt {
            return "Worked for " + Elapsed.short(ended.timeIntervalSince(record.startedAt))
        }
        let count = turn.toolCount
        return count == 1 ? "1 tool call" : "\(count) tool calls"
    }

}

private struct UserBubble: View {
    @Environment(\.interfaceScale) private var metrics
    @Environment(AppModel.self) private var model
    let text: String

    @State private var hovering = false

    var body: some View {
        HStack(alignment: .bottom, spacing: metrics.points(6)) {
            Spacer(minLength: 80)
            let message = ChatMessage.decode(text)
            let receipt = QuestionReceipt.decode(message.text)
            if !message.text.isEmpty {
                CopyButton(text: receipt?.summary ?? message.text, help: "Copy Message")
                    .font(model.chatText.small)
                    .foregroundStyle(Color.secondaryText)
                    .opacity(hovering ? 1 : 0)
                    .padding(.bottom, metrics.points(9))
            }
            VStack(alignment: .leading, spacing: metrics.points(8)) {
                if let receipt {
                    Text(receipt.summary).textSelection(.enabled)
                    DisclosureGroup("Answered Question") {
                        ForEach(Array(receipt.questions.enumerated()), id: \.offset) { _, field in
                            Text(field.question).textSelection(.enabled)
                        }
                    }
                    .font(model.chatText.small)
                    .foregroundStyle(Color.secondaryText)
                    .accessibilityIdentifier("questionReceipt")
                } else if !message.text.isEmpty {
                    Text(message.text).textSelection(.enabled)
                }
                if !message.attachments.isEmpty { AttachmentChips(attachments: message.attachments) }
            }
                .font(model.chatText.body)
                .padding(.horizontal, metrics.points(14))
                .padding(.vertical, metrics.points(9))
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: metrics.points(16)))
                .overlay {
                    RoundedRectangle(cornerRadius: metrics.points(16)).strokeBorder(Color.primary.opacity(0.06))
                }
        }
        .onHover { hovering = $0 }
    }
}

/// The session's harness, resolved model and applied effort.
/// With a Copy button at the row's end for the message under it, shown while `hovering`.
private struct AgentHeader: View {
    @Environment(\.interfaceScale) private var metrics
    @Environment(AppModel.self) private var model
    let record: RunRecord
    let copy: String
    let hovering: Bool

    var body: some View {
        HStack(spacing: metrics.points(6)) {
            HStack(spacing: metrics.points(6)) {
                HarnessLogo(harness: record.harness)
                Text(ModelLabel.name(record: record, models: model.settings.models))
                if let effort = ModelLabel.effort(record) {
                    Text(effort).foregroundStyle(Color.secondaryText)
                }
            }
            .accessibilityElement(children: .combine)
            if !copy.isEmpty {
                Spacer(minLength: 0)
                CopyButton(text: copy, help: "Copy Message")
                    .foregroundStyle(Color.secondaryText)
                    .opacity(hovering ? 1 : 0)
            }
        }
        .font(model.chatText.small)
    }
}

private struct AnswerView: View {
    @Environment(AppModel.self) private var model
    let item: TranscriptItem

    var body: some View {
        switch item.kind {
        case .output: CodeBox(text: item.text)
        default: MarkdownText(source: item.text).environment(\.sessionImageItemID, item.id)
        }
    }
}

/// Rota's notes inside the chat: a centered line between rules, or a framed error.
private struct NoteView: View {
    @Environment(\.interfaceScale) private var metrics
    @Environment(AppModel.self) private var model
    let item: TranscriptItem

    var body: some View {
        if item.kind == .error {
            HStack(alignment: .firstTextBaseline, spacing: metrics.points(8)) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.errorText)
                Text(item.text).textSelection(.enabled)
                Spacer(minLength: 0)
            }
            .font(model.chatText.body)
            .padding(.horizontal, metrics.points(14))
            .padding(.vertical, metrics.points(10))
            .background(Color.errorText.opacity(0.06), in: RoundedRectangle(cornerRadius: metrics.points(10)))
            .overlay { RoundedRectangle(cornerRadius: metrics.points(10)).strokeBorder(Color.errorText.opacity(0.45)) }
        } else {
            HStack(spacing: metrics.points(10)) {
                Hairline()
                Text(item.text)
                    .font(model.chatText.small)
                    .foregroundStyle(Color.secondaryText)
                    .textSelection(.enabled)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
                Hairline()
            }
        }
    }
}

/// One completion line with its time, outcome and duration, under a finished turn.
private struct TurnFooter: View {
    @Environment(\.interfaceScale) private var metrics
    @Environment(AppModel.self) private var model
    let record: RunRecord
    let status: String?
    var body: some View {
        HStack(spacing: metrics.points(10)) {
            // Capitalize legacy status text at the start of this clause.
            Text([record.endedAt?.formatted(date: .omitted, time: .shortened),
                  status.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? record.outcome.title]
                .compactMap { $0 }.joined(separator: " \u{00B7} "))
                .foregroundStyle(record.outcome.isFailure ? Color.errorText : Color.secondaryText)
            Hairline()
        }
        .font(model.chatText.small)
        .accessibilityIdentifier("transcriptCompletion")
    }
}

/// The clock before the session has written anything.
private struct WorkingLabel: View {
    @Environment(AppModel.self) private var model
    let since: Date?

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            Text("Working for " + Elapsed.short(since.map { context.date.timeIntervalSince($0) } ?? 0))
                .monospacedDigit()
                .foregroundStyle(Color.secondaryText)
                .shimmering()
        }
        .font(model.chatText.small)
    }
}

struct CodeBox: View {
    @Environment(\.interfaceScale) private var metrics
    @Environment(AppModel.self) private var model
    let text: String

    var body: some View {
        Text(text)
            .font(model.chatText.code)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(metrics.points(12))
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: metrics.points(10)))
            .overlay { RoundedRectangle(cornerRadius: metrics.points(10)).strokeBorder(Color.primary.opacity(0.06)) }
    }
}

struct Hairline: View {
    @Environment(\.interfaceScale) private var metrics
    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(height: metrics.points(1))
            .frame(maxWidth: .infinity)
    }
}

/// Where the chat is scrolled, to tell the reader scrolling from the session writing.
private struct ScrollSpot: Equatable {
    let offset: CGFloat
    let height: CGFloat
    let atEnd: Bool
}
