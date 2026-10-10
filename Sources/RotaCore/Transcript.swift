import Foundation

/// One entry of a session as the chat shows it.
public struct TranscriptItem: Equatable, Identifiable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// The routine's prompt or a message the user sent.
        case user
        /// What the agent said.
        case agent
        /// A tool the agent called.
        case tool
        /// Rota's own notes: the run ended, a message was not delivered.
        case status
        case error
        /// A shell command's output.
        case output
    }

    public var id: Int
    public var kind: Kind
    public var text: String
}

/// Reads a run log into chat entries. Runners write the log with line prefixes:
/// `[you] ` for user text (every line of it), `-> ` for tool calls, `[rota: …]`
/// and `[result: …]` for status, `[error] ` for errors; header lines such as the
/// session id are dropped; anything else is the agent's text, consecutive lines
/// joined into one message.
public enum Transcript {
    public static let userPrefix = "[you] "

    /// The log lines for a user message, so a multi-line message survives the round trip.
    public static func userLines(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { userPrefix + $0 }
            .joined(separator: "\n")
    }

    public static func parse(_ log: String, shell: Bool = false) -> [TranscriptItem] {
        var items: [TranscriptItem] = []
        func append(_ kind: TranscriptItem.Kind, _ text: String) {
            if let last = items.last, last.kind == kind, kind == .agent || kind == .user || kind == .output {
                items[items.count - 1].text += "\n" + text
            } else {
                items.append(TranscriptItem(id: items.count, kind: kind, text: text))
            }
        }
        // Inside a fenced code block a blank line is code, not the end of a message.
        var inFence = false
        for raw in log.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let fence = !shell && line.trimmingCharacters(in: .whitespaces).hasPrefix("```")
            if fence { inFence.toggle() }
            if fence || inFence {
                append(.agent, line)
                continue
            }
            if line.trimmingCharacters(in: .whitespaces).isEmpty {
                // A blank line ends a message, so the next text starts a new one.
                if let last = items.last, last.kind == .agent || last.kind == .output {
                    items.append(TranscriptItem(id: items.count, kind: .status, text: ""))
                }
            } else if let (kind, text) = classify(line, shell: shell) {
                append(kind, text)
            }
        }
        return items.filter { !($0.kind == .status && $0.text.isEmpty) }.enumerated().map {
            TranscriptItem(id: $0.offset, kind: $0.element.kind, text: $0.element.text)
        }
    }

    /// The kind and text of a non-blank log line outside a code fence; nil for a header.
    static func classify(_ line: String, shell: Bool) -> (TranscriptItem.Kind, String)? {
        if line.hasPrefix(userPrefix) { return (.user, String(line.dropFirst(userPrefix.count))) }
        if line.hasPrefix("-> ") { return (.tool, String(line.dropFirst(3))) }
        if line.hasPrefix("[rota: ") || line.hasPrefix("[result: ") {
            let body = line.drop { $0 != " " }.dropFirst().dropLast(line.hasSuffix("]") ? 1 : 0)
            return (.status, readableDurations(String(body)))
        }
        if line.hasPrefix("[error] ") { return (.error, String(line.dropFirst(8))) }
        if isHeader(line) { return nil }
        return (shell ? .output : .agent, line)
    }

    /// "after 412 s" reads as "after 6 min 52 s".
    static func readableDurations(_ text: String) -> String {
        guard let range = text.range(of: #"\d+ s\b"#, options: .regularExpression),
              let seconds = Int(text[range].dropLast(2)), seconds >= 60 else { return text }
        let minutes = seconds / 60
        let rest = seconds % 60
        let readable = minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min"
            : rest == 0 ? "\(minutes) min" : "\(minutes) min \(rest) s"
        return text.replacingCharacters(in: range, with: readable)
    }

    /// The lines runners write about a session rather than in it.
    static let headers = ["[codex thread ", "[grok session ", "[session started"]

    static func isHeader(_ line: String) -> Bool {
        headers.contains { line.hasPrefix($0) }
    }
}
