import Foundation

/// A short excerpt of actual session content, never a generated summary or the user's prompt.
public enum SessionPreview {
    public static func text(for record: RunRecord, snapshot: TranscriptSnapshot?) -> String {
        if let question = record.nextQuestion {
            return plain(([question.detail] + question.fields.map(\.title) + [question.title])
                .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? question.title)
        }
        if let attention = record.attention { return plain(attention) }
        switch record.outcome {
        case .launchFailed(let reason), .skipped(let reason): return plain(reason)
        default: break
        }
        guard let snapshot else { return record.logPath == nil ? empty(record) : "Loading last message…" }
        if record.outcome.isFailure,
           let error = snapshot.items.last(where: { $0.kind == .error && !$0.text.isEmpty }) {
            return plain(error.text)
        }
        if let item = snapshot.items.last(where: {
            ($0.kind == .agent || ($0.kind == .output && record.harness == .shell) || $0.kind == .error)
                && !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) {
            return plain(item.text)
        }
        if snapshot.problem != nil { return "Couldn't read the last message. Open the session for details." }
        return empty(record)
    }

    private static func empty(_ record: RunRecord) -> String {
        if record.outcome == .running { return "Waiting for the first message…" }
        return record.harness == .shell ? "No command output." : "No agent message."
    }

    private static func plain(_ text: String) -> String {
        let source = String(text.prefix(2000))
        let blocks = MarkdownBlock.parse(source).map { block in
            switch block {
            case .heading(_, let text), .listItem(_, let text, _), .paragraph(let text), .code(let text, _):
                return text
            case .table(let table): return (table.headers + table.rows.flatMap { $0 }).joined(separator: " ")
            }
        }.joined(separator: " ")
        let parsed = String(inlineMarkdown(blocks).characters)
        return String(parsed.split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(320))
    }
}
