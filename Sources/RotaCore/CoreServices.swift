import Foundation

public enum ScheduleText {
    public static let presets = ["0 * * * *", "0 9 * * *", "0 9 * * 1-5", "0 9 * * 1", "0 9 1 * *"]

    public static func describe(_ expression: String, locale: Locale = .current) -> String? {
        _ = locale
        return try? FFIBridge.callCore(String?.self, "scheduleText.describe", params: [
            "expression": expression
        ])
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

    public init(
        id: String,
        routineID: String,
        routineName: String,
        harness: Harness,
        start: Date,
        end: Date? = nil,
        count: Int = 1,
        scheduleSummary: String? = nil,
        kind: Kind
    ) {
        self.id = id
        self.routineID = routineID
        self.routineName = routineName
        self.harness = harness
        self.start = start
        self.end = end
        self.count = count
        self.scheduleSummary = scheduleSummary
        self.kind = kind
    }

    public var isFrequent: Bool { count > 1 }

    public var isPaused: Bool {
        if case .scheduled(let paused) = kind { return paused }
        return false
    }

    public var record: RunRecord? {
        if case .record(let rec) = kind { return rec }
        return nil
    }
}

extension CalendarEntry: Decodable {
    private enum CodingKeys: String, CodingKey {
        case id, routineID, routineName, harness, start, end, count, scheduleSummary, kind
    }

    private struct RawKind: Decodable {
        var type: String
        var record: RunRecord?
        var paused: Bool?
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        routineID = try container.decode(String.self, forKey: .routineID)
        routineName = try container.decode(String.self, forKey: .routineName)
        harness = try container.decode(Harness.self, forKey: .harness)
        start = try container.decode(Date.self, forKey: .start)
        end = try container.decodeIfPresent(Date.self, forKey: .end)
        count = try container.decode(Int.self, forKey: .count)
        scheduleSummary = try container.decodeIfPresent(String.self, forKey: .scheduleSummary)
        let rawKind = try container.decode(RawKind.self, forKey: .kind)
        if rawKind.type == "record", let rec = rawKind.record {
            kind = .record(rec)
        } else {
            kind = .scheduled(paused: rawKind.paused ?? false)
        }
    }
}

public struct CalendarDay: Identifiable, Equatable, Sendable, Decodable {
    public let id: String
    public let date: Date
    public let isToday: Bool
    public var entries: [CalendarEntry]

    public init(id: String, date: Date, isToday: Bool, entries: [CalendarEntry]) {
        self.id = id
        self.date = date
        self.isToday = isToday
        self.entries = entries
    }

    public var recordedCount: Int {
        entries.reduce(0) { $0 + ($1.record != nil ? $1.count : 0) }
    }

    public var scheduledCount: Int {
        entries.reduce(0) { $0 + ($1.record == nil ? $1.count : 0) }
    }
}

public enum ScheduleCalendar {
    private struct IntervalPayload: Decodable {
        var start: Date
        var end: Date
    }

    public static func agendaInterval(
        startingAt anchor: Date,
        days: Int = 7,
        calendar: Calendar = .current
    ) -> DateInterval {
        if let res = try? FFIBridge.callCore(IntervalPayload.self, "calendar.agendaInterval", params: [
            "anchor": FFIDateCoding.format(anchor),
            "days": days,
            "timeZone": calendar.timeZone.identifier
        ]), res.end >= res.start {
            return DateInterval(start: res.start, end: res.end)
        }
        let start = calendar.startOfDay(for: anchor)
        let clamped = max(1, min(days, 366))
        let end = calendar.date(byAdding: .day, value: clamped, to: start) ?? start
        return DateInterval(start: start, end: end)
    }

    public static func dayIdentifier(for date: Date, calendar: Calendar = .current) -> String {
        if let dayID = try? FFIBridge.callCore(String.self, "calendar.dayIdentifier", params: [
            "date": FFIDateCoding.format(date),
            "timeZone": calendar.timeZone.identifier
        ]) {
            return dayID
        }
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    public struct Query: Sendable {
        public var interval: DateInterval
        public var now: Date
        public var includePaused: Bool
        public var routineID: String?
        public var calendar: Calendar

        public init(
            interval: DateInterval,
            now: Date = .now,
            includePaused: Bool = false,
            routineID: String? = nil,
            calendar: Calendar = .current
        ) {
            self.interval = interval
            self.now = now
            self.includePaused = includePaused
            self.routineID = routineID
            self.calendar = calendar
        }
    }

    public static func days(
        query: Query,
        routines: [Routine],
        records: [RunRecord]
    ) -> [CalendarDay] {
        var params: [String: Any] = [
            "start": FFIDateCoding.format(query.interval.start),
            "end": FFIDateCoding.format(query.interval.end),
            "now": FFIDateCoding.format(query.now),
            "includePaused": query.includePaused,
            "timeZone": query.calendar.timeZone.identifier,
            "routines": FFIJSON.toJSONValue(routines) ?? [],
            "records": FFIJSON.toJSONValue(records) ?? []
        ]
        if let routineID = query.routineID {
            params["routineID"] = routineID
        }
        return (try? FFIBridge.callCore([CalendarDay].self, "calendar.days", params: params)) ?? []
    }
}

public enum SessionRestart {
    public static func hitUsageLimit(in items: [TranscriptItem]) -> Bool {
        guard !items.isEmpty else { return false }
        let suffix = items.lastIndex { $0.kind == .user }.map { Array(items[$0...]) } ?? items
        return (try? FFIBridge.callCore(Bool.self, "sessionRestart.hitUsageLimit", params: [
            "items": FFIJSON.toJSONValue(suffix) ?? []
        ])) ?? false
    }
}
