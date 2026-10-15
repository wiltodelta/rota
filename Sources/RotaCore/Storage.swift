import Foundation
import os

/// Where Rota keeps its routines, run history and logs.
public struct StorageLocation: Sendable {
    public let root: URL
    public let logs: URL

    public init(root: URL, logs: URL) {
        self.root = root
        self.logs = logs
    }

    /// The app's data: `ROTA_DATA_DIR` when set (checks give each run a fresh one),
    /// else "Rota", or "Rota Dev" for a development build (bundle id
    /// com.wiltodelta.rota.dev), so a build under test never reads or writes the
    /// installed app's routines. The `rota` command inside a bundle follows its app.
    public static var standard: StorageLocation {
        if let directory = ProcessInfo.processInfo.environment["ROTA_DATA_DIR"], !directory.isEmpty {
            let root = URL(fileURLWithPath: (directory as NSString).expandingTildeInPath)
            return StorageLocation(root: root, logs: root.appendingPathComponent("Logs"))
        }
        let files = FileManager.default
        let support = files.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let library = files.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        let name = appBundleIdentifier?.hasSuffix(".dev") == true ? "Rota Dev" : "Rota"
        return StorageLocation(root: support.appendingPathComponent(name),
                               logs: library.appendingPathComponent("Logs/\(name)"))
    }

    /// This process's app: its own bundle, or for a helper such as
    /// Contents/Helpers/rota the app it sits in.
    static var appBundleIdentifier: String? {
        if let id = Bundle.main.bundleIdentifier { return id }
        var url = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
        while url.path != "/" {
            url.deleteLastPathComponent()
            if url.pathExtension == "app" { return Bundle(url: url)?.bundleIdentifier }
        }
        return nil
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
        let routines = try JSONFile.read([Routine].self, from: location.routinesFile) ?? []
        guard Self.validIDs(routines) else {
            throw ControlError("Routines contain unsafe or duplicate ids. Repair routines.json before reopening Rota.")
        }
        return routines
    }

    public func save(_ routines: [Routine]) throws {
        guard Self.validIDs(routines) else {
            throw ControlError("Routine ids must be unique safe file names.")
        }
        try JSONFile.write(routines, to: location.routinesFile)
    }

    private static func validIDs(_ routines: [Routine]) -> Bool {
        routines.allSatisfy { Routine.isSafeStorageID($0.id) }
            && Set(routines.map { Routine.storageIDKey($0.id) }).count == routines.count
    }
}

/// Per-routine run history, newest first, bounded with the logs it points to.
public struct RunHistory: Sendable {
    public static let limit = 50
    private static let log = Logger(subsystem: "com.wiltodelta.rota", category: "history")
    let location: StorageLocation

    public init(location: StorageLocation) {
        self.location = location
    }

    private func file(for routineID: String) -> URL {
        location.historyDirectory.appendingPathComponent("\(routineID).json")
    }

    public func records(for routineID: String) -> [RunRecord] {
        do { return try loadRecords(for: routineID) } catch {
            Self.log.error("Could not read run history: \(error.localizedDescription, privacy: .private)")
            return []
        }
    }

    func loadRecords(for routineID: String) throws -> [RunRecord] {
        guard Routine.isSafeStorageID(routineID) else { throw ControlError("The routine id is not a safe file name.") }
        let records = try JSONFile.read([RunRecord].self, from: file(for: routineID)) ?? []
        guard records.allSatisfy({ $0.routineID == routineID }),
              Set(records.map(\.id)).count == records.count else {
            throw ControlError("Run history contains another routine's records or duplicate session ids.")
        }
        return records
    }

    /// Inserts or replaces `record` and drops the oldest records past the limit, with their logs.
    public func upsert(_ record: RunRecord) throws {
        var records = try loadRecords(for: record.routineID)
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.insert(record, at: 0)
        }
        records.sort { $0.startedAt > $1.startedAt }
        // Skipped slots must never evict an active conversation and its open log.
        let sessions = records.filter { !$0.isSkip }
        let retained = Array(sessions.filter { $0.outcome == .running })
            + Array(sessions.filter { $0.outcome != .running }.prefix(Self.limit))
        let kept = Set((retained + records.filter(\.isSkip).prefix(max(0, Self.limit - retained.count))).map(\.id))
        // Commit the index first: a failed write must not delete logs it still references.
        try JSONFile.write(records.filter { kept.contains($0.id) }, to: file(for: record.routineID))
        for dropped in records where !kept.contains(dropped.id) {
            if let path = dropped.logPath { removeLog(path) }
        }
    }

    /// Marks runs left `running` by a previous launch as interrupted and returns them.
    @discardableResult
    public func closeOrphans(routineIDs: [String], now: Date) throws -> [RunRecord] {
        var closed: [RunRecord] = []
        for routineID in routineIDs {
            for var record in try loadRecords(for: routineID) where record.outcome == .running {
                record.outcome = record.stopRequestedAt == nil ? .interrupted : .cancelled
                record.endedAt = now
                record.clearProviderRequests()
                try upsert(record)
                closed.append(record)
            }
        }
        return closed
    }

    public func removeAll(for routineID: String) {
        guard Routine.isSafeStorageID(routineID) else { return }
        for record in records(for: routineID) {
            if let path = record.logPath { removeLog(path) }
        }
        try? FileManager.default.removeItem(at: file(for: routineID))
    }

    private func removeLog(_ path: String) {
        let log = URL(fileURLWithPath: path)
        let root = location.logs.resolvingSymlinksInPath().standardizedFileURL.path + "/"
        guard log.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(root), log.pathExtension == "log" else {
            Self.log.error("Refused to remove a log outside Rota's log directory")
            return
        }
        try? FileManager.default.removeItem(at: log)
        try? FileManager.default.removeItem(at: SessionEventReader.file(for: log))
        try? FileManager.default.removeItem(at: log.deletingPathExtension().appendingPathExtension("attachments"))
    }

    public func logFile(for record: RunRecord) -> URL {
        let stamp = ISO8601DateFormatter().string(from: record.startedAt)
            .replacingOccurrences(of: ":", with: "-")
        return location.logs.appendingPathComponent(record.routineID)
            .appendingPathComponent("\(stamp)-\(record.id.uuidString).log")
    }
}
