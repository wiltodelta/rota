import Foundation

extension Scheduler {
    // MARK: Editing

    public func routine(_ id: String) -> Routine? {
        routines.first { $0.id == id }
    }

    /// Adds or replaces a routine, recomputing its next slot from the saved schedule.
    @discardableResult
    public func save(_ routine: Routine) -> Bool {
        var routine = routine
        if let previous = self.routine(routine.id) {
            let unchanged = routine.hasSameSchedule(as: previous)
            routine.scheduledRunCount = unchanged ? previous.scheduledRunCount : 0
            routine.scheduleCompletedAt = unchanged ? previous.scheduleCompletedAt : nil
        }
        if routine.isScheduleComplete { routine.enabled = false }
        routine.nextFire = routine.enabled ? routine.nextScheduledFire(after: now(), calendar: calendar) : nil
        var next = routines
        if let index = next.firstIndex(where: { $0.id == routine.id }) {
            next[index] = routine
        } else {
            next.append(routine)
        }
        guard persist(next) else { return false }
        routines = next
        return true
    }

    @discardableResult
    public func setEnabled(_ enabled: Bool, for id: String) -> Bool {
        guard var routine = routine(id) else { return false }
        if enabled, routine.isScheduleComplete {
            lastError = "This schedule is complete. Edit its date, repetition or run limit to schedule it again."
            return false
        }
        routine.enabled = enabled
        if enabled, let problem = routine.scheduleProblem(now: now()) {
            lastError = problem
            return false
        }
        return save(routine)
    }

    @discardableResult
    public func delete(_ id: String) -> Bool {
        guard !hasSurvivingSession(id) else {
            lastError = "Close this routine's surviving native session before deleting it."
            return false
        }
        let next = routines.filter { $0.id != id }
        guard persist(next) else { return false }
        let records = active.values.filter { $0.routineID == id }
        let ownedControls = records.compactMap { controls[$0.id] }
        for record in records {
            cancelQuestions(on: record)
            launchIDs[record.id] = nil
            active[record.id] = nil
            controls[record.id] = nil
            runStarts[record.id] = nil
            lateMessages[record.id] = nil
            sleptThrough.remove(record.id)
        }
        pendingResumes = pendingResumes.filter { $0.value != id }
        pendingReruns[id] = nil
        reruns[id] = nil
        routines = next
        ownedControls.forEach { $0.stop() }
        history.removeAll(for: id)
        historyVersion += 1
        return true
    }

    /// Availability is drawn for every list row. Reuse the display snapshot;
    /// the action below reloads storage before removing anything.
    public func canDelete(_ record: RunRecord) -> Bool {
        guard !isActive(record), !isSurvivingSession(record),
              let stored = records(for: record.routineID).first(where: { $0.id == record.id }) else { return false }
        return stored.outcome != .running && stored.needsReconciliation != true
    }

    /// The confirmation can outlive the record it showed, so check current state again.
    @discardableResult
    public func deleteSession(_ record: RunRecord) -> Bool {
        guard let stored = current(record.id, routineID: record.routineID),
              stored.outcome != .running, stored.needsReconciliation != true,
              !isActive(stored), !isSurvivingSession(stored), !stillRunning(stored) else {
            lastError = "The session is running or is no longer in history."
            return false
        }
        do {
            guard try history.remove(record.id, for: record.routineID) else { return false }
            pendingResumes[record.id] = nil
            historyVersion += 1
            return true
        } catch {
            lastError = "Could not delete the session: \(error.localizedDescription)"
            Self.log.error("Could not delete session: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    @discardableResult
    func persist(_ next: [Routine]? = nil) -> Bool {
        do {
            try store.save(next ?? routines)
            return true
        } catch {
            lastError = "Could not save routines: \(error.localizedDescription)"
            Self.log.error("Could not save routines: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

}
