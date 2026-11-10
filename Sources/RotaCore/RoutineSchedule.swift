import Foundation

extension Routine {
    public var isScheduleComplete: Bool {
        scheduleCompletedAt != nil || (repeats ? runLimit.map { scheduledRunCount >= $0 } ?? false
            : scheduledRunCount > 0)
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
        let earliest = scheduledAt.map { max(date, $0.addingTimeInterval(-1)) } ?? date
        return (try? CronSchedule(schedule))?.next(after: earliest, calendar: calendar)
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

extension Scheduler {
    public func tick() {
        // Offline (just woken, no Wi-Fi yet), a due slot waits rather than failing; it runs once online.
        guard isOnline() else { return }
        refreshSurvivingSession()
        reconcilePending()
        let current = now()
        var changed = false
        for index in routines.indices where routines[index].enabled {
            guard let due = routines[index].nextFire else {
                routines[index].nextFire = routines[index].nextScheduledFire(after: current, calendar: calendar)
                changed = true
                continue
            }
            guard due <= current else { continue }
            let busy = hasActiveSession(routines[index].id)
                || survivingSessions.values.contains(where: { $0.routineID == routines[index].id })
            // A one-time slot waits for its existing session, within the normal catch-up grace.
            if !routines[index].repeats, busy, current.timeIntervalSince(due) <= Self.missedRunGrace { continue }
            routines[index].nextFire = routines[index].repeats
                ? routines[index].nextScheduledFire(after: current, calendar: calendar) : nil
            changed = true
            let routine = routines[index]
            if current.timeIntervalSince(due) > Self.missedRunGrace {
                if !routine.repeats { routines[index].completeSchedule(at: current) }
                record(skipped: "missed the \(due.formatted(date: .abbreviated, time: .shortened)) slot",
                       routine: routine, at: current)
            } else if busy {
                record(skipped: "the previous run was still going", routine: routine, at: current, notify: false)
            } else {
                // A minute late is the tick's own lag; later than that, the slot was missed.
                if !run(routine, trigger: current.timeIntervalSince(due) > 120 ? .catchUp : .scheduled) {
                    routines[index].nextFire = due
                }
            }
        }
        if changed { persist() }
    }

    private func record(skipped reason: String, routine: Routine, at date: Date, notify: Bool = true) {
        let record = RunRecord(routineID: routine.id, trigger: .scheduled, harness: routine.harness,
                               startedAt: date, endedAt: date, outcome: .skipped(reason))
        saveRecord(record)
        Self.log.warning("\(routine.id, privacy: .public) skipped: \(reason, privacy: .public)")
        if notify { notifier?.runEnded(record, routine: routine) }
    }

    /// Persist the attempt before launching: a relaunch must not repeat a consumed slot.
    func reserveScheduledRun(_ routine: Routine) -> Bool {
        guard let index = routines.firstIndex(where: { $0.id == routine.id }) else {
            return routine.repeats && routine.runLimit == nil
        }
        guard !routines[index].isScheduleComplete else { return false }
        var next = routines
        if next[index].scheduledRunCount < Int.max { next[index].scheduledRunCount += 1 }
        if !next[index].repeats || next[index].isScheduleComplete {
            next[index].completeSchedule(at: now())
        }
        guard persist(next) else { return false }
        routines = next
        return true
    }
}
