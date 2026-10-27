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
        routine.nextFire = routine.enabled
            ? (try? CronSchedule(routine.schedule))?.next(after: now(), calendar: calendar)
            : nil
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
        routine.enabled = enabled
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
        let control = controls[id]
        if let record = active[id] { cancelQuestions(on: record) }
        launchIDs[id] = nil
        active[id] = nil
        controls[id] = nil
        runStarts[id] = nil
        pendingResumes = pendingResumes.filter { $0.value != id }
        pendingReruns[id] = nil
        reruns[id] = nil
        sleptThrough.remove(id)
        routines = next
        control?.stop()
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
