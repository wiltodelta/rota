import Foundation

extension Routine {
    public static let missedRunGrace: TimeInterval = 7 * 24 * 3600

    public var isScheduleComplete: Bool {
        scheduleCompletedAt != nil || (repeats ? runLimit.map { scheduledRunCount >= $0 } ?? false
            : scheduledRunCount > 0)
    }

    public var remainingScheduledRuns: Int? {
        guard let limit = repeats ? runLimit : 1 else { return nil }
        return isScheduleComplete ? 0 : max(0, limit - scheduledRunCount)
    }

    func cronFloor(after date: Date) -> Date {
        scheduledAt.map { max(date, $0.addingTimeInterval(-1)) } ?? date
    }

    func isWithinGrace(_ due: Date, at now: Date) -> Bool {
        due <= now && now.timeIntervalSince(due) <= Self.missedRunGrace
    }

    public var scheduleDescription: String {
        if !repeats {
            return scheduledAt.map { "Once on " + $0.formatted(date: .abbreviated, time: .shortened) }
                ?? "Choose a date and time"
        }
        let text = ScheduleText.describe(schedule) ?? schedule
        guard let runLimit else { return text }
        return text + ". Ends after \(runLimit) scheduled \(runLimit == 1 ? "run" : "runs")"
    }

    public func nextScheduledFire(after date: Date, calendar: Calendar = .current) -> Date? {
        guard !isScheduleComplete else { return nil }
        if !repeats { return scheduledAt }
        return (try? CronSchedule(schedule))?.next(after: cronFloor(after: date), calendar: calendar)
    }

    func scheduleProblem(now: Date) -> String? {
        if repeats {
            if schedule.isEmpty { return "Choose a one-time date and time or a repeating schedule." }
            do { _ = try CronSchedule(schedule) } catch {
                return "The schedule \"\(schedule)\": \(error.localizedDescription)"
            }
        } else {
            if runLimit != nil { return "Run limits apply to repeating schedules. Choose a one-time date instead." }
            guard let scheduledAt else { return "Choose a date and time for the one-time run." }
            if enabled, !isScheduleComplete, scheduledAt <= now {
                return "Choose a future date and time for the one-time run."
            }
        }
        if let runLimit, runLimit < 1 { return "A run limit must be a positive integer, or none." }
        return nil
    }

    func hasSameSchedule(as other: Routine) -> Bool {
        schedule == other.schedule && scheduledAt == other.scheduledAt
            && repeats == other.repeats && runLimit == other.runLimit
    }

    mutating func completeSchedule(at date: Date) {
        enabled = false
        nextFire = nil
        scheduleCompletedAt = date
    }
}
