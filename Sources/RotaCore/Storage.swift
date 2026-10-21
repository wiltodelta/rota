import Foundation

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

    /// Keeps running sessions and pending questions, plus limits for finished sessions and skipped slots.
    public func upsert(_ record: RunRecord) throws {
        var records = try JSONFile.read([RunRecord].self, from: file(for: record.routineID)) ?? []
        if let index = records.firstIndex(where: { $0.id == record.id }) {
            records[index] = record
        } else {
            records.insert(record, at: 0)
        }
        records.sort { $0.startedAt > $1.startedAt }
        var sessions = 0
        var skips = 0
        let retained = records.filter { item in
            if item.outcome == .running || item.questions?.isEmpty == false { return true }
            if item.isSkip {
                skips += 1
                return skips <= Self.limit
            }
            sessions += 1
            return sessions <= Self.limit
        }
        try JSONFile.write(retained, to: file(for: record.routineID))
        guard retained.count != records.count else { return }
        let keptIDs = Set(retained.map(\.id))
        let keptLogs = Set(retained.compactMap {
            $0.logPath.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path }
        })
        for dropped in records where !keptIDs.contains(dropped.id) {
            if let path = dropped.logPath,
               !keptLogs.contains(URL(fileURLWithPath: path).resolvingSymlinksInPath().path) {
                removeLog(path, routineID: record.routineID)
            }
        }
    }

    /// Marks runs left `running` by a previous launch as interrupted and returns them.
    @discardableResult
    public func closeOrphans(routineIDs: [String], now: Date) -> [RunRecord] {
        var closed: [RunRecord] = []
        for routineID in routineIDs {
            for var record in records(for: routineID) where record.outcome == .running {
                if record.questions?.isEmpty == false {
                    let hadBlockingQuestion = record.questions?.contains { $0.replyViaMessage != true } == true
                    record.questions = record.questions?.filter { $0.replyViaMessage == true }
                    record.attention = record.nextQuestion?.title
                    if hadBlockingQuestion, record.questions?.isEmpty != false {
                        record.attention = "The session was interrupted while waiting for your answer. "
                            + "Continue it to ask again."
                    }
                }
                record.outcome = .interrupted
                record.endedAt = now
                try? upsert(record)
                closed.append(record)
            }
        }
        return closed
    }

    public func removeAll(for routineID: String) {
        for record in records(for: routineID) {
            if let path = record.logPath { removeLog(path, routineID: routineID) }
        }
        try? FileManager.default.removeItem(at: file(for: routineID))
    }

    /// Deletes one finished session and its owned logs, preserving shared files.
    @discardableResult
    public func remove(_ id: UUID, for routineID: String) throws -> Bool {
        let records = try JSONFile.read([RunRecord].self, from: file(for: routineID)) ?? []
        guard let record = records.first(where: { $0.id == id }) else { return false }
        guard record.outcome != .running else { throw HistoryDeletionError.running }
        let retained = records.filter { $0.id != id }
        if let path = record.logPath {
            let log = try ownedLog(path, routineID: routineID)
            let resolvedLog = log.resolvingSymlinksInPath().path
            let shared = retained.contains {
                $0.logPath.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } == resolvedLog
            }
            if !shared {
                for url in [log, TranscriptReader.journalURL(for: log), ChatAttachmentStore.folder(for: log)] {
                    do { try FileManager.default.removeItem(at: url) } catch let error as CocoaError
                        where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile { }
                }
            }
        }
        try JSONFile.write(retained, to: file(for: routineID))
        return true
    }

    public func attachments(for record: RunRecord) throws -> ChatAttachmentStore {
        guard let path = record.logPath else { throw HistoryDeletionError.foreignLog }
        return ChatAttachmentStore(log: try ownedLog(path, routineID: record.routineID))
    }

    private func ownedLog(_ path: String, routineID: String) throws -> URL {
        let log = URL(fileURLWithPath: path).standardizedFileURL
        let folder = location.logs.appendingPathComponent(routineID).resolvingSymlinksInPath()
        guard folder.deletingLastPathComponent().path == location.logs.resolvingSymlinksInPath().path,
              log.deletingLastPathComponent().resolvingSymlinksInPath().path == folder.path,
              log.pathExtension == "log" else { throw HistoryDeletionError.foreignLog }
        return log
    }

    /// A normalized transcript has exactly the same retention as its readable log.
    private func removeLog(_ path: String, routineID: String) {
        guard let log = try? ownedLog(path, routineID: routineID) else { return }
        try? FileManager.default.removeItem(at: log)
        try? FileManager.default.removeItem(at: TranscriptReader.journalURL(for: log))
        try? FileManager.default.removeItem(at: ChatAttachmentStore.folder(for: log))
    }

    public func logFile(for record: RunRecord) -> URL {
        let stamp = ISO8601DateFormatter().string(from: record.startedAt)
            .replacingOccurrences(of: ":", with: "-")
        return location.logs.appendingPathComponent(record.routineID)
            .appendingPathComponent("\(stamp)-\(record.id.uuidString).log")
    }
}

enum HistoryDeletionError: LocalizedError {
    case running, foreignLog

    var errorDescription: String? {
        switch self {
        case .running: "Stop the session before deleting it."
        case .foreignLog: "The session log is outside Rota's log folder."
        }
    }
}
