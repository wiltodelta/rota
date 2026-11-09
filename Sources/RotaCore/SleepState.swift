import Darwin

/// Whether the Mac is asleep as far as starting work goes: from the announced sleep to the announced
/// wake. A sleeping Mac keeps waking for seconds at a time (dark wake: network upkeep, Power Nap) and
/// Rota's timers run in those seconds, but neither `willSleep` nor `didWake` is posted for them.
public struct SleepState {
    public struct Reading {
        /// Seconds since boot, not counting sleep.
        public let awake: Double
        /// Seconds since boot, counting sleep.
        public let total: Double

        public init(awake: Double, total: Double) {
            self.awake = awake
            self.total = total
        }

        public static var now: Reading {
            Reading(awake: Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1e9,
                    total: Double(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1e9)
        }

        var slept: Double { total - awake }
    }

    /// With this long awake and no time slept, the announced sleep never happened, and no wake will
    /// be announced for it. Without this an aborted sleep would hold every routine indefinitely.
    static let abortedAfter: Double = 120
    /// The two clocks are read one after the other; less than this is not sleep.
    static let sleptAtLeast: Double = 1

    private var announced: Reading?

    public init() {}

    public mutating func willSleep(at reading: Reading = .now) {
        announced = reading
    }

    public mutating func didWake() {
        announced = nil
    }

    public func isAsleep(at reading: Reading = .now) -> Bool {
        guard let announced else { return false }
        return reading.slept - announced.slept >= Self.sleptAtLeast
            || reading.awake - announced.awake < Self.abortedAfter
    }
}
