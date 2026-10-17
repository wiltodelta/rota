import AppKit
import RotaCore
import SwiftUI

/// Normalized sessions display ordered entries with durable IDs. Legacy logs
/// keep their inferred turn layout until those sessions leave history.
struct ChatTranscript: View {
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
    @State private var expandedTools: Set<Int> = []
    @State private var following = true
    @State private var visibleItem: Int?
    @State private var viewport = TranscriptViewport()
    @State private var pageAnchor: TranscriptViewport.Anchor?

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
                LazyVStack(alignment: .leading, spacing: 22) {
                    if hasEarlier {
                        Button(loadingEarlier ? "Loading…" : "Load Earlier Messages") {
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
                        if running {
                            WorkingLabel(since: model.scheduler.runStartedAt(record))
                        } else if record.endedAt != nil {
                            TurnFooter(record: record, status: closingNote?.text)
                        }
                    } else {
                        ForEach(Array(turns.enumerated()), id: \.element.id) { index, turn in
                            TurnView(turn: turn, isLast: index == turns.count - 1, running: running,
                                     only: turns.count == 1, record: record)
                        }
                    }
                    if !structured && turns.isEmpty && running {
                        WorkingLabel(since: model.scheduler.runStartedAt(record))
                    }
                    ForEach(Array(sending.enumerated()), id: \.offset) { _, text in
                        VStack(alignment: .trailing, spacing: 4) {
                            UserBubble(text: text).opacity(0.6)
                            Text("Sending\u{2026}").font(model.chatText.small).foregroundStyle(Color.secondaryText)
                        }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    Color.clear.frame(height: 1).id(Int.min)
                }
                .scrollTargetLayout()
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
            }
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
            .onDisappear { viewport.cancel() }
            .onChange(of: items.count + sending.count) { if following { proxy.scrollTo(Int.min, anchor: .bottom) } }
            .onAppear { proxy.scrollTo(Int.min, anchor: .bottom) }
            .overlay(alignment: .bottom) {
                if !following {
                    Button {
                        following = true
                        viewport.cancel()
                        proxy.scrollTo(Int.min, anchor: .bottom)
                    } label: {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 13, weight: .semibold))
                            .frame(width: 30, height: 30)
                            .background(.regularMaterial, in: Circle())
                            .overlay { Circle().strokeBorder(Color.primary.opacity(0.1)) }
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 12)
                    .help("Scroll to the latest")
                    .accessibilityLabel("Scroll to the latest")
                    .accessibilityIdentifier("scrollToLatest")
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }
}

/// A normalized transcript keeps the adapter's order. It never infers a final
/// answer from the position of the last tool call.
private struct TranscriptRow: View {
    @Environment(AppModel.self) private var model
    let item: TranscriptItem
    let record: RunRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch item.kind {
            case .user: UserBubble(text: item.text)
            case .agent:
                AgentHeader(record: record)
                AnswerView(item: item)
            case .tool:
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "wrench.and.screwdriver")
                    Text(item.text).textSelection(.enabled)
                }
                .font(model.chatText.small)
                .foregroundStyle(Color.secondaryText)
            case .plan: PlanCard(steps: PlanStep.parse(item.text))
            case .output: CodeBox(text: item.text)
            case .status, .error: NoteView(item: item)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct TurnView: View {
    @Environment(AppModel.self) private var model
    let turn: TranscriptTurn
    let isLast: Bool
    let running: Bool
    /// The session's only turn, whose length is the session's.
    let only: Bool
    let record: RunRecord

    private var live: Bool { isLast && running }
    private var finished: Bool { isLast && !running && record.endedAt != nil }

    /// The status line the footer shows, when the turn ends on one.
    private var closingNote: TranscriptItem? {
        guard finished, let last = turn.notes.last, last.kind == .status else { return nil }
        return last
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let prompt = turn.prompt {
                UserBubble(text: prompt.text)
            }
            if !turn.work.isEmpty || !turn.answer.isEmpty || live {
                AgentHeader(record: record)
                    .padding(.top, 4)
            }
            if !turn.work.isEmpty || live {
                WorkSection(items: turn.work, live: live, since: model.scheduler.runStartedAt(record),
                            label: workLabel)
            }
            if let plan = turn.plan {
                PlanCard(steps: PlanStep.parse(plan.text))
            }
            ForEach(turn.answer) { AnswerView(item: $0) }
            ForEach(turn.notes.filter { $0 != closingNote }) { NoteView(item: $0) }
            if finished {
                TurnFooter(record: record, status: closingNote?.text)
            }
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
    @Environment(AppModel.self) private var model
    let text: String

    var body: some View {
        HStack {
            Spacer(minLength: 80)
            Text(text)
                .font(model.chatText.body)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 16))
                .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.06)) }
        }
    }
}

/// "Codex  GPT-6.1-Sol  High": what the answer below came from.
private struct AgentHeader: View {
    @Environment(AppModel.self) private var model
    let record: RunRecord

    var body: some View {
        HStack(spacing: 6) {
            HarnessLogo(harness: record.harness)
            Text(ModelLabel.name(record: record, models: model.settings.models))
            if let effort = record.effort {
                Text(effort.capitalized).foregroundStyle(Color.secondaryText)
            }
        }
        .font(model.chatText.small)
        .accessibilityElement(children: .combine)
    }
}

/// The harness, and the model when the routine picked one, by the title its CLI lists.
enum ModelLabel {
    static func name(record: RunRecord, models: [Harness: [ModelOption]]) -> String {
        guard let id = record.model else { return record.harness.title }
        let title = models[record.harness]?.first { $0.id == id }?.title ?? id
        return "\(record.harness.title)  \(title)"
    }
}

private struct AnswerView: View {
    @Environment(AppModel.self) private var model
    let item: TranscriptItem

    var body: some View {
        switch item.kind {
        case .output: CodeBox(text: item.text)
        default: MarkdownText(source: item.text)
        }
    }
}

/// Rota's notes inside the chat: a centered line between rules, or a framed error.
private struct NoteView: View {
    @Environment(AppModel.self) private var model
    let item: TranscriptItem

    var body: some View {
        if item.kind == .error {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Color.errorText)
                Text(item.text).textSelection(.enabled)
                Spacer(minLength: 0)
            }
            .font(model.chatText.body)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.errorText.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Color.errorText.opacity(0.45)) }
        } else {
            HStack(spacing: 10) {
                Hairline()
                Text(item.text)
                    .font(model.chatText.small)
                    .foregroundStyle(Color.secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Hairline()
            }
        }
    }
}

/// One completion line with its time, outcome and duration, under a finished turn.
private struct TurnFooter: View {
    @Environment(AppModel.self) private var model
    let record: RunRecord
    let status: String?
    var body: some View {
        HStack(spacing: 10) {
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
    @Environment(AppModel.self) private var model
    let text: String

    var body: some View {
        Text(text)
            .font(model.chatText.code)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.06)) }
    }
}

struct Hairline: View {
    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(height: 1)
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
        .frame(width: 14, height: 14)
        .accessibilityHidden(true)
    }
}

/// Where the chat is scrolled, to tell the reader scrolling from the session writing.
private struct ScrollSpot: Equatable {
    let offset: CGFloat
    let height: CGFloat
    let atEnd: Bool
}
