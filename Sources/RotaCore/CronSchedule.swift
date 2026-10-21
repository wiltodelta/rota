import Foundation

public enum CronError: Error, Equatable, LocalizedError {
    case fieldCount(Int)
    case invalidField(String)

    public var errorDescription: String? {
        switch self {
        case .fieldCount(let count):
            return "A schedule has 5 fields (minute hour day month weekday), this one has \(count)."
        case .invalidField(let field):
            return "\"\(field)\" is not a valid schedule field."
        }
    }
}

/// A five-field cron expression, the format Claude Desktop stores routines in.
///
/// Supports `*`, numbers, ranges `a-b`, steps `*/n` and `a-b/n`, and lists.
/// Weekday 0 and 7 are both Sunday. As in Vixie cron, when both day of month
/// and day of week are restricted, a day matching either one fires.
public struct CronSchedule: Equatable, Sendable {
    public let expression: String
    let minutes: [Int]
    let hours: [Int]
    let daysOfMonth: Set<Int>
    let months: Set<Int>
    let daysOfWeek: Set<Int>
    let dayOfMonthRestricted: Bool
    let dayOfWeekRestricted: Bool

    public init(_ expression: String) throws {
        let fields = expression.split(whereSeparator: \.isWhitespace).map(String.init)
        guard fields.count == 5 else { throw CronError.fieldCount(fields.count) }
        minutes = try Self.parse(fields[0], range: 0...59).sorted()
        hours = try Self.parse(fields[1], range: 0...23).sorted()
        daysOfMonth = try Self.parse(fields[2], range: 1...31)
        months = try Self.parse(fields[3], range: 1...12)
        var weekdays = try Self.parse(fields[4], range: 0...7)
        if weekdays.remove(7) != nil { weekdays.insert(0) }
        daysOfWeek = weekdays
        dayOfMonthRestricted = !fields[2].hasPrefix("*")
        dayOfWeekRestricted = !fields[4].hasPrefix("*")
        self.expression = fields.joined(separator: " ")
    }

    /// The first fire time strictly after `date`, or nil if none falls within
    /// five years (an impossible date such as February 30).
    public func next(after date: Date, calendar: Calendar = .current) -> Date? {
        guard let minute = calendar.dateInterval(of: .minute, for: date)?.end else { return nil }
        var day = calendar.startOfDay(for: minute)
        for _ in 0..<(366 * 5) {
            if matches(day: day, calendar: calendar),
               let time = firstTime(on: day, notBefore: minute, calendar: calendar) {
                return time
            }
            guard let following = calendar.date(byAdding: .day, value: 1, to: day) else { return nil }
            day = following
        }
        return nil
    }

    /// The next `count` fire times after `date`.
    public func upcoming(after date: Date, count: Int, calendar: Calendar = .current) -> [Date] {
        var result: [Date] = []
        var cursor = date
        while result.count < count, let time = next(after: cursor, calendar: calendar) {
            result.append(time)
            cursor = time
        }
        return result
    }

    func matches(day: Date, calendar: Calendar) -> Bool {
        let parts = calendar.dateComponents([.month, .day, .weekday], from: day)
        guard let month = parts.month, let dayOfMonth = parts.day, let weekday = parts.weekday,
              months.contains(month) else { return false }
        let domHit = daysOfMonth.contains(dayOfMonth)
        let dowHit = daysOfWeek.contains(weekday - 1)
        if dayOfMonthRestricted && dayOfWeekRestricted { return domHit || dowHit }
        return domHit && dowHit
    }

    private func firstTime(on day: Date, notBefore floor: Date, calendar: Calendar) -> Date? {
        for hour in hours {
            for minute in minutes {
                guard let time = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day),
                      time >= floor else { continue }
                // A wall-clock time skipped by a DST change resolves to another hour; skip it.
                let parts = calendar.dateComponents([.hour, .minute], from: time)
                if parts.hour == hour && parts.minute == minute { return time }
            }
        }
        return nil
    }

    static func parse(_ field: String, range: ClosedRange<Int>) throws -> Set<Int> {
        var values = Set<Int>()
        for part in field.split(separator: ",", omittingEmptySubsequences: false) {
            values.formUnion(try parsePart(String(part), range: range, field: field))
        }
        return values
    }

    private static func parsePart(_ part: String, range: ClosedRange<Int>, field: String) throws -> [Int] {
        let pieces = part.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard pieces.count <= 2 else { throw CronError.invalidField(field) }
        var step = 1
        if pieces.count == 2 {
            guard let value = Int(pieces[1]), value > 0 else { throw CronError.invalidField(field) }
            step = value
        }
        let bounds: ClosedRange<Int>
        if pieces[0] == "*" {
            bounds = range
        } else {
            let ends = pieces[0].split(separator: "-", omittingEmptySubsequences: false)
            let expected = pieces[0].contains("-") ? 2 : 1
            guard ends.count == expected, let first = ends.first, let last = ends.last,
                  let low = Int(first), let high = Int(last), low <= high,
                  range.contains(low), range.contains(high) else { throw CronError.invalidField(field) }
            // "5/15" means "from 5 to the end, every 15", as in Vixie cron.
            bounds = low...(expected == 1 && pieces.count == 2 ? range.upperBound : high)
        }
        return Array(stride(from: bounds.lowerBound, through: bounds.upperBound, by: step))
    }
}
