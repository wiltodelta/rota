import Foundation

/// Rota's own wire format. Provider payloads never enter this journal.
struct TranscriptRecord: Codable {
    var version = 1
    var type: String
    var required: Bool?
    var id: Int?
    var kind: String?
    var text: String?
    var complete: Bool?
    var logSize: UInt64
}

public struct TranscriptSnapshot: Equatable, Sendable {
    public var items: [TranscriptItem] = []
    public var structured = false
    public var problem: String?
    public var hasEarlier = false

    public init(items: [TranscriptItem] = [], structured: Bool = false,
                problem: String? = nil, hasEarlier: Bool = false) {
        self.items = items
        self.structured = structured
        self.problem = problem
        self.hasEarlier = hasEarlier
    }
}

/// Incrementally replays the normalized journal. A reader belongs to one open session.
public struct TranscriptReader: Sendable {
    private var offset: UInt64 = 0
    private var pending = Data()
    private var items: [TranscriptItem] = []
    private var indices: [Int: Int] = [:]
    private var headerSeen = false
    private var logSize: UInt64 = 0
    private var failure: String?

    private let pageSize: Int?
    private let settleWrites: Bool
    private var earlierOffset: UInt64 = 0
    private var headerEnd: UInt64 = 0
    private var lastGood: TranscriptSnapshot?
    private var unsettledReads = 0
    /// Actual bytes fetched, including header and incremental reads, for bounded-I/O checks.
    private(set) var bytesRead = 0

    public init(pageSize: Int? = nil, settleWrites: Bool = false) {
        self.pageSize = pageSize.map { max(1, $0) }
        self.settleWrites = settleWrites
    }

    public static func journalURL(for log: URL) -> URL { log.appendingPathExtension("chat.jsonl") }

    public mutating func read(log: URL, shell: Bool = false, finished: Bool = false) -> TranscriptSnapshot {
        let url = Self.journalURL(for: log)
        guard !shell, FileManager.default.fileExists(atPath: url.path) else { return legacy(log, shell: shell) }
        do {
            if offset == 0, let pageSize {
                try openTail(url, count: pageSize)
            }
            try replay(url)
            let size = try FileManager.default.attributesOfItem(atPath: log.path)[.size] as? UInt64
            let candidate = TranscriptSnapshot(items: items, structured: true, hasEarlier: earlierOffset > 0)
            guard failure == nil, headerSeen, size == logSize, !finished || pending.isEmpty else {
                // A poll can fall between the readable and normalized writes. Keep a coherent
                // projection for one poll; a second inconsistent read must expose the failure.
                unsettledReads += 1
                if settleWrites, !finished, failure == nil, unsettledReads == 1 {
                    return lastGood ?? candidate
                }
                let problem = failure ?? "Chat history is incomplete. Open the log for details."
                return legacy(log, shell: shell, problem: problem)
            }
            unsettledReads = 0
            lastGood = candidate
            return candidate
        } catch {
            return legacy(log, shell: shell, problem: "Couldn't read chat history. Open the log for details.")
        }
    }

    /// Used by the writer on continuation, before it appends anything.
    mutating func replay(_ url: URL) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        if size < offset {
            self = TranscriptReader(pageSize: pageSize, settleWrites: settleWrites)
            if let pageSize { try openTail(url, count: pageSize) }
        }
        try handle.seek(toOffset: offset)
        let data = try handle.readToEnd() ?? Data()
        bytesRead += data.count
        offset += UInt64(data.count)
        pending.append(data)
        while let newline = pending.firstIndex(of: 10) {
            let line = Data(pending[..<newline])
            pending.removeSubrange(...newline)
            do { try apply(JSONDecoder().decode(TranscriptRecord.self, from: line)) } catch {
                failure = "Chat history is incomplete or unsupported. Open the log for details."
            }
        }
    }

    /// Prepend a page without discarding live appends or changing existing IDs.
    public mutating func readEarlier(log: URL, finished: Bool = false) -> TranscriptSnapshot {
        guard earlierOffset > 0, let pageSize, failure == nil else {
            return read(log: log, finished: finished)
        }
        do {
            let page = try JournalPage.read(Self.journalURL(for: log), before: earlierOffset, count: pageSize)
            bytesRead += page.bytesRead
            var older = TranscriptReader()
            older.headerSeen = true
            for record in page.records where record.type != "header" { try older.apply(record) }
            guard Set(older.items.map(\.id)).isDisjoint(with: indices.keys) else { throw JournalError.unsupported }
            items = older.items + items
            indices = Dictionary(uniqueKeysWithValues: items.enumerated().map { ($0.element.id, $0.offset) })
            earlierOffset = page.start > headerEnd ? page.start : 0
            if var good = lastGood {
                good.items = older.items + good.items
                good.hasEarlier = earlierOffset > 0
                lastGood = good
            }
        } catch {
            failure = "Chat history is incomplete or unsupported. Open the log for details."
        }
        return read(log: log, finished: finished)
    }

    private mutating func openTail(_ url: URL, count: Int) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var first = Data()
        while !first.contains(10), let chunk = try handle.read(upToCount: 4096), !chunk.isEmpty {
            bytesRead += chunk.count
            first.append(chunk)
        }
        guard let newline = first.firstIndex(of: 10) else {
            pending = first
            offset = UInt64(first.count)
            return
        }
        let header = try JSONDecoder().decode(TranscriptRecord.self, from: first[..<newline])
        guard header.type == "header" else { throw JournalError.unsupported }
        try apply(header)
        headerEnd = UInt64(first.distance(from: first.startIndex, to: newline)) + 1
        let size = try handle.seekToEnd()
        let page = try JournalPage.read(url, before: size, count: count, allowPartial: true)
        bytesRead += page.bytesRead
        for record in page.records where record.type != "header" { try apply(record) }
        earlierOffset = page.start > headerEnd ? page.start : 0
        offset = size
        pending = page.partial
    }

    var canAppend: Bool { failure == nil && headerSeen && pending.isEmpty }
    var nextID: Int { (items.map(\.id).max() ?? -1) + 1 }

    private mutating func apply(_ record: TranscriptRecord) throws {
        guard record.version == 1 else { throw JournalError.unsupported }
        if record.type == "header" {
            guard !headerSeen else { throw JournalError.unsupported }
            headerSeen = true
        } else {
            guard headerSeen else { throw JournalError.unsupported }
            switch record.type {
            case "item": try insert(record)
            case "append", "complete": try update(record)
            default:
                guard record.required == false else { throw JournalError.unsupported }
            }
        }
        logSize = record.logSize
    }

    private mutating func update(_ record: TranscriptRecord) throws {
        guard let id = record.id, let index = indices[id], !items[index].isComplete else {
            throw JournalError.unsupported
        }
        if record.type == "append" {
            guard let text = record.text else { throw JournalError.unsupported }
            items[index].text += text
        } else {
            items[index].isComplete = true
        }
    }

    private mutating func insert(_ record: TranscriptRecord) throws {
        guard let id = record.id, id >= 0, indices[id] == nil,
              let kind = record.kind, let text = record.text else { throw JournalError.unsupported }
        indices[id] = items.count
        // An unfamiliar presentation kind still has the contract's explicit display text.
        items.append(TranscriptItem(id: id, kind: TranscriptItem.Kind(rawValue: kind) ?? .status,
                                    text: text, isComplete: record.complete ?? true))
    }

    private func legacy(_ log: URL, shell: Bool, problem: String? = nil) -> TranscriptSnapshot {
        guard let handle = try? FileHandle(forReadingFrom: log) else {
            return TranscriptSnapshot(problem: problem ?? "Couldn't read the session log.")
        }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 400_000 ? size - 400_000 : 0)
        let text = lossyUTF8((try? handle.readToEnd()) ?? Data())
        return TranscriptSnapshot(items: Transcript.parse(text, shell: shell), problem: problem)
    }
}

enum JournalError: Error { case unsupported }

/// Called only under RunJournal's lock. Records and readable output share one writer.
final class TranscriptJournal {
    private let handle: FileHandle
    private(set) var nextID: Int

    init(log: URL, resuming: Bool, logSize: UInt64) throws {
        let url = TranscriptReader.journalURL(for: log)
        if resuming {
            var reader = TranscriptReader()
            let snapshot = reader.read(log: log)
            guard snapshot.structured, reader.canAppend else { throw JournalError.unsupported }
            nextID = reader.nextID
        } else {
            FileManager.default.createFile(atPath: url.path, contents: nil)
            nextID = 0
        }
        handle = try FileHandle(forWritingTo: url)
        try handle.seekToEnd()
        if !resuming { try append(TranscriptRecord(type: "header", logSize: logSize)) }
    }

    deinit { try? handle.close() }

    func append(_ record: TranscriptRecord) throws {
        let data = try JSONEncoder().encode(record) + Data([10])
        try handle.write(contentsOf: data)
    }

    func allocateID() -> Int {
        defer { nextID += 1 }
        return nextID
    }
}

/// Serializes polling and page requests away from the UI actor. The reader survives
/// scheduler refreshes, so finishing a run does not collapse already loaded pages.
public actor TranscriptSessionReader {
    private var reader = TranscriptReader(pageSize: 50, settleWrites: true)

    public init() {}

    public func read(log: URL, shell: Bool, finished: Bool, earlier: Bool = false) -> TranscriptSnapshot {
        if earlier, !shell { return reader.readEarlier(log: log, finished: finished) }
        return reader.read(log: log, shell: shell, finished: finished)
    }
}
