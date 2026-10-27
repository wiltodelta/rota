import Darwin
import Foundation

/// A PID plus its kernel birth time. Signals never target a reused PID.
struct OwnedProcess: Codable, Sendable {
    let pid: Int32
    let parent: UInt32
    let seconds: UInt64
    let microseconds: UInt64

    init?(pid: Int32) {
        var info = proc_bsdinfo()
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info))) > 0
        else { return nil }
        self.pid = pid
        parent = info.pbi_ppid
        seconds = info.pbi_start_tvsec
        microseconds = info.pbi_start_tvusec
    }

    var exists: Bool {
        guard let current = OwnedProcess(pid: pid) else { return false }
        return current.seconds == seconds && current.microseconds == microseconds
    }

    func signal(_ signal: Int32) {
        if exists { kill(pid, signal) }
    }

    /// Capture descendants before terminating their parent; ancestry alone is not a reusable identity.
    func descendants() -> [OwnedProcess] {
        guard exists else { return [] }
        var pids = [pid_t](repeating: 0, count: 4096)
        let bytes = pids.withUnsafeMutableBytes { proc_listchildpids(pid, $0.baseAddress, Int32($0.count)) }
        guard bytes > 0 else { return [] }
        return pids.prefix(Int(bytes) / MemoryLayout<pid_t>.size).flatMap { id -> [OwnedProcess] in
            guard let child = OwnedProcess(pid: id), child.parent == UInt32(pid) else { return [] }
            return child.descendants() + [child]
        }
    }
}
