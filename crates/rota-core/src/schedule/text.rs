use std::collections::{HashMap, HashSet};

use jiff::Timestamp;
use jiff::tz::TimeZone;

use crate::schedule::CronSchedule;

pub struct ScheduleText;

impl ScheduleText {
    pub const PRESETS: [&'static str; 5] =
        ["0 * * * *", "0 9 * * *", "0 9 * * 1-5", "0 9 * * 1", "0 9 1 * *"];

    const DAY_NAMES: [&'static str; 7] = [
        "Sunday",
        "Monday",
        "Tuesday",
        "Wednesday",
        "Thursday",
        "Friday",
        "Saturday",
    ];

    const MONTH_NAMES: [&'static str; 12] = [
        "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    ];

    /// Plain-language schedule description in US English (`"Every day at 9:00 AM"`).
    pub fn describe(expression: &str) -> Option<String> {
        let cron = CronSchedule::parse(expression).ok()?;
        let fields: Vec<&str> = cron.expression.split(' ').collect();
        if fields.get(3).copied() != Some("*") {
            return None;
        }
        if !cron.day_of_month_restricted
            && !cron.day_of_week_restricted
            && let Some(rep) = Self::repeating(fields[0], fields[1])
        {
            return Some(rep);
        }
        if cron.minutes.len() != 1 || fields[1].contains('*') || cron.hours.len() > 6 {
            return None;
        }
        let minute = cron.minutes[0];
        let time = cron
            .hours
            .iter()
            .map(|&h| Self::format_hm_12h(h, minute))
            .collect::<Vec<_>>()
            .join(", ");
        match (cron.day_of_month_restricted, cron.day_of_week_restricted) {
            (false, false) => Some(format!("Every day at {time}")),
            (false, true) => {
                let days: Vec<u8> = cron.days_of_week.iter().copied().collect();
                Some(format!("{} at {time}", Self::day_list(&days)))
            }
            (true, false) => {
                if cron.days_of_month.len() != 1 {
                    return None;
                }
                let day = cron.days_of_month.iter().next()?;
                Some(format!("Monthly on day {day} at {time}"))
            }
            (true, true) => None,
        }
    }

    fn repeating(minute: &str, hour: &str) -> Option<String> {
        if hour == "*"
            && let Some(step) = Self::step(minute)
        {
            return Some(if step == 1 {
                "Every minute".to_string()
            } else {
                format!("Every {step} minutes")
            });
        }
        let min_val = minute.parse::<u8>().ok()?;
        let step = Self::step(hour)?;
        let past = format!(":{min_val:02}");
        Some(if step == 1 {
            format!("Every hour at {past}")
        } else {
            format!("Every {step} hours at {past}")
        })
    }

    fn step(field: &str) -> Option<u8> {
        if field == "*" {
            Some(1)
        } else {
            field.strip_prefix("*/")?.parse().ok()
        }
    }

    fn day_list(days: &[u8]) -> String {
        if days == [1, 2, 3, 4, 5] {
            "Weekdays".to_string()
        } else if days == [0, 6] {
            "Weekends".to_string()
        } else if days.len() == 1 {
            format!("{}s", Self::DAY_NAMES[days[0] as usize])
        } else {
            days.iter()
                .map(|&d| &Self::DAY_NAMES[d as usize][..3])
                .collect::<Vec<_>>()
                .join(", ")
        }
    }

    pub fn format_hm_12h(hour: u8, minute: u8) -> String {
        let suffix = if hour < 12 { "AM" } else { "PM" };
        let h12 = match hour % 12 {
            0 => 12,
            h => h,
        };
        format!("{h12}:{minute:02} {suffix}")
    }

    pub fn format_short_time(ts: Timestamp, tz: &TimeZone) -> String {
        let z = ts.to_zoned(tz.clone());
        Self::format_hm_12h(z.hour() as u8, z.minute() as u8)
    }

    pub fn format_abbreviated_date_time(ts: Timestamp, tz: &TimeZone) -> String {
        let z = ts.to_zoned(tz.clone());
        let mon = Self::MONTH_NAMES[(z.month() as usize).saturating_sub(1)];
        let time = Self::format_hm_12h(z.hour() as u8, z.minute() as u8);
        format!("{mon} {}, {} at {time}", z.day(), z.year())
    }

    pub fn format_day_header(date_id: &str, tz: &TimeZone) -> String {
        let parts: Vec<i16> = date_id.split('-').filter_map(|p| p.parse().ok()).collect();
        if parts.len() == 3
            && let Ok(d) = jiff::civil::Date::new(parts[0], parts[1] as i8, parts[2] as i8)
            && let Ok(noon) = d.at(12, 0, 0, 0).to_zoned(tz.clone())
        {
            let wd = &Self::DAY_NAMES[noon.weekday().to_sunday_zero_offset() as usize][..3];
            let mon = Self::MONTH_NAMES[(noon.month() as usize).saturating_sub(1)];
            return format!("{wd}, {mon} {}, {}", noon.day(), noon.year());
        }
        date_id.to_string()
    }

    /// Converts RFC 5545 `RRULE` strings (such as Codex automations) into 5-field cron.
    pub fn cron_from_rrule(rule: &str, anchor: Option<Timestamp>, tz: &TimeZone) -> Option<String> {
        let mut parts: HashMap<String, String> = HashMap::new();
        for pair in rule.replace("RRULE:", "").split(';') {
            if pair.is_empty() {
                continue;
            }
            let (k, v) = pair.split_once('=')?;
            parts.insert(k.to_ascii_uppercase(), v.to_ascii_uppercase());
        }
        let supported: HashSet<&str> = ["FREQ", "INTERVAL", "BYMINUTE", "BYHOUR", "BYDAY", "WKST"]
            .into_iter()
            .collect();
        if !parts.keys().all(|k| supported.contains(k.as_str())) {
            return None;
        }
        let freq = parts.get("FREQ")?.as_str();
        let interval: u32 = parts
            .get("INTERVAL")
            .map_or(Some(1), |s| s.parse().ok())
            .filter(|&n| n >= 1)?;
        let zoned = anchor.map(|ts| ts.to_zoned(tz.clone()));
        let anchor_hour = zoned.as_ref().map(|z| z.hour() as u32);
        let anchor_minute = zoned.as_ref().map(|z| z.minute() as u32);
        let anchor_weekday = zoned.as_ref().map(|z| z.weekday().to_sunday_zero_offset() as u32);

        let days = match parts.get("BYDAY") {
            Some(by_day) => Some(Self::cron_weekdays(by_day)?),
            None => None,
        };
        if freq == "MINUTELY" && parts.contains_key("BYMINUTE") {
            return None;
        }
        let minute = if let Some(mins) = parts.get("BYMINUTE") {
            let tokens: Vec<&str> = mins.split(',').collect();
            if tokens.is_empty() || !tokens.iter().all(|t| t.parse::<u8>().is_ok_and(|m| m <= 59)) {
                return None;
            }
            mins.clone()
        } else {
            anchor_minute.unwrap_or(0).to_string()
        };
        let sets_hour = parts.contains_key("BYHOUR");
        let hour = parts
            .get("BYHOUR")
            .cloned()
            .or_else(|| anchor_hour.map(|h| h.to_string()));

        match freq {
            "MINUTELY" => {
                if 60 % interval != 0 || sets_hour || days.is_some() {
                    return None;
                }
                if interval == 1 {
                    return Some("* * * * *".to_string());
                }
                let am = anchor_minute?;
                Some(format!("{} * * * *", Self::phase(am, interval, 60)))
            }
            "HOURLY" => {
                if interval < 24 && 24 % interval == 0 && !sets_hour {
                    let dow = days.as_deref().unwrap_or("*");
                    if interval == 1 {
                        return Some(format!("{minute} * * * {dow}"));
                    }
                    let ah = anchor_hour?;
                    return Some(format!("{minute} {} * * {dow}", Self::phase(ah, interval, 24)));
                }
                let h = hour?;
                if days.is_some() {
                    return None;
                }
                if interval == 24 {
                    return Some(format!("{minute} {h} * * *"));
                }
                if interval == 168 {
                    let aw = anchor_weekday?;
                    return Some(format!("{minute} {h} * * {aw}"));
                }
                None
            }
            "DAILY" => {
                if interval != 1 {
                    return None;
                }
                let h = hour?;
                Some(format!("{minute} {h} * * {}", days.as_deref().unwrap_or("*")))
            }
            "WEEKLY" => {
                if interval != 1 {
                    return None;
                }
                let h = hour?;
                let weekdays = days.or_else(|| anchor_weekday.map(|w| w.to_string()))?;
                Some(format!("{minute} {h} * * {weekdays}"))
            }
            _ => None,
        }
    }

    fn phase(anchor: u32, interval: u32, end: u32) -> String {
        let offset = anchor % interval;
        if offset == 0 {
            format!("*/{interval}")
        } else {
            let mut vals = Vec::new();
            let mut cur = offset;
            while cur < end {
                vals.push(cur.to_string());
                cur += interval;
            }
            vals.join(",")
        }
    }

    pub fn cron_weekdays(by_day: &str) -> Option<String> {
        const CODES: [&str; 7] = ["SU", "MO", "TU", "WE", "TH", "FR", "SA"];
        let mut out = Vec::new();
        for tok in by_day.split(',') {
            let idx = CODES.iter().position(|&c| c == tok)?;
            out.push(idx.to_string());
        }
        (!out.is_empty()).then(|| out.join(","))
    }
}
