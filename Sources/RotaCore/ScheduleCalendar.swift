import Foundation

public enum CalendarViewMode: String, CaseIterable, Codable, Sendable, Identifiable {
    case week
    case month
    case agenda

    public var id: Self { self }

    public var title: String {
        switch self {
        case .week: return "Week"
        case .month: return "Month"
        case .agenda: return "Agenda"
        }
    }
}

public struct CalendarEntry: Identifiable, Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case record(RunRecord)
        case scheduled(paused: Bool)
    }

    public let id: String
    public let routineID: String
    public let routineName: String
    public let harness: Harness
    public let start: Date
    public let end: Date?
    public let count: Int
    public let scheduleSummary: String?
    public let kind: Kind

    public var isFrequent: Bool { count > 1 }

    public var isPaused: Bool {
        if case .scheduled(let paused) = kind { return paused }
        return false
    }

    public var record: RunRecord? {
        if case .record(let record) = kind { return record }
        return nil
    }

    public var isProminent: Bool { record?.isProminent == true }
}

public struct CalendarDay: Identifiable, Equatable, Sendable {
    public let id: String
    public let date: Date
    public let isCurrentMonth: Bool
    public let isToday: Bool
    public var entries: [CalendarEntry]

    public var frequentEntries: [CalendarEntry] { entries.filter(\.isFrequent) }
    public var timedEntries: [CalendarEntry] { entries.filter { !$0.isFrequent } }

    public var recordedCount: Int {
        entries.reduce(0) { $0 + ($1.record == nil ? 0 : $1.count) }
    }

    public var scheduledCount: Int {
        entries.reduce(0) { $0 + ($1.record == nil ? $1.count : 0) }
    }
}

/// Combines recorded session history with upcoming scheduled slots on a local calendar.
public enum ScheduleCalendar {
    public static let frequentThreshold = 6
    public static let agendaDays = 14

    private struct DayRoutineKey: Hashable {
        let dayID: String
        let routineID: String
    }

    public static func weekInterval(containing anchor: Date, calendar: Calendar = .current) -> DateInterval {
        let start = calendar.dateInterval(of: .weekOfYear, for: anchor)?.start ?? calendar.startOfDay(for: anchor)
        let end = calendar.date(byAdding: .day, value: 7, to: start) ?? start.addingTimeInterval(7 * 86_400)
        return DateInterval(start: start, end: end)
    }

    public static func monthGridInterval(
        containing anchor: Date, calendar: Calendar = .current
    ) -> (month: DateInterval, grid: DateInterval) {
        let fallback = weekInterval(containing: anchor, calendar: calendar)
        let month = calendar.dateInterval(of: .month, for: anchor) ?? fallback
        let gridStart = weekInterval(containing: month.start, calendar: calendar).start
        let lastMoment = month.end.addingTimeInterval(-1)
        let gridEnd = weekInterval(containing: lastMoment, calendar: calendar).end
        return (month, DateInterval(start: gridStart, end: max(gridEnd, month.end)))
    }

    public static func agendaInterval(
        startingAt anchor: Date, days: Int = agendaDays, calendar: Calendar = .current
    ) -> DateInterval {
        let start = calendar.startOfDay(for: anchor)
        let clamped = max(1, min(days, 366))
        let end = calendar.date(byAdding: .day, value: clamped, to: start)
            ?? start.addingTimeInterval(Double(clamped) * 86_400)
        return DateInterval(start: start, end: end)
    }

    public struct Window: Sendable {
        public let visible: DateInterval
        public let query: DateInterval
        public let currentMonth: DateInterval?
    }

    public static func window(
        for mode: CalendarViewMode, anchor: Date, calendar: Calendar = .current
    ) -> Window {
        switch mode {
        case .week:
            let interval = weekInterval(containing: anchor, calendar: calendar)
            return Window(visible: interval, query: interval, currentMonth: nil)
        case .month:
            let (month, grid) = monthGridInterval(containing: anchor, calendar: calendar)
            return Window(visible: month, query: grid, currentMonth: month)
        case .agenda:
            let interval = agendaInterval(startingAt: anchor, days: agendaDays, calendar: calendar)
            return Window(visible: interval, query: interval, currentMonth: nil)
        }
    }

    public static func stepped(
        _ anchor: Date, mode: CalendarViewMode, by offset: Int, calendar: Calendar = .current
    ) -> Date {
        switch mode {
        case .week:
            return calendar.date(byAdding: .day, value: 7 * offset, to: anchor) ?? anchor
        case .month:
            return calendar.date(byAdding: .month, value: offset, to: anchor) ?? anchor
        case .agenda:
            return calendar.date(byAdding: .day, value: agendaDays * offset, to: anchor) ?? anchor
        }
    }

    public static func dayIdentifier(for date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    public struct Query: Sendable {
        public var interval: DateInterval
        public var currentMonth: DateInterval?
        public var now: Date
        public var includePaused: Bool
        public var routineID: String?
        public var calendar: Calendar

        public init(
            interval: DateInterval, currentMonth: DateInterval? = nil, now: Date,
            includePaused: Bool = false, routineID: String? = nil, calendar: Calendar = .current
        ) {
            self.interval = interval
            self.currentMonth = currentMonth
            self.now = now
            self.includePaused = includePaused
            self.routineID = routineID
            self.calendar = calendar
        }
    }

    fileprivate struct RoutineContext {
        let routine: Routine
        let summary: String
    }

    public static func days(
        query: Query, routines: [Routine], records: [RunRecord]
    ) -> [CalendarDay] {
        let activeRoutines = query.routineID.map { id in routines.filter { $0.id == id } } ?? routines
        let activeRecords = query.routineID.map { id in records.filter { $0.routineID == id } } ?? records
        let routinesByID = Dictionary(uniqueKeysWithValues: activeRoutines.map { ($0.id, $0) })

        var summaries: [String: String] = [:]
        var entriesByDay: [String: [CalendarEntry]] = [:]
        appendRecords(
            activeRecords, query: query, routinesByID: routinesByID,
            summaries: &summaries, to: &entriesByDay
        )
        for routine in activeRoutines {
            guard !routine.isScheduleComplete, routine.enabled || query.includePaused else { continue }
            let summary = summaries[routine.id] ?? {
                let text = routine.scheduleDescription
                summaries[routine.id] = text
                return text
            }()
            appendProjected(
                info: RoutineContext(routine: routine, summary: summary),
                query: query, to: &entriesByDay
            )
        }
        return buildDays(query: query, entriesByDay: entriesByDay)
    }

    private static func entryOrder(_ lhs: CalendarEntry, _ rhs: CalendarEntry) -> Bool {
        if lhs.start != rhs.start { return lhs.start < rhs.start }
        if lhs.isFrequent != rhs.isFrequent { return lhs.isFrequent && !rhs.isFrequent }
        if lhs.routineName != rhs.routineName { return lhs.routineName < rhs.routineName }
        return lhs.id < rhs.id
    }

    private static func buildDays(
        query: Query, entriesByDay: [String: [CalendarEntry]]
    ) -> [CalendarDay] {
        var days: [CalendarDay] = []
        var cursor = query.calendar.startOfDay(for: query.interval.start)
        while cursor < query.interval.end {
            let id = dayIdentifier(for: cursor, calendar: query.calendar)
            let inMonth = query.currentMonth.map { cursor >= $0.start && cursor < $0.end } ?? true
            let today = query.calendar.isDate(cursor, inSameDayAs: query.now)
            let sorted = (entriesByDay[id] ?? []).sorted(by: entryOrder)
            days.append(CalendarDay(id: id, date: cursor, isCurrentMonth: inMonth, isToday: today, entries: sorted))
            guard let next = query.calendar.date(byAdding: .day, value: 1, to: cursor), next > cursor else { break }
            cursor = next
        }
        return days
    }

    private static func appendRecords(
        _ records: [RunRecord], query: Query, routinesByID: [String: Routine],
        summaries: inout [String: String], to entries: inout [String: [CalendarEntry]]
    ) {
        let inWindow = records.filter { $0.startedAt >= query.interval.start && $0.startedAt < query.interval.end }
        let byDayAndRoutine = Dictionary(grouping: inWindow) { record in
            DayRoutineKey(
                dayID: dayIdentifier(for: record.startedAt, calendar: query.calendar),
                routineID: record.routineID
            )
        }
        for (key, group) in byDayAndRoutine {
            let routine = routinesByID[key.routineID]
            let name = routine?.name ?? key.routineID
            let summary = routine.map { item in
                if let cached = summaries[item.id] { return cached }
                let text = item.scheduleDescription
                summaries[item.id] = text
                return text
            }
            let sorted = group.sorted { $0.startedAt < $1.startedAt }
            var quietRuns: [RunRecord] = []
            var quietSkips: [RunRecord] = []
            for record in sorted {
                if record.isProminent {
                    entries[key.dayID, default: []].append(recordEntry(record, name: name, summary: summary))
                } else if record.isSkip {
                    quietSkips.append(record)
                } else {
                    quietRuns.append(record)
                }
            }
            entries[key.dayID, default: []].append(
                contentsOf: collapseRecords(quietRuns, dayID: key.dayID, name: name, summary: summary))
            entries[key.dayID, default: []].append(
                contentsOf: collapseRecords(quietSkips, dayID: key.dayID, name: name, summary: summary))
        }
    }

    private static func collapseRecords(
        _ group: [RunRecord], dayID: String, name: String, summary: String?
    ) -> [CalendarEntry] {
        guard group.count > frequentThreshold, let first = group.first, let last = group.last else {
            return group.map { recordEntry($0, name: name, summary: summary) }
        }
        let kindTag = last.isSkip ? "skip-burst" : "run-burst"
        return [CalendarEntry(
            id: "\(kindTag):\(last.routineID):\(dayID)", routineID: last.routineID, routineName: name,
            harness: last.harness, start: first.startedAt, end: last.startedAt, count: group.count,
            scheduleSummary: summary, kind: .record(last)
        )]
    }

    private static func recordEntry(_ record: RunRecord, name: String, summary: String?) -> CalendarEntry {
        CalendarEntry(
            id: "record:\(record.id.uuidString)", routineID: record.routineID, routineName: name,
            harness: record.harness, start: record.startedAt, end: record.endedAt, count: 1,
            scheduleSummary: summary, kind: .record(record)
        )
    }
}

private extension ScheduleCalendar {
    static func appendProjected(
        info: RoutineContext, query: Query, to entries: inout [String: [CalendarEntry]]
    ) {
        if !info.routine.repeats {
            appendOneTime(info: info, query: query, to: &entries)
            return
        }
        guard let cron = try? CronSchedule(info.routine.schedule) else { return }
        appendRepeating(info: info, cron: cron, query: query, to: &entries)
    }

    private static func appendOneTime(
        info: RoutineContext, query: Query, to entries: inout [String: [CalendarEntry]]
    ) {
        let routine = info.routine
        let candidate = routine.enabled ? (routine.nextFire ?? routine.scheduledAt) : routine.scheduledAt
        guard let fire = candidate else { return }
        let pendingDue = routine.enabled && routine.nextFire != nil && routine.isWithinGrace(fire, at: query.now)
        guard fire > query.now || pendingDue,
              fire >= query.interval.start, fire < query.interval.end else { return }
        let dayID = dayIdentifier(for: fire, calendar: query.calendar)
        entries[dayID, default: []].append(slotEntry(info: info, start: fire))
    }

    private static func appendRepeating(
        info: RoutineContext, cron: CronSchedule, query: Query, to entries: inout [String: [CalendarEntry]]
    ) {
        let routine = info.routine
        var remaining = routine.remainingScheduledRuns
        if remaining == 0 { return }
        let earliest = routine.cronFloor(after: query.now)
        let cronFloor = query.calendar.dateInterval(of: .minute, for: earliest)?.end ?? earliest
        var firstFloor = cronFloor
        if routine.enabled, let due = routine.nextFire {
            if routine.isWithinGrace(due, at: query.now) {
                if due >= query.interval.start, due < query.interval.end {
                    let dayID = dayIdentifier(for: due, calendar: query.calendar)
                    entries[dayID, default: []].append(slotEntry(info: info, start: due))
                }
                if let left = remaining { remaining = left - 1 }
                if remaining == 0 { return }
            } else if due > cronFloor {
                firstFloor = due
            }
        }
        guard query.interval.end > firstFloor else { return }
        if var left = remaining, query.interval.start > firstFloor {
            consumePriorSlots(cron: cron, window: DateInterval(start: firstFloor, end: query.interval.start),
                              remaining: &left, calendar: query.calendar)
            remaining = left
            if left == 0 { return }
        }
        var visible = query
        visible.interval = DateInterval(start: max(firstFloor, query.interval.start), end: query.interval.end)
        projectVisibleDays(info: info, cron: cron, query: visible, remaining: &remaining, to: &entries)
    }

    private static func consumePriorSlots(
        cron: CronSchedule, window: DateInterval, remaining: inout Int, calendar: Calendar
    ) {
        var day = calendar.startOfDay(for: window.start)
        for _ in 0..<(366 * 5) where day < window.end {
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: day), nextDay > day else { return }
            let hits: Int
            if day >= window.start, nextDay <= window.end,
               CronSchedule.isStandardLocalDay(day, calendar: calendar) {
                hits = cron.matches(day: day, calendar: calendar) ? cron.dailySlotCount : 0
            } else {
                hits = cron.times(on: day, notBefore: window.start,
                                  before: min(nextDay, window.end), calendar: calendar).count
            }
            remaining = max(0, remaining - hits)
            if remaining == 0 { return }
            day = nextDay
        }
    }

    private static func projectVisibleDays(
        info: RoutineContext, cron: CronSchedule, query: Query,
        remaining: inout Int?, to entries: inout [String: [CalendarEntry]]
    ) {
        let calendar = query.calendar
        var day = calendar.startOfDay(for: query.interval.start)
        while day < query.interval.end {
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: day), nextDay > day else { break }
            var slots = cron.times(on: day, notBefore: query.interval.start,
                                   before: min(nextDay, query.interval.end), calendar: calendar)
            if let left = remaining {
                slots = Array(slots.prefix(left))
                remaining = left - slots.count
            }
            if !slots.isEmpty {
                let dayID = dayIdentifier(for: day, calendar: calendar)
                let frequent = slots.count > 1
                    && (slots.count > frequentThreshold || cron.dailySlotCount > frequentThreshold)
                if frequent, let first = slots.first, let last = slots.last {
                    entries[dayID, default: []].append(
                        slotEntry(info: info, start: first, end: last, count: slots.count, dayID: dayID)
                    )
                } else {
                    for slot in slots {
                        entries[dayID, default: []].append(slotEntry(info: info, start: slot))
                    }
                }
            }
            if remaining == 0 { break }
            day = nextDay
        }
    }

    private static func slotEntry(
        info: RoutineContext, start: Date, end: Date? = nil, count: Int = 1, dayID: String = ""
    ) -> CalendarEntry {
        let routine = info.routine
        let id = count > 1 ? "burst:\(routine.id):\(dayID)"
            : "slot:\(routine.id):\(Int(start.timeIntervalSince1970))"
        return CalendarEntry(
            id: id, routineID: routine.id, routineName: routine.name, harness: routine.harness,
            start: start, end: end, count: count, scheduleSummary: info.summary,
            kind: .scheduled(paused: !routine.enabled)
        )
    }
}
