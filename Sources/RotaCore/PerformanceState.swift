import Darwin
import Foundation

struct PerformanceResources {
    var uptime: TimeInterval
    var cpuSeconds: TimeInterval?
    var residentBytes: UInt64?

    static func current() -> Self {
        var usage = rusage()
        let cpu: Double?
        if getrusage(RUSAGE_SELF, &usage) == 0 {
            cpu = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
                + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        } else {
            cpu = nil
        }
        var info = mach_task_basic_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout.size(ofValue: info) / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        return Self(uptime: ProcessInfo.processInfo.systemUptime, cpuSeconds: cpu,
                    residentBytes: result == KERN_SUCCESS ? info.resident_size : nil)
    }

    func cpuPercent(since previous: Self?) -> Double? {
        guard let previous, let cpuSeconds, let oldCPU = previous.cpuSeconds,
              uptime > previous.uptime, cpuSeconds >= oldCPU else { return nil }
        return (cpuSeconds - oldCPU) / (uptime - previous.uptime) * 100
    }
}

/// Pure state for one outstanding main-queue probe, with no timer or wall-clock waits.
struct PerformanceProbeState {
    struct Probe: Sendable {
        var id: UInt64
        var sent: TimeInterval
    }

    private var sequence: UInt64 = 0
    private(set) var pending: Probe?
    private var reported = false
    private(set) var sleeping = false
    var maxDelay: TimeInterval = 0

    mutating func begin(at now: TimeInterval) -> Probe? {
        guard !sleeping, pending == nil else { return nil }
        sequence &+= 1
        let probe = Probe(id: sequence, sent: now)
        pending = probe
        reported = false
        return probe
    }

    mutating func stalled(at now: TimeInterval) -> TimeInterval? {
        guard let pending, !reported, !sleeping, now - pending.sent >= 1 else { return nil }
        reported = true
        return now - pending.sent
    }

    mutating func finish(_ probe: Probe, at now: TimeInterval) -> TimeInterval? {
        guard pending?.id == probe.id, !sleeping else { return nil }
        pending = nil
        let delay = max(0, now - probe.sent)
        maxDelay = max(maxDelay, delay)
        return delay
    }

    mutating func setSleeping(_ value: Bool) {
        sleeping = value
        pending = nil
        maxDelay = 0
    }
}
