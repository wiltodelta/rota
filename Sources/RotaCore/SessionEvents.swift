import Foundation

/// What the transport has actually confirmed about a user message.
public enum MessageDelivery: Codable, Equatable, Sendable {
    case pending
    case written
    case accepted
    case queued
    case failed(String)
    case unconfirmed(String)
    case cancelled

    public var title: String? {
        switch self {
        case .pending: return "Sending…"
        case .written: return "Sent to harness"
        case .accepted: return nil
        case .queued: return "Queued"
        case .failed(let reason): return "Not delivered: \(reason)"
        case .unconfirmed(let reason): return "Delivery unconfirmed: \(reason)"
        case .cancelled: return "Not delivered: session ended"
        }
    }
}

public enum MessagePhase: String, Codable, Sendable { case work, answer }

public struct SessionMetadata: Codable, Equatable, Sendable {
    public var model: String?
    public var effort: String?

    public init(model: String? = nil, effort: String? = nil) {
        self.model = model
        self.effort = effort
    }
}

/// The immutable launch settings of a provider conversation, independent of routine edits.
public struct RunConfiguration: Codable, Equatable, Sendable {
    public var model: String?
    public var effort: String?
    public var workingDirectory: String
}

/// Normalized events keep identifiers and content separate from the readable log.
public struct SessionEvent: Codable, Equatable, Sendable {
    public var turnID: String
    public var payload: Payload

    public enum Payload: Codable, Equatable, Sendable {
        case started(SessionMetadata)
        case user(id: String, text: String, delivery: MessageDelivery)
        case attachments(id: String, files: [ChatAttachment])
        case delivery(id: String, state: MessageDelivery)
        case assistant(id: String, text: String, phase: MessagePhase?)
        case delta(id: String, text: String, phase: MessagePhase?)
        case tool(id: String, title: String, input: String?, output: String?, status: String?)
        case plan([PlanStep])
        case metadata(SessionMetadata)
        case note(text: String, error: Bool)
        case finished(RunOutcome)
        /// A continuation of an old session preserves its readable history once.
        case legacy(text: String, shell: Bool)
    }
}

/// A deterministic projection: neither text prefixes nor matching message text imply delivery.
public struct SessionTranscript: Sendable {
    public private(set) var items: [TranscriptItem] = []
    public private(set) var metadata: [String: SessionMetadata] = [:]
    private var positions: [String: Int] = [:]

    public init() {}

    public mutating func apply(_ event: SessionEvent) {
        switch event.payload {
        case .started(let value), .metadata(let value): updateMetadata(value, turn: event.turnID)
        case .note(let text, let error): append(kind: error ? .error : .status, text: text, turn: event.turnID)
        case .finished(let outcome): finish(outcome, turn: event.turnID)
        case .legacy(let text, let shell):
            for var item in Transcript.parse(text, shell: shell) {
                item.id = items.count
                items.append(item)
            }
        default: applyContent(event)
        }
    }

    private mutating func applyContent(_ event: SessionEvent) {
        let turn = event.turnID
        switch event.payload {
        case .user(let id, let text, let delivery):
            let index = position(id, turn: turn, kind: .user)
            items[index].text = text
            items[index].delivery = delivery
        case .attachments(let id, let files):
            let index = position(id, turn: turn, kind: .user)
            items[index].attachments = files
        case .delivery(let id, let state):
            if let index = positions[key(id, turn: turn)] { items[index].delivery = state }
        case .assistant(let id, let text, let phase), .delta(let id, let text, let phase):
            let index = position(id, turn: turn, kind: .agent)
            if case .delta = event.payload { items[index].text += text } else { items[index].text = text }
            if let phase { items[index].phase = phase }
        case .tool(let id, let title, let input, let output, let status):
            updateTool(id, patch: SessionTool(title: title, input: input, output: output, status: status), turn: turn)
        case .plan(let steps):
            let index = position("plan", turn: turn, kind: .plan)
            items[index].text = steps.map { $0.status.rawValue + " " + $0.text }.joined(separator: "\n")
        default: break
        }
    }

    private mutating func updateMetadata(_ value: SessionMetadata, turn: String) {
        let old = metadata[turn] ?? SessionMetadata()
        metadata[turn] = SessionMetadata(model: value.model ?? old.model, effort: value.effort ?? old.effort)
        for index in items.indices where items[index].turnID == turn && items[index].kind == .user {
            items[index].model = metadata[turn]?.model
        }
    }

    private mutating func updateTool(_ id: String, patch: SessionTool, turn: String) {
        // Unknown-phase notes before a tool are activity; an explicit final answer stays final.
        for index in items.indices where items[index].turnID == turn && items[index].kind == .agent
            && items[index].phase == nil { items[index].phase = .work }
        let index = position(id, turn: turn, kind: .tool)
        var tool = items[index].tool ?? SessionTool(title: patch.title.isEmpty ? "Tool " + id : patch.title)
        if !patch.title.isEmpty { tool.title = patch.title }
        if let input = patch.input { tool.input = input }
        if let output = patch.output { tool.output = output }
        if let status = patch.status { tool.status = status }
        items[index].tool = tool
        items[index].text = tool.text
        items[index].phase = .work
    }

    private mutating func finish(_ outcome: RunOutcome, turn: String) {
        for index in items.indices where items[index].turnID == turn && items[index].delivery == .pending {
            items[index].delivery = .unconfirmed("The session ended before delivery was confirmed.")
        }
        append(kind: .status, text: outcome.title, turn: turn)
    }

    private func key(_ id: String, turn: String) -> String { turn + "/" + id }

    private mutating func position(_ id: String, turn: String, kind: TranscriptItem.Kind) -> Int {
        let identity = key(id, turn: turn)
        if let index = positions[identity] { return index }
        let index = items.count
        positions[identity] = index
        append(kind: kind, text: "", turn: turn)
        items[index].sourceID = id
        return index
    }

    private mutating func append(kind: TranscriptItem.Kind, text: String, turn: String) {
        items.append(TranscriptItem(id: items.count, kind: kind, text: text,
                                    turnID: turn, model: metadata[turn]?.model))
    }
}

public struct SessionTool: Equatable, Sendable {
    public var title: String
    public var input: String?
    public var output: String?
    public var status: String?

    public var text: String {
        [title, status.map { "Status: " + $0 }, input.map { "Input: " + $0 }, output.map { "Output: " + $0 }]
            .compactMap { $0 }.joined(separator: "\n")
    }
}

/// Incremental JSONL reads keep long conversations intact and tolerate only an unfinished final line.
public final class SessionEventReader {
    public private(set) var transcript = SessionTranscript()
    private var offset: UInt64 = 0
    private var partial = Data()

    public init() {}

    public static func file(for log: URL) -> URL { log.appendingPathExtension("events.jsonl") }

    @discardableResult
    public func read(from url: URL) throws -> Bool {
        guard FileManager.default.fileExists(atPath: url.path) else { return false }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        if size < offset {
            offset = 0
            partial = Data()
            transcript = SessionTranscript()
        }
        try handle.seek(toOffset: offset)
        let data = try handle.readToEnd() ?? Data()
        offset += UInt64(data.count)
        partial.append(data)
        while let newline = partial.firstIndex(of: UInt8(ascii: "\n")) {
            // A corrupt complete event must not silently turn into absent history.
            let event = try JSONDecoder().decode(SessionEvent.self, from: partial[..<newline])
            partial.removeSubrange(...newline)
            transcript.apply(event)
        }
        return true
    }
}
