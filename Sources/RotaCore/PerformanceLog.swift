import Foundation

/// Only fixed categories and numeric measurements enter the performance journal.
public struct PerformanceContext: Codable, Sendable {
    public enum Surface: String, Codable, Sendable {
        case background, conversation, routine, settings, panel, empty
    }

    public var surface: Surface = .background
    public var activeRuns = 0
    public var routineCount = 0
    public var appActive = false
    public var windowWidth: Double = 0
    public var windowHeight: Double = 0

    public init() {}
}

struct PerformanceEvent: Codable {
    enum Kind: String, Codable {
        case launch, resources, sleep, wake, shutdown
        case mainThreadStall = "main_thread_stall"
        case mainThreadDelay = "main_thread_delay"
        case slowTranscript = "slow_transcript"
    }

    var schema = 1
    var time = ""
    var kind: Kind
    var uptime = ProcessInfo.processInfo.systemUptime
    var cpuPercent: Double?
    var residentBytes: UInt64?
    var durationMs: Double?
    var context: PerformanceContext?
    var transcript: TranscriptPerformance?
}

struct TranscriptPerformance: Codable, Sendable {
    var reads = 0
    var earlierReads = 0
    var shellReads = 0
    var totalMs: Double = 0
    var maxMs: Double = 0
    var maxItems = 0

    mutating func add(seconds: TimeInterval, items: Int, earlier: Bool, shell: Bool) {
        reads += 1
        if earlier { earlierReads += 1 }
        if shell { shellReads += 1 }
        let milliseconds = max(0, seconds * 1_000)
        totalMs += milliseconds
        maxMs = max(maxMs, milliseconds)
        maxItems = max(maxItems, items)
    }
}

/// Owned by the diagnostic queue. Two bounded files preserve data across launches.
final class PerformanceLog {
    static let byteLimit = 2 * 1_024 * 1_024
    private let directory: URL
    private let byteLimit: Int
    private let header: Data
    private var handle: FileHandle?
    private var size = 0
    private let encoder = JSONEncoder()
    private let date = ISO8601DateFormatter()

    init(directory: URL, metadata: [String: String], byteLimit: Int = PerformanceLog.byteLimit) throws {
        self.directory = directory
        self.byteLimit = byteLimit
        date.timeZone = .current
        var metadata = metadata as [String: Any]
        metadata["kind"] = "launch"
        metadata["schema"] = 1
        metadata["time"] = date.string(from: Date())
        header = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]) + Data([10])
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try open()
        // A hard quit may leave a partial last line; separate the new launch header.
        try append(Data([10]) + header)
    }

    private var current: URL { directory.appendingPathComponent("current.jsonl") }
    private var previous: URL { directory.appendingPathComponent("previous.jsonl") }

    private func open() throws {
        let files = FileManager.default
        if !files.fileExists(atPath: current.path) {
            guard files.createFile(atPath: current.path, contents: nil,
                                   attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let opened = try FileHandle(forWritingTo: current)
        size = Int(try opened.seekToEnd())
        handle = opened
    }

    func append(_ event: PerformanceEvent) throws {
        var event = event
        event.time = date.string(from: Date())
        try append(encoder.encode(event) + Data([10]))
    }

    private func append(_ data: Data) throws {
        guard handle != nil else { throw CocoaError(.fileWriteUnknown) }
        guard data.count + header.count < byteLimit else { throw CocoaError(.fileWriteOutOfSpace) }
        if size + data.count > byteLimit {
            try close()
            let files = FileManager.default
            if files.fileExists(atPath: previous.path) { try files.removeItem(at: previous) }
            try files.moveItem(at: current, to: previous)
            try open()
            try write(header)
        }
        try write(data)
    }

    private func write(_ data: Data) throws {
        guard let handle else { throw CocoaError(.fileWriteUnknown) }
        try handle.write(contentsOf: data)
        size += data.count
    }

    func close() throws {
        try handle?.close()
        handle = nil
    }

    deinit { try? handle?.close() }
}
