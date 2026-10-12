import AppKit
import RotaCore
import SwiftUI

/// The session as turns, laid out the way super.engineering lays out an agent
/// chat: the user's message in a gray bubble on the right; the agent's answer as
/// plain text under a line naming what it ran on; the tool calls that led there
/// folded into one "N tool calls" rule; a footer with the time and a copy button.
struct ChatTranscript: View {
    @Environment(AppModel.self) private var model
    let items: [TranscriptItem]
    let running: Bool
    let record: RunRecord
    let routine: Routine
    /// Messages sent and not yet in the log.
    var sending: [String] = []
    @State private var following = true

    var body: some View {
        let turns = TranscriptTurn.group(items)
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 22) {
                    ForEach(Array(turns.enumerated()), id: \.element.id) { index, turn in
                        TurnView(turn: turn, isLast: index == turns.count - 1, running: running,
                                 only: turns.count == 1, record: record, routine: routine)
                    }
                    if turns.isEmpty && running {
                        WorkingLabel(since: model.scheduler.runStartedAt(record))
                    }
                    ForEach(Array(sending.enumerated()), id: \.offset) { _, text in
                        VStack(alignment: .trailing, spacing: 4) {
                            UserBubble(text: text).opacity(0.6)
                            Text("Sending\u{2026}").font(model.chatText.small).foregroundStyle(Color.secondaryText)
                        }
                        .frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
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
                    if following { proxy.scrollTo("end", anchor: .bottom) }
                } else if new.offset != old.offset {
                    // The reader scrolled: following resumes only back at the end.
                    following = new.atEnd
                }
            }
            .onChange(of: items.count + sending.count) { if following { proxy.scrollTo("end", anchor: .bottom) } }
            .onAppear { proxy.scrollTo("end", anchor: .bottom) }
            .overlay(alignment: .bottom) {
                if !following {
                    Button {
                        withAnimation { proxy.scrollTo("end", anchor: .bottom) }
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

private struct TurnView: View {
    @Environment(AppModel.self) private var model
    let turn: TranscriptTurn
    let isLast: Bool
    let running: Bool
    /// The session's only turn, whose length is the session's.
    let only: Bool
    let record: RunRecord
    let routine: Routine

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
                AgentHeader(record: record, routine: routine)
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
                TurnFooter(record: record, status: closingNote?.text, copyText: copyText)
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

    private var copyText: String {
        turn.answer.map(\.text).joined(separator: "\n\n")
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
    let routine: Routine

    var body: some View {
        HStack(spacing: 6) {
            HarnessLogo(harness: record.harness)
            Text(ModelLabel.name(harness: record.harness, routine: routine, models: model.settings.models))
            if record.harness == routine.harness, let effort = routine.effort {
                Text(effort.capitalized).foregroundStyle(Color.secondaryText)
            }
        }
        .font(model.chatText.small)
        .accessibilityElement(children: .combine)
    }
}

/// The harness, and the model when the routine picked one, by the title its CLI lists.
enum ModelLabel {
    static func name(harness: Harness, routine: Routine, models: [Harness: [ModelOption]]) -> String {
        guard harness == routine.harness, let id = routine.model else { return harness.title }
        let title = models[harness]?.first { $0.id == id }?.title ?? id
        return "\(harness.title)  \(title)"
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

/// "2:31 PM · Succeeded after 15 s" and a copy button, under a finished turn.
private struct TurnFooter: View {
    @Environment(AppModel.self) private var model
    let record: RunRecord
    let status: String?
    let copyText: String

    var body: some View {
        HStack(spacing: 10) {
            // The log's status line starts lowercase ("succeeded after 12 s"); here it starts the clause.
            Text([record.endedAt?.formatted(date: .omitted, time: .shortened),
                  status.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? record.outcome.title]
                .compactMap { $0 }.joined(separator: " \u{00B7} "))
                .foregroundStyle(record.outcome.isFailure ? Color.errorText : Color.secondaryText)
            Hairline()
            if !copyText.isEmpty {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(copyText, forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(Color.secondaryText)
                .help("Copy the answer")
                .accessibilityLabel("Copy the answer")
            }
        }
        .font(model.chatText.small)
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
                        Text(marker).foregroundStyle(Color.secondaryText)
                        Text(inline(content))
                    }
                    .font(text.body)
                    .padding(.leading, CGFloat(indent) * 16)
                case .code(let content, let language):
                    CodeBlockView(code: content, language: language)
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

/// A fenced code block as super.engineering draws one: a header with the
/// language and a Copy button over the code, which scrolls sideways rather than wrapping.
struct CodeBlockView: View {
    @Environment(AppModel.self) private var model
    let code: String
    let language: String?
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language ?? "Plain text")
                Spacer()
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help(copied ? "Copied" : "Copy Code")
                .accessibilityLabel(copied ? "Copied" : "Copy Code")
            }
            .font(model.chatText.small)
            .foregroundStyle(Color.secondaryText)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()
            ScrollView(.horizontal) {
                Text(code)
                    .font(model.chatText.code)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(12)
            }
        }
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
        .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.06)) }
    }
}

/// Where the chat is scrolled, to tell the reader scrolling from the session writing.
private struct ScrollSpot: Equatable {
    let offset: CGFloat
    let height: CGFloat
    let atEnd: Bool
}
