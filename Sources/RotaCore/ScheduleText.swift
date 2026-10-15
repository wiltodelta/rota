import Foundation

/// Plain-language schedules: "Every day at 10:00 AM" for `0 10 * * *`, and
/// cron from the RFC 5545 rules Codex automations store.
public enum ScheduleText {
    private static let dayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

    /// Common schedules the routine form offers, each with a description.
    public static let presets = ["0 * * * *", "0 9 * * *", "0 9 * * 1-5", "0 9 * * 1", "0 9 1 * *"]

    /// The common shapes in words; nil for anything else, which reads better as cron.
    public static func describe(_ expression: String, locale: Locale = .current) -> String? {
        guard let cron = try? CronSchedule(expression) else { return nil }
        let fields = cron.expression.split(separator: " ").map(String.init)
        guard fields[3] == "*" else { return nil }
        if !cron.dayOfMonthRestricted, !cron.dayOfWeekRestricted,
           let repeating = repeating(minute: fields[0], hour: fields[1]) {
            return repeating
        }
        // One minute past one hour or a short list of them: "at 10:37 AM, 2:37 PM".
        guard cron.minutes.count == 1, let minute = cron.minutes.first, !fields[1].contains("*"),
              cron.hours.count <= 6 else { return nil }
        let time = cron.hours.map { Self.time(hour: $0, minute: minute, locale: locale) }.joined(separator: ", ")
        switch (cron.dayOfMonthRestricted, cron.dayOfWeekRestricted) {
        case (false, false): return "Every day at \(time)"
        case (false, true): return "\(dayList(cron.daysOfWeek.sorted())) at \(time)"
        case (true, false):
            guard cron.daysOfMonth.count == 1, let day = cron.daysOfMonth.first else { return nil }
            return "Monthly on day \(day) at \(time)"
        case (true, true): return nil
        }
    }

    /// Every n minutes, or every n hours at a minute.
    static func repeating(minute: String, hour: String) -> String? {
        if hour == "*", let step = step(minute) {
            return step == 1 ? "Every minute" : "Every \(step) minutes"
        }
        guard let minuteValue = Int(minute), let step = step(hour) else { return nil }
        let past = ":" + String(format: "%02d", minuteValue)
        return step == 1 ? "Every hour at \(past)" : "Every \(step) hours at \(past)"
    }

    static func step(_ field: String) -> Int? {
        field == "*" ? 1 : (field.hasPrefix("*/") ? Int(field.dropFirst(2)) : nil)
    }

    static func dayList(_ days: [Int]) -> String {
        switch days {
        case [1, 2, 3, 4, 5]: return "Weekdays"
        case [0, 6]: return "Weekends"
        case _ where days.count == 1: return dayNames[days[0]] + "s"
        default: return days.map { String(dayNames[$0].prefix(3)) }.joined(separator: ", ")
        }
    }

    static func time(hour: Int, minute: Int, locale: Locale) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let date = calendar.date(from: DateComponents(year: 2026, month: 1, day: 1, hour: hour, minute: minute))
            ?? Date()
        var style = Date.FormatStyle(date: .omitted, time: .shortened, locale: locale)
        style.timeZone = calendar.timeZone
        return date.formatted(style)
    }

    /// Cron for the RRULE shapes a schedule picker writes; nil for the rest.
    /// `anchor` supplies the hour, minute and weekday a rule leaves out, as an
    /// interval rule like `FREQ=HOURLY;INTERVAL=24` takes them from its start.
    public static func cron(fromRRule rule: String, anchor: Date?, calendar: Calendar = .current) -> String? {
        guard let rule = RRule(rule, anchor: anchor, calendar: calendar) else { return nil }
        switch rule.frequency {
        case "MINUTELY": return rule.minutelyCron
        case "HOURLY": return rule.hourlyCron
        case "DAILY", "WEEKLY": return rule.dailyOrWeeklyCron
        default: return nil
        }
    }

    /// The parts of an RRULE cron can express, with the anchor's fill-ins.
    struct RRule {
        var frequency: String
        var interval: Int
        var minute: Int
        /// BYHOUR as written, else the anchor's hour.
        var hour: String?
        var setsHour: Bool
        var setsMinute: Bool
        var anchorMinute: Int?
        var anchorHour: Int?
        /// BYDAY as cron weekdays.
        var days: String?
        var anchorWeekday: Int?

        init?(_ text: String, anchor: Date?, calendar: Calendar) {
            var parts: [String: String] = [:]
            for pair in text.replacingOccurrences(of: "RRULE:", with: "").split(separator: ";") {
                let keyValue = pair.split(separator: "=", maxSplits: 1).map(String.init)
                guard keyValue.count == 2 else { return nil }
                let key = keyValue[0].uppercased()
                guard parts[key] == nil else { return nil }
                parts[key] = keyValue[1].uppercased()
            }
            let supported: Set<String> = ["FREQ", "INTERVAL", "BYMINUTE", "BYHOUR", "BYDAY", "WKST"]
            guard let frequency = parts["FREQ"], Set(parts.keys).isSubset(of: supported),
                  let interval = Int(parts["INTERVAL"] ?? "1"), interval >= 1 else { return nil }
            let filled = anchor.map { calendar.dateComponents([.hour, .minute, .weekday], from: $0) }
            if let minute = parts["BYMINUTE"], Int(minute).map({ (0...59).contains($0) }) != true { return nil }
            if let hour = parts["BYHOUR"] {
                let values = hour.split(separator: ",", omittingEmptySubsequences: false)
                guard values.allSatisfy({ Int($0).map { (0...23).contains($0) } == true }) else { return nil }
            }
            if let byDay = parts["BYDAY"] {
                guard let converted = ScheduleText.cronWeekdays(byDay) else { return nil }
                days = converted
            }
            self.frequency = frequency
            self.interval = interval
            minute = parts["BYMINUTE"].flatMap(Int.init) ?? filled?.minute ?? 0
            hour = parts["BYHOUR"] ?? filled?.hour.map(String.init)
            setsHour = parts["BYHOUR"] != nil
            setsMinute = parts["BYMINUTE"] != nil
            anchorMinute = filled?.minute
            anchorHour = filled?.hour
            anchorWeekday = filled?.weekday.map { $0 - 1 }
        }

        var minutelyCron: String? {
            guard 60 % interval == 0, !setsHour, !setsMinute, days == nil else { return nil }
            if interval == 1 { return "* * * * *" }
            guard let anchorMinute else { return nil }
            let offset = anchorMinute % interval
            return "\(offset == 0 ? "*/\(interval)" : "\(offset)-59/\(interval)") * * * *"
        }

        var hourlyCron: String? {
            if interval < 24, 24 % interval == 0, !setsHour {
                if interval == 1 { return "\(minute) * * * \(days ?? "*")" }
                guard let anchorHour else { return nil }
                let offset = anchorHour % interval
                let hours = offset == 0 ? "*/\(interval)" : "\(offset)-23/\(interval)"
                return "\(minute) \(hours) * * \(days ?? "*")"
            }
            guard let hour, days == nil else { return nil }
            if interval == 24 { return "\(minute) \(hour) * * *" }
            guard interval == 168, let anchorWeekday else { return nil }
            return "\(minute) \(hour) * * \(anchorWeekday)"
        }

        var dailyOrWeeklyCron: String? {
            guard interval == 1, let hour else { return nil }
            if frequency == "DAILY" { return "\(minute) \(hour) * * \(days ?? "*")" }
            guard let weekdays = days ?? anchorWeekday.map(String.init) else { return nil }
            return "\(minute) \(hour) * * \(weekdays)"
        }
    }

    /// `MO,WE,FR` as `1,3,5`.
    static func cronWeekdays(_ byDay: String) -> String? {
        let codes = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"]
        let indexes = byDay.split(separator: ",", omittingEmptySubsequences: false)
            .map { codes.firstIndex(of: String($0)) }
        guard !indexes.isEmpty, !indexes.contains(nil) else { return nil }
        return indexes.compactMap { $0.map(String.init) }.joined(separator: ",")
    }
}
