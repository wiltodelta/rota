import Foundation

/// Where Rota keeps its routines, run history and logs.
public struct StorageLocation: Sendable {
    public let root: URL
    public let logs: URL

    public init(root: URL, logs: URL) {
        self.root = root
        self.logs = logs
    }

    public static var standard: StorageLocation {
        let files = FileManager.default
        let support = files.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let library = files.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        return StorageLocation(root: support.appendingPathComponent("Rota"),
                               logs: library.appendingPathComponent("Logs/Rota"))
    }

    var routinesFile: URL { root.appendingPathComponent("routines.json") }
    var historyDirectory: URL { root.appendingPathComponent("runs") }
}

enum JSONFile {
    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    static func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try decoder.decode(type, from: Data(contentsOf: url))
    }

    static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try encoder.encode(value).write(to: url, options: .atomic)
    }
}

public struct RoutineStore: Sendable {
    let location: StorageLocation

    public init(location: StorageLocation) {
        self.location = location
    }

    public func load() throws -> [Routine] {
        try JSONFile.read([Routine].self, from: location.routinesFile) ?? []
    }

    public func save(_ routines: [Routine]) throws {
        try JSONFile.write(routines, to: location.routinesFile)
    }
}

/// Per-routine run history, newest first, bounded with the logs it points to.
public struct RunHistory: Sendable {
    public static let limit = 50
    let location: StorageLocation

    public init(location: StorageLocation) {
        self.location = location
    }

    private func file(for routineID: String) -> URL {
        location.historyDirectory.appendingPathComponent("\(routineID).json")
    }

    public func records(for routineID: String) -> [RunRecord] {
        (try? JSONFile.read([RunRecord].self, from: file(for: routineID))) ?? []
    }

    /// Inserts or replaces `record` and drops the oldest records past the limit, with their logs.
    public func upsert(_ record: RunRecord) throws {
        var records = self.records(for: record.routineID)
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.insert(record, at: 0)
        }
        records.sort { $0.startedAt > $1.startedAt }
        for dropped in records.dropFirst(Self.limit) {
            if let path = dropped.logPath { try? FileManager.default.removeItem(atPath: path) }
        }
        try JSONFile.write(Array(records.prefix(Self.limit)), to: file(for: record.routineID))
    }

    /// Marks runs left `running` by a previous launch as interrupted.
    public func closeOrphans(routineIDs: [String], now: Date) {
        for routineID in routineIDs {
            for var record in records(for: routineID) where record.outcome == .running {
                record.outcome = .interrupted
                record.endedAt = now
                try? upsert(record)
            }
        }
    }

    public func removeAll(for routineID: String) {
        for record in records(for: routineID) {
            if let path = record.logPath { try? FileManager.default.removeItem(atPath: path) }
        }
        try? FileManager.default.removeItem(at: file(for: routineID))
    }

    public func logFile(for record: RunRecord) -> URL {
        let stamp = ISO8601DateFormatter().string(from: record.startedAt)
            .replacingOccurrences(of: ":", with: "-")
        return location.logs.appendingPathComponent(record.routineID)
            .appendingPathComponent("\(stamp).log")
    }
}
