import Foundation

/// Durable ownership of a local CLI. A stale lease cannot authorize a signal to a reused PID.
struct RunLease: Codable {
    var process: OwnedProcess?
    var id: String
    var screenName: String?
    var nativeOffset: UInt64?

    static func url(_ log: URL) -> URL { log.appendingPathExtension("runtime.json") }
    static func read(_ log: URL) -> RunLease? {
        guard let data = try? Data(contentsOf: url(log)) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
    func write(_ log: URL) throws { try JSONEncoder().encode(self).write(to: Self.url(log), options: .atomic) }
    static func save(_ process: Process, log: URL, id: String) throws -> RunLease {
        let lease = Self(process: OwnedProcess(pid: process.processIdentifier), id: id)
        try lease.write(log)
        return lease
    }
}
