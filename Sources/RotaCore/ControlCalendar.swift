import Foundation

extension Scheduler {
    func calendarOverview(_ params: [String: Any]) throws -> [String: Any] {
        let routineID = try optional(params, "id", as: String.self)
        let targetRoutines: [Routine]
        if let routineID {
            guard let found = routine(routineID) else {
                throw ControlError("No routine \(routineID).")
            }
            targetRoutines = [found]
        } else {
            targetRoutines = routines
        }
        let dayCount = try optional(params, "days", as: Int.self) ?? 7
        guard (1...366).contains(dayCount) else {
            throw ControlError("days must be between 1 and 366.")
        }
        let includePaused = try optional(params, "includePaused", as: Bool.self) ?? false
        let current = now()
        let start: Date
        if let rawFrom = try optional(params, "from", as: String.self) {
            guard let parsed = Self.parseCalendarAnchor(rawFrom, calendar: calendar) else {
                throw ControlError("from needs YYYY-MM-DD or an ISO 8601 date and time with a zone.")
            }
            start = parsed
        } else {
            start = calendar.startOfDay(for: current)
        }
        let interval = ScheduleCalendar.agendaInterval(startingAt: start, days: dayCount, calendar: calendar)
        let query = ScheduleCalendar.Query(
            interval: interval, now: current, includePaused: includePaused,
            routineID: routineID, calendar: calendar
        )
        let targetRecords = targetRoutines.flatMap { routine in
            records(for: routine.id).filter { $0.startedAt >= interval.start && $0.startedAt < interval.end }
        }
        let days = ScheduleCalendar.days(query: query, routines: targetRoutines, records: targetRecords)
        return [
            "start": Self.timestamp.string(from: interval.start),
            "end": Self.timestamp.string(from: interval.end),
            "days": dayCount,
            "timeZone": calendar.timeZone.identifier,
            "includePaused": includePaused,
            "calendar": days.map { describeCalendarDay($0) }
        ]
    }

    static func parseCalendarAnchor(_ text: String, calendar: Calendar) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: "-", omittingEmptySubsequences: false)
        if parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
           let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]) {
            var components = DateComponents(year: year, month: month, day: day, hour: 12)
            components.calendar = calendar
            components.timeZone = calendar.timeZone
            guard let noon = calendar.date(from: components) else { return nil }
            let check = calendar.dateComponents([.year, .month, .day], from: noon)
            guard check.year == year, check.month == month, check.day == day else { return nil }
            return calendar.startOfDay(for: noon)
        }
        if let instant = parseISODate(trimmed) {
            return calendar.startOfDay(for: instant)
        }
        return nil
    }

    private func describeCalendarDay(_ day: CalendarDay) -> [String: Any] {
        [
            "date": day.id,
            "isToday": day.isToday,
            "entries": day.entries.map { describeCalendarEntry($0) }
        ]
    }

    private func describeCalendarEntry(_ entry: CalendarEntry) -> [String: Any] {
        var json: [String: Any] = [
            "routine": entry.routineID,
            "name": entry.routineName,
            "harness": entry.harness.rawValue,
            "startedAt": Self.timestamp.string(from: entry.start),
            "count": entry.count,
            "frequent": entry.isFrequent,
            "paused": entry.isPaused
        ]
        if let end = entry.end { json["endedAt"] = Self.timestamp.string(from: end) }
        if let summary = entry.scheduleSummary { json["scheduleText"] = summary }
        switch entry.kind {
        case .record(let record):
            json["kind"] = record.isSkip ? "skip" : "session"
            json["status"] = record.compactStatusTitle(canMessage: canMessage(record))
            if !record.isSkip { json["session"] = record.id.uuidString }
            if let attention = record.attention { json["needsReply"] = attention }
        case .scheduled(let paused):
            json["kind"] = "scheduled"
            json["status"] = paused ? "Paused" : "Scheduled"
        }
        return json
    }
}
