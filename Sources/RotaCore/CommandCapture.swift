import Darwin
import Foundation

/// Drains a short-lived helper without letting a child or an inherited pipe defeat its deadline.
enum CommandCapture {
    static func read(_ process: Process, output: FileHandle, timeout: TimeInterval?,
                     clock: () -> TimeInterval) -> (data: Data, timedOut: Bool) {
        let started = clock()
        let pid = process.processIdentifier
        // Foundation gives spawned helpers their own group. Never signal Rota's group.
        let group = getpgid(pid) == pid && pid != getpgrp() ? pid : nil
        let descriptor = output.fileDescriptor
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        var data = Data()
        var eof = false
        var terminatedAt: TimeInterval?
        while true {
            let current = clock()
            if let timeout, terminatedAt == nil, current - started >= timeout {
                terminatedAt = current
                signal(pid: pid, group: group, with: SIGTERM)
            }
            if let terminatedAt, current - terminatedAt >= 0.2 {
                signal(pid: pid, group: group, with: SIGKILL)
                // A descendant outside the group may still own stdout. It cannot keep us here.
                drain(descriptor, into: &data, eof: &eof)
                break
            }
            if eof, !process.isRunning, terminatedAt == nil { break }
            var watched = pollfd(fd: eof ? -1 : descriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
            _ = poll(&watched, 1, 20)
            if watched.revents != 0 { drain(descriptor, into: &data, eof: &eof) }
        }
        try? output.close()
        process.waitUntilExit()
        return (data, terminatedAt != nil)
    }

    private static func signal(pid: pid_t, group: pid_t?, with value: Int32) {
        kill(group.map { -$0 } ?? pid, value)
    }

    private static func drain(_ descriptor: Int32, into data: inout Data, eof: inout Bool) {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        // A helper that writes continuously still yields to the deadline check.
        for _ in 0..<16 {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0, errno == EINTR { continue }
            if count > 0 { data.append(contentsOf: buffer[..<count]) } else {
                if count == 0 { eof = true }
                return
            }
        }
    }
}
