import AppKit
import RotaCore
import SwiftUI

/// The tool calls and passing notes of a turn behind one rule, as
/// super.engineering lays out a turn: while it runs the rule reads "Working
/// for 12s" and shimmers, with the work shown under it; afterwards it reads
/// "Worked for 3m 12s" and folds the work away. Calls in a row become one line
/// that says what they did ("ran 2 commands, read 1 file").
struct WorkSection: View {
    @Environment(\.interfaceScale) private var metrics
    @Environment(AppModel.self) private var model
    let items: [TranscriptItem]
    let live: Bool
    /// When the live turn's run started; the clock counts from it.
    let since: Date?
    let label: String
    var willToggle: () -> Void = {}
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.points(6)) {
            HStack(spacing: metrics.points(10)) {
                Hairline()
                Group {
                    if live {
                        // A status while the turn works, not a disabled control: disabling dims the text.
                        TimelineView(.periodic(from: .now, by: 1)) { context in
                            let seconds = since.map { context.date.timeIntervalSince($0) } ?? 0
                            Text("Working for " + Elapsed.short(seconds))
                                .monospacedDigit()
                                .shimmering()
                        }
                    } else {
                        Button {
                            willToggle()
                            expanded.toggle()
                        } label: {
                            HStack(spacing: metrics.points(5)) {
                                Text(label)
                                Image(systemName: "chevron.right")
                                    .interfaceFont(.caption2).fontWeight(.semibold)
                                    .rotationEffect(.degrees(expanded ? 90 : 0))
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(expanded ? "Hide the steps" : "Show the steps")
                    }
                }
                .foregroundStyle(Color.secondaryText)
                .accessibilityIdentifier("workToggle")
                Hairline()
            }
            .font(model.chatText.small)
            if expanded || live {
                let rows = WorkRow.group(items)
                VStack(alignment: .leading, spacing: metrics.points(4)) {
                    ForEach(rows) { row in
                        switch row {
                        case .note(let item): WorkNoteView(item: item, willToggle: willToggle)
                        case .tools(let calls):
                            ToolRunRow(calls: calls, live: live && row.id == rows.last?.id, willToggle: willToggle)
                        }
                    }
                }
                .padding(.leading, metrics.points(4))
            }
        }
    }
}

/// One transcript entry, or adjacent tool calls sharing a disclosure row.
enum WorkRow: Identifiable {
    case note(TranscriptItem)
    case tools([TranscriptItem])

    var id: Int {
        switch self {
        case .note(let item): return item.id
        case .tools(let calls): return calls.first?.id ?? -1
        }
    }

    var items: [TranscriptItem] {
        switch self {
        case .note(let item): [item]
        case .tools(let calls): calls
        }
    }

    /// Paging can prepend calls to the first group; map its previous row ID to the new header.
    static func visibleID(for id: Int, in rows: [WorkRow]) -> Int {
        rows.first { $0.items.contains { $0.id == id } }?.id ?? id
    }

    static func group(_ items: [TranscriptItem]) -> [WorkRow] {
        var rows: [WorkRow] = []
        var calls: [TranscriptItem] = []
        for raw in items where !raw.isEmptyReasoning {
            let item = raw.presented
            if item.kind.canJoinToolGroup && (item.kind == .tool || !calls.isEmpty) {
                calls.append(item)
                continue
            }
            if !calls.isEmpty {
                rows.append(.tools(calls))
                calls = []
            }
            rows.append(.note(item))
        }
        if !calls.isEmpty { rows.append(.tools(calls)) }
        return rows
    }
}

/// Calls in a row: one call as itself, several as what they did, unfolding into each call.
private struct ToolRunRow: View {
    @Environment(\.interfaceScale) private var metrics
    @Environment(AppModel.self) private var model
    let calls: [TranscriptItem]
    /// The run the agent is in now: it shimmers.
    let live: Bool
    var willToggle: () -> Void = {}
    @State private var expanded = false

    var body: some View {
        let lines = calls.map(\.text)
        VStack(alignment: .leading, spacing: metrics.points(3)) {
            if calls.count == 1 {
                // One call reads as itself; there is nothing to unfold.
                header(lines).help(lines[0])
            } else {
                Button {
                    willToggle()
                    expanded.toggle()
                } label: { header(lines) }
                    .buttonStyle(.plain)
                    .help(expanded ? "Hide the calls" : "Show the calls")
            }
            if expanded, calls.count > 1 {
                VStack(alignment: .leading, spacing: metrics.points(3)) {
                    ForEach(calls) { call in
                        Text(call.text)
                            .font(model.chatText.smallCode)
                            .foregroundStyle(Color.secondaryText)
                            .lineLimit(2)
                            .help(call.text)
                    }
                }
                .padding(.leading, metrics.points(12))
                .overlay(alignment: .leading) {
                    // The rail the calls hang off, under the run's icon.
                    Rectangle().fill(Color(nsColor: .separatorColor)).frame(width: 1)
                        .padding(.leading, metrics.points(6))
                }
            }
        }
    }

    private func header(_ lines: [String]) -> some View {
        HStack(spacing: metrics.points(6)) {
            let kind = lines.count == 1 ? ToolStep.kind(of: lines[0]) : ToolStep.dominant(lines)
            Image(systemName: kind.symbol)
                .frame(width: metrics.points(14))
            let change = lines.count == 1 ? FileChangeTitle.title(lines[0], live: live) : nil
            Text(change ?? (lines.count == 1 ? lines[0] : ToolStep.summary(lines).capitalizedFirst))
                .font(lines.count == 1 && change == nil ? model.chatText.smallCode : model.chatText.small)
                .shimmering(live)
                .lineLimit(1)
                .truncationMode(.tail)
            if lines.count > 1 {
                Image(systemName: "chevron.right")
                    .interfaceFont(.caption2).fontWeight(.semibold)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
            }
        }
        .foregroundStyle(Color.secondaryText)
        .contentShape(Rectangle())
    }
}

/// What the agent said along the way, quieter than its answer.
private struct WorkNoteView: View {
    @Environment(\.interfaceScale) private var metrics
    @Environment(AppModel.self) private var model
    let item: TranscriptItem
    var willToggle: () -> Void = {}

    var body: some View {
        switch item.kind {
        case .reasoning: ReasoningView(text: item.text, willToggle: willToggle)
        case .output:
            ToolOutputView(item: item)
        default:
            Text(item.text)
                .font(model.chatText.small)
                .foregroundStyle(Color.secondaryText)
                .textSelection(.enabled)
                .padding(.vertical, metrics.points(2))
        }
    }
}

extension ToolStep {
    var symbol: String {
        switch self {
        case .read: return "doc.text"
        case .edit: return "pencil.line"
        case .search: return "magnifyingglass"
        case .execute: return "apple.terminal"
        case .fetch: return "globe"
        case .other: return "wrench.and.screwdriver"
        }
    }
}

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

/// "12s", "3m 12s", "1h 5m": an elapsed time as super.engineering's chat writes it.
enum Elapsed {
    static func short(_ interval: TimeInterval) -> String {
        Transcript.readable(seconds: max(0, Int(interval)))
    }
}

/// The agent's latest plan in a turn: each step with its state, done ones struck through.
struct PlanCard: View {
    @Environment(\.interfaceScale) private var metrics
    @Environment(AppModel.self) private var model
    let steps: [PlanStep]

    var body: some View {
        VStack(alignment: .leading, spacing: metrics.points(6)) {
            let done = steps.filter { $0.status == .completed }.count
            HStack {
                Text("Plan").fontWeight(.semibold)
                Spacer()
                Text("\(done) of \(steps.count) done").foregroundStyle(Color.secondaryText)
            }
            .font(model.chatText.small)
            ForEach(Array(steps.enumerated()), id: \.offset) { _, step in
                HStack(alignment: .firstTextBaseline, spacing: metrics.points(8)) {
                    Image(systemName: Self.symbol(step.status))
                        .foregroundStyle(step.status == .inProgress ? Color.accentColor : Color.secondaryText)
                    Text(step.text)
                        .strikethrough(step.status == .completed)
                        .foregroundStyle(step.status == .completed ? Color.secondaryText : .primary)
                }
                .font(model.chatText.body)
                .accessibilityElement(children: .combine)
                .accessibilityValue(step.status == .completed ? "Done"
                                    : step.status == .inProgress ? "In progress" : "To do")
            }
        }
        .padding(metrics.points(12))
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay { RoundedRectangle(cornerRadius: metrics.points(10)).strokeBorder(Color.primary.opacity(0.12)) }
    }

    static func symbol(_ status: PlanStep.Status) -> String {
        switch status {
        case .pending: return "circle"
        case .inProgress: return "circle.dotted"
        case .completed: return "checkmark.circle.fill"
        }
    }
}

/// "Edited Footer.astro" for one call that writes a file; nil for anything else.
enum FileChangeTitle {
    static func title(_ line: String, live: Bool) -> String? {
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2, parts[1].hasPrefix("/") || parts[1].hasPrefix("~") else { return nil }
        let name = URL(fileURLWithPath: parts[1]).lastPathComponent
        switch parts[0] {
        case "Edit", "MultiEdit", "search_replace": return (live ? "Editing " : "Edited ") + name
        case "Write", "write_file", "create_file": return (live ? "Writing " : "Wrote ") + name
        default: return nil
        }
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
