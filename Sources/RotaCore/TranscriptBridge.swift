internal import CRotaFFI
import Foundation

public struct TranscriptSnapshot: Equatable, Sendable {
    public var items: [TranscriptItem] = []
    public var structured = false
    public var problem: String?
    public var hasEarlier = false

    public init(
        items: [TranscriptItem] = [],
        structured: Bool = false,
        problem: String? = nil,
        hasEarlier: Bool = false
    ) {
        self.items = items
        self.structured = structured
        self.problem = problem
        self.hasEarlier = hasEarlier
    }
}

extension TranscriptSnapshot: Decodable {
    private enum CodingKeys: String, CodingKey {
        case items, structured, problem, hasEarlier
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decodeIfPresent([TranscriptItem].self, forKey: .items) ?? []
        structured = try container.decodeIfPresent(Bool.self, forKey: .structured) ?? false
        problem = try container.decodeIfPresent(String.self, forKey: .problem)
        hasEarlier = try container.decodeIfPresent(Bool.self, forKey: .hasEarlier) ?? false
    }
}

private struct PreviewReply: Decodable {
    var preview: String
    var items: Int
}

/// Guards an opaque Rust `RotaReaderHandle` with an `NSLock` and is `@unchecked Sendable`.
private final class ReaderBox: @unchecked Sendable {
    private let lock = NSLock()
    private let handle: OpaquePointer?

    init(pageSize: Int?, settleWrites: Bool) {
        handle = rota_reader_create(Int64(pageSize ?? 0), settleWrites)
    }

    func read(log: URL, shell: Bool, finished: Bool, earlier: Bool) -> TranscriptSnapshot {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { return TranscriptSnapshot(problem: "Transcript reader unavailable.") }
        let raw = log.path.withCString { pathPtr in
            FFIJSON.string(taking: rota_reader_read(handle, pathPtr, shell, finished, earlier))
        }
        guard let raw,
              let envelope = try? FFIJSON.decoder.decode(FFIEnvelope<TranscriptSnapshot>.self, from: Data(raw.utf8)),
              let decoded = envelope.ok else {
            return TranscriptSnapshot(problem: "Couldn't read chat history. Open the log for details.")
        }
        return decoded
    }

    func preview(for record: RunRecord) -> (text: String, items: Int)? {
        lock.lock()
        defer { lock.unlock() }
        guard let handle,
              let jsonData = try? FFIJSON.encoder.encode(record),
              let jsonText = String(data: jsonData, encoding: .utf8) else {
            return nil
        }
        let raw = jsonText.withCString { ptr in
            FFIJSON.string(taking: rota_reader_preview(handle, ptr))
        }
        guard let raw,
              let envelope = try? FFIJSON.decoder.decode(FFIEnvelope<PreviewReply>.self, from: Data(raw.utf8)),
              let ok = envelope.ok else {
            return nil
        }
        return (ok.preview, ok.items)
    }

    deinit {
        if let handle { rota_reader_free(handle) }
    }
}

public struct TranscriptReader: Sendable {
    private var box: ReaderBox

    public init(pageSize: Int? = nil, settleWrites: Bool = false) {
        self.box = ReaderBox(pageSize: pageSize, settleWrites: settleWrites)
    }

    public static func journalURL(for log: URL) -> URL {
        log.appendingPathExtension("chat.jsonl")
    }

    public mutating func read(log: URL, shell: Bool = false, finished: Bool = false) -> TranscriptSnapshot {
        box.read(log: log, shell: shell, finished: finished, earlier: false)
    }

    public mutating func readEarlier(log: URL, finished: Bool = false) -> TranscriptSnapshot {
        box.read(log: log, shell: false, finished: finished, earlier: true)
    }
}

/// Structured transcript producer backed by `rota-core`'s `TranscriptJournal` + `RunJournal`.
public final class TranscriptJournal: @unchecked Sendable {
    let log: URL
    let resuming: Bool

    public init(log: URL, resuming: Bool, logSize: UInt64) throws {
        _ = logSize
        self.log = log
        self.resuming = resuming
    }
}

/// Thread-safe run log + structured journal writer backed by `rota-core`'s `RunJournal`.
public final class RunJournal: @unchecked Sendable {
    private let handle: OpaquePointer?

    public init(output: FileHandle, events: RunEvents, transcript: TranscriptJournal?) {
        _ = events
        try? output.close()
        if let transcript {
            handle = transcript.log.path.withCString { ptr in
                rota_journal_create(ptr, transcript.resuming)
            }
        } else {
            handle = nil
        }
    }

    public func record(_ kind: TranscriptItem.Kind, _ text: String) {
        guard let handle else { return }
        kind.rawValue.withCString { kindPtr in
            text.withCString { textPtr in
                rota_journal_record(handle, kindPtr, textPtr)
            }
        }
    }

    public func finish(_ outcome: RunOutcome) {
        guard let handle,
              let data = try? FFIJSON.encoder.encode(outcome),
              let jsonText = String(data: data, encoding: .utf8) else { return }
        jsonText.withCString { ptr in
            rota_journal_finish(handle, ptr)
        }
    }

    deinit {
        if let handle { rota_journal_free(handle) }
    }
}

public actor TranscriptSessionReader {
    private let box = ReaderBox(pageSize: 50, settleWrites: true)

    public init() {}

    public func read(log: URL, shell: Bool, finished: Bool, earlier: Bool = false) -> TranscriptSnapshot {
        let started = ProcessInfo.processInfo.systemUptime
        let snapshot = box.read(log: log, shell: shell, finished: finished, earlier: earlier)
        PerformanceDiagnostics.shared.recordTranscript(
            seconds: ProcessInfo.processInfo.systemUptime - started,
            items: snapshot.items.count,
            earlier: earlier,
            shell: shell
        )
        return snapshot
    }

    public func followPreview(of record: RunRecord, update: @MainActor @Sendable (String) -> Void) async {
        while true {
            let started = ProcessInfo.processInfo.systemUptime
            let preview: String
            if let computed = box.preview(for: record) {
                if !record.isSkip && record.logPath != nil {
                    PerformanceDiagnostics.shared.recordTranscript(
                        seconds: ProcessInfo.processInfo.systemUptime - started,
                        items: computed.items,
                        earlier: false,
                        shell: record.harness == .shell
                    )
                }
                preview = computed.text
            } else {
                preview = SessionPreview.text(for: record, snapshot: nil)
            }
            guard !Task.isCancelled else { return }
            await update(preview)
            guard record.outcome == .running else { return }
            do {
                try await Task.sleep(for: .seconds(3))
            } catch {
                return
            }
        }
    }
}
