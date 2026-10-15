import Foundation
import SQLite3

/// Where routines can be imported from. Each source is read, never written:
/// the app that owns it rewrites its own store.
public enum ImportSource: String, CaseIterable, Sendable {
    case claudeDesktop
    case codex

    public var title: String {
        switch self {
        case .claudeDesktop: return "Claude Desktop"
        case .codex: return "Codex"
        }
    }

    /// The harness its routines ran on there.
    public var harness: Harness {
        switch self {
        case .claudeDesktop: return .claude
        case .codex: return .codex
        }
    }
}

/// A routine another app schedules, as Rota would import it.
public struct ImportCandidate: Identifiable, Equatable, Sendable {
    public var routine: Routine
    public var source: ImportSource
    /// Still on in its app, so turning it on in Rota too would run it twice.
    public var onInSource: Bool
    /// Why it cannot be imported, when it cannot.
    public var unsupported: String?
    /// The source's stable record id is independent of its display name and destination id.
    public var id: String

    public init(routine: Routine, source: ImportSource, onInSource: Bool, unsupported: String? = nil,
                sourceID: String? = nil) {
        self.routine = routine
        self.source = source
        self.onInSource = onInSource
        self.unsupported = unsupported
        id = "\(source.rawValue):\(sourceID ?? routine.id)"
    }
}

/// One source's routines, or why none could be read.
public struct ImportScan: Sendable {
    public var source: ImportSource
    public var candidates: [ImportCandidate]
    /// Set when the source was not found or could not be read.
    public var problem: String?
}

public enum RoutineImport {
    /// Every source, read now. Blocks on file reads: call it off the main thread.
    public static func scanAll(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [ImportScan] {
        uniqueIdentifiers(ImportSource.allCases.map { source in
            do {
                switch source {
                case .claudeDesktop:
                    guard let file = ClaudeDesktopImport.locate(home: home) else {
                        return ImportScan(source: source, candidates: [], problem: "No scheduled tasks found.")
                    }
                    return ImportScan(source: source, candidates: try ClaudeDesktopImport.candidates(from: file))
                case .codex:
                    let databases = CodexAutomationsImport.locate(home: home)
                    guard !databases.isEmpty else {
                        return ImportScan(source: source, candidates: [], problem: "No automations found.")
                    }
                    return ImportScan(source: source,
                                      candidates: try databases.flatMap(CodexAutomationsImport.candidates(from:)))
                }
            } catch {
                return ImportScan(source: source, candidates: [], problem: error.localizedDescription)
            }
        })
    }

    /// Allocate every destination id before displaying the choices, so one import cannot overwrite another.
    static func uniqueIdentifiers(_ scans: [ImportScan]) -> [ImportScan] {
        var used = Set<String>()
        return scans.map { scan in
            var scan = scan
            scan.candidates = scan.candidates.map { candidate in
                var candidate = candidate
                let base = candidate.routine.id
                var identifier = base
                var suffix = 2
                while used.contains(Routine.storageIDKey(identifier)) {
                    identifier = "\(base)-\(suffix)"
                    suffix += 1
                }
                used.insert(Routine.storageIDKey(identifier))
                candidate.routine.id = identifier
                if !Routine.isSafeStorageID(identifier) {
                    candidate.unsupported = "Its id cannot be used as a safe file name."
                }
                return candidate
            }
            return scan
        }
    }

    /// A routine id from a name: lowercase words joined by hyphens, any script.
    public static func identifier(from name: String) -> String {
        let words = name.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
        return words.filter { !$0.isEmpty }.joined(separator: "-")
    }
}

/// Reads the automations the Codex app schedules from its SQLite store,
/// read-only. Columns read from the store's schema on 2026-10-09.
public enum CodexAutomationsImport {
    struct ReadError: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    /// Codex's app databases that hold an `automations` table.
    public static func locate(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        let folder = home.appendingPathComponent(".codex/sqlite")
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "db" }.sorted { $0.path < $1.path }
    }

    public static func candidates(from database: URL) throws -> [ImportCandidate] {
        var handle: OpaquePointer?
        let uri = database.absoluteString + "?mode=ro"
        guard sqlite3_open_v2(uri, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK else {
            defer { sqlite3_close(handle) }
            throw ReadError(message: "Could not open \(database.lastPathComponent).")
        }
        defer { sqlite3_close(handle) }
        let query = """
            SELECT id, name, prompt, status, next_run_at, cwds, rrule, model, reasoning_effort, target_thread_id
            FROM automations ORDER BY name, id
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, query, -1, &statement, nil) == SQLITE_OK else {
            let reason = String(cString: sqlite3_errmsg(handle))
            // Only an absent table means there are no automations; changed columns or corruption are errors.
            if reason == "no such table: automations" { return [] }
            throw ReadError(message: "Could not read Codex automations: " + reason)
        }
        defer { sqlite3_finalize(statement) }
        var rows: [Row] = []
        var status = sqlite3_step(statement)
        while status == SQLITE_ROW {
            rows.append(Row(statement))
            status = sqlite3_step(statement)
        }
        guard status == SQLITE_DONE else {
            throw ReadError(message: "Could not read all Codex automations: " + String(cString: sqlite3_errmsg(handle)))
        }
        return rows.map { row in
            var item = candidate(row)
            item.id = "codex:\(database.lastPathComponent):\(row.id)"
            return item
        }
    }

    struct Row {
        var id, name, prompt, status, cwds, rrule: String
        var nextRun: Int64?
        var model, effort, targetThread: String?

        init(_ statement: OpaquePointer?) {
            func text(_ column: Int32) -> String? {
                sqlite3_column_text(statement, column).map { String(cString: $0) }
            }
            id = text(0) ?? ""
            name = text(1) ?? ""
            prompt = text(2) ?? ""
            status = text(3) ?? ""
            nextRun = sqlite3_column_type(statement, 4) == SQLITE_NULL ? nil : sqlite3_column_int64(statement, 4)
            cwds = text(5) ?? "[]"
            rrule = text(6) ?? ""
            model = text(7)
            effort = text(8)
            targetThread = text(9)
        }
    }

    static func candidate(_ row: Row) -> ImportCandidate {
        let folders = (try? JSONDecoder().decode([String].self, from: Data(row.cwds.utf8))) ?? []
        // Seconds or milliseconds since 1970; a millisecond count is past 10^12.
        let anchor = row.nextRun.map { Date(timeIntervalSince1970: Double($0) / ($0 > 1_000_000_000_000 ? 1000 : 1)) }
        let cron = ScheduleText.cron(fromRRule: row.rrule, anchor: anchor)
        let identifier = RoutineImport.identifier(from: row.name)
        let routine = Routine(id: identifier.isEmpty ? row.id : identifier, name: row.name,
                              workingDirectory: folders.first ?? "", schedule: cron ?? "",
                              harness: .codex, prompt: row.prompt, model: row.model, effort: row.effort)
        var unsupported: String?
        if row.targetThread != nil {
            unsupported = "Continues a Codex thread, which a routine cannot."
        } else if folders.isEmpty {
            unsupported = "Has no project folder."
        } else if folders.count > 1 {
            unsupported = "Uses multiple project folders, which a single-folder routine cannot preserve."
        } else if cron == nil {
            unsupported = "Its schedule (\(row.rrule)) has no cron equivalent."
        }
        return ImportCandidate(routine: routine, source: .codex, onInSource: row.status == "ACTIVE",
                               unsupported: unsupported, sourceID: row.id)
    }
}
