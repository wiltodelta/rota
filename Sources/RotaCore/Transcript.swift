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
        /// The agent's plan, one step per line (`PlanStep.parse`).
        case plan
    }

    public var id: Int
    public var kind: Kind
    public var text: String
    public var sourceID: String?
    public var turnID: String?
    public var phase: MessagePhase?
    public var delivery: MessageDelivery?
    public var model: String?
    public var tool: SessionTool?
    public var attachments: [ChatAttachment] = []

    public init(id: Int, kind: Kind, text: String, turnID: String? = nil, model: String? = nil) {
        self.id = id
        self.kind = kind
        self.text = text
        self.turnID = turnID
        self.model = model
    }
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
            // Each plan update opens with its own header line, so two in a row stay two plans.
            if kind == .plan, text == PlanStep.header {
                return items.append(TranscriptItem(id: items.count, kind: .plan, text: ""))
            }
            if let last = items.last, last.kind == kind,
               kind == .agent || kind == .user || kind == .output || kind == .plan {
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
        if line.hasPrefix(PlanStep.prefix) { return (.plan, String(line.dropFirst(PlanStep.prefix.count))) }
        if isHeader(line) { return nil }
        return (shell ? .output : .agent, line)
    }

    /// "after 412 s" reads as "after 6 min 52 s".
    static func readableDurations(_ text: String) -> String {
        guard let range = text.range(of: #"\d+ s\b"#, options: .regularExpression),
              let seconds = Int(text[range].dropLast(2)) else { return text }
        return text.replacingCharacters(in: range, with: readable(seconds: seconds))
    }

    /// 412 reads as "6m 52s", the way the chat's "Worked for" clock writes it.
    public static func readable(seconds: Int) -> String {
        if seconds < 60 { return "\(seconds)s" }
        if seconds < 3600 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds / 3600)h \(seconds / 60 % 60)m"
    }

    /// The lines runners write about a session rather than in it.
    static let headers = ["[codex thread ", "[grok session ", "[session started"]

    static func isHeader(_ line: String) -> Bool {
        headers.contains { line.hasPrefix($0) }
    }
}

/// One exchange of a session as a chat app lays it out: what the user sent,
/// the work the agent did for it (tool calls and its notes along the way),
/// the answer it ended on, and Rota's notes about the turn.
public struct TranscriptTurn: Equatable, Identifiable, Sendable {
    public var prompt: TranscriptItem?
    public var work: [TranscriptItem] = []
    public var answer: [TranscriptItem] = []
    public var notes: [TranscriptItem] = []
    /// The turn's latest plan: each update replaces the one before.
    public var plan: TranscriptItem?

    public var id: Int { prompt?.id ?? work.first?.id ?? answer.first?.id ?? notes.first?.id ?? plan?.id ?? -1 }
    public var toolCount: Int { work.filter { $0.kind == .tool }.count }

    /// Splits the items at each user message. Within a turn, everything up to the
    /// last tool call is work; the agent text and output after it are the answer.
    public static func group(_ items: [TranscriptItem]) -> [TranscriptTurn] {
        if items.contains(where: { $0.turnID != nil }) { return structured(items) }
        var turns: [TranscriptTurn] = []
        var current = TranscriptTurn()
        var body: [TranscriptItem] = []
        func close() {
            let lastTool = body.lastIndex { $0.kind == .tool }
            for (index, item) in body.enumerated() {
                switch item.kind {
                case .status, .error: current.notes.append(item)
                case .plan: current.plan = item
                case .user: break
                default:
                    if let lastTool, index <= lastTool {
                        current.work.append(item)
                    } else {
                        current.answer.append(item)
                    }
                }
            }
            if current.prompt != nil || !body.isEmpty { turns.append(current) }
            current = TranscriptTurn()
            body = []
        }
        for item in items {
            if item.kind == .user {
                close()
                current.prompt = item
            } else {
                body.append(item)
            }
        }
        close()
        return turns
    }

    private static func structured(_ items: [TranscriptItem]) -> [TranscriptTurn] {
        var turns = group(items.filter { $0.turnID == nil })
        var positions: [String: Int] = [:]
        for item in items {
            guard let id = item.turnID else { continue }
            let index: Int
            if let existing = positions[id] { index = existing } else {
                index = turns.count
                positions[id] = index
                turns.append(TranscriptTurn())
            }
            switch item.kind {
            case .user:
                if turns[index].prompt == nil { turns[index].prompt = item } else {
                    turns[index].work.append(item)
                }
            case .plan: turns[index].plan = item
            case .error, .status: turns[index].notes.append(item)
            default:
                if item.kind == .tool || item.phase == .work { turns[index].work.append(item) } else {
                    turns[index].answer.append(item)
                }
            }
        }
        return turns
    }
}

/// One step of an agent's plan: Claude's `TodoWrite`, Codex's `turn/plan/updated`
/// and Grok's ACP `plan` update all send the whole plan each time. In the log a
/// plan is a block of `[plan] ` lines, one per step, marked done, doing or todo.
public struct PlanStep: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case pending = "todo", inProgress = "doing", completed = "done" }

    public var status: Status
    public var text: String

    public init(status: Status, text: String) {
        self.status = status
        self.text = text
    }

    static let prefix = "[plan] "
    static let header = "plan"

    /// Each harness's own status word: pending, in_progress / inProgress, completed.
    public init(status raw: String?, text: String) {
        switch raw?.lowercased() {
        case "completed", "done": status = .completed
        case "in_progress", "inprogress", "doing", "active": status = .inProgress
        default: status = .pending
        }
        self.text = text
    }

    /// The log lines for a plan.
    public static func lines(_ steps: [PlanStep]) -> String {
        let rows = steps.map { prefix + $0.status.rawValue + " " + $0.text.replacingOccurrences(of: "\n", with: " ") }
        return ([prefix + header] + rows).joined(separator: "\n")
    }

    /// The steps of a plan item's text.
    public static func parse(_ text: String) -> [PlanStep] {
        text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: " ", maxSplits: 1)
            guard parts.count == 2, let status = Status(rawValue: String(parts[0])) else { return nil }
            return PlanStep(status: status, text: String(parts[1]))
        }
    }
}
