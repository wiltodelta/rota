use std::collections::BTreeSet;
use std::fmt;

use jiff::Timestamp;
use jiff::civil::Date;
use jiff::tz::TimeZone;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CronError {
    FieldCount(usize),
    InvalidField(String),
}

impl fmt::Display for CronError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::FieldCount(count) => write!(
                f,
                "A schedule has 5 fields (minute hour day month weekday), this one has {count}."
            ),
            Self::InvalidField(field) => write!(f, "\"{field}\" is not a valid schedule field."),
        }
    }
}

impl std::error::Error for CronError {}

/// Five-field Vixie cron expression (`minute hour day-of-month month day-of-week`).
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CronSchedule {
    pub expression: String,
    pub minutes: Vec<u8>,
    pub hours: Vec<u8>,
    pub days_of_month: BTreeSet<u8>,
    pub months: BTreeSet<u8>,
    pub days_of_week: BTreeSet<u8>,
    pub day_of_month_restricted: bool,
    pub day_of_week_restricted: bool,
}

impl CronSchedule {
    pub fn parse(expression: &str) -> Result<Self, CronError> {
        let fields: Vec<&str> = expression.split_whitespace().collect();
        if fields.len() != 5 {
            return Err(CronError::FieldCount(fields.len()));
        }
        let minutes: Vec<u8> = Self::parse_field(fields[0], 0, 59)?.into_iter().collect();
        let hours: Vec<u8> = Self::parse_field(fields[1], 0, 23)?.into_iter().collect();
        let days_of_month = Self::parse_field(fields[2], 1, 31)?;
        let months = Self::parse_field(fields[3], 1, 12)?;
        let mut weekdays = Self::parse_field(fields[4], 0, 7)?;
        if weekdays.remove(&7) {
            weekdays.insert(0);
        }
        Ok(Self {
            expression: fields.join(" "),
            minutes,
            hours,
            days_of_month,
            months,
            days_of_week: weekdays,
            day_of_month_restricted: !fields[2].starts_with('*'),
            day_of_week_restricted: !fields[4].starts_with('*'),
        })
    }

    pub fn daily_slot_count(&self) -> usize {
        self.hours.len() * self.minutes.len()
    }

    /// First fire timestamp strictly after `after` (rounded up to the next minute boundary),
    /// searching up to 5 years in `tz`. Skips nonexistent spring-forward wall minutes.
    pub fn next_date(&self, after: Timestamp, tz: &TimeZone) -> Option<Timestamp> {
        let floor_secs = (after.as_second().div_euclid(60) + 1) * 60;
        let floor = Timestamp::from_second(floor_secs).ok()?;
        let mut day = floor.to_zoned(tz.clone()).date();
        for _ in 0..(366 * 5) {
            if self.matches_day(day)
                && let Some(hit) = self.first_time_on_day(day, floor, tz)
            {
                return Some(hit);
            }
            day = day.tomorrow().ok()?;
        }
        None
    }

    pub fn upcoming(&self, after: Timestamp, count: usize, tz: &TimeZone) -> Vec<Timestamp> {
        let mut out = Vec::with_capacity(count);
        let mut cursor = after;
        while out.len() < count {
            let Some(next) = self.next_date(cursor, tz) else {
                break;
            };
            out.push(next);
            cursor = next;
        }
        out
    }

    /// Every valid wall-clock fire time on `day` within `[floor, ceiling)`.
    pub fn times_on_day(
        &self,
        day: Date,
        floor: Timestamp,
        ceiling: Timestamp,
        tz: &TimeZone,
    ) -> Vec<Timestamp> {
        if floor >= ceiling || !self.matches_day(day) {
            return Vec::new();
        }
        let mut out = Vec::new();
        for &hour in &self.hours {
            for &minute in &self.minutes {
                if let Some(ts) = Self::valid_time(day, hour, minute, tz)
                    && ts >= floor
                    && ts < ceiling
                {
                    out.push(ts);
                }
            }
        }
        out
    }

    pub fn matches_day(&self, day: Date) -> bool {
        let month = day.month() as u8;
        if !self.months.contains(&month) {
            return false;
        }
        let dom = day.day() as u8;
        let dow = day.weekday().to_sunday_zero_offset() as u8;
        let dom_hit = self.days_of_month.contains(&dom);
        let dow_hit = self.days_of_week.contains(&dow);
        if self.day_of_month_restricted && self.day_of_week_restricted {
            dom_hit || dow_hit
        } else {
            dom_hit && dow_hit
        }
    }

    pub fn is_standard_local_day(day: Date, tz: &TimeZone) -> bool {
        let Ok(next_day) = day.tomorrow() else {
            return false;
        };
        let Ok(start) = tz.to_ambiguous_zoned(day.at(0, 0, 0, 0)).unambiguous() else {
            return false;
        };
        let Ok(end) = tz.to_ambiguous_zoned(next_day.at(0, 0, 0, 0)).unambiguous() else {
            return false;
        };
        end.timestamp().as_second() - start.timestamp().as_second() == 86_400
            && start.offset() == end.offset()
    }

    fn first_time_on_day(&self, day: Date, floor: Timestamp, tz: &TimeZone) -> Option<Timestamp> {
        for &hour in &self.hours {
            for &minute in &self.minutes {
                if let Some(ts) = Self::valid_time(day, hour, minute, tz)
                    && ts >= floor
                {
                    return Some(ts);
                }
            }
        }
        None
    }

    fn valid_time(day: Date, hour: u8, minute: u8, tz: &TimeZone) -> Option<Timestamp> {
        let dt = day.at(hour as i8, minute as i8, 0, 0);
        let z = tz.to_ambiguous_zoned(dt).earlier().ok()?;
        (z.datetime() == dt).then(|| z.timestamp())
    }

    fn parse_field(field: &str, min: u8, max: u8) -> Result<BTreeSet<u8>, CronError> {
        let mut values = BTreeSet::new();
        for part in field.split(',') {
            if part.is_empty() {
                return Err(CronError::InvalidField(field.to_string()));
            }
            for v in Self::parse_part(part, min, max, field)? {
                values.insert(v);
            }
        }
        if values.is_empty() {
            return Err(CronError::InvalidField(field.to_string()));
        }
        Ok(values)
    }

    fn parse_part(part: &str, min: u8, max: u8, full_field: &str) -> Result<Vec<u8>, CronError> {
        let err = || CronError::InvalidField(full_field.to_string());
        let pieces: Vec<&str> = part.split('/').collect();
        if pieces.len() > 2 {
            return Err(err());
        }
        let step: u8 = if pieces.len() == 2 {
            let s = pieces[1].parse::<u8>().map_err(|_| err())?;
            if s == 0 {
                return Err(err());
            }
            s
        } else {
            1
        };
        let (low, high) = if pieces[0] == "*" {
            (min, max)
        } else if pieces[0].contains('-') {
            let ends: Vec<&str> = pieces[0].split('-').collect();
            if ends.len() != 2 || ends[0].is_empty() || ends[1].is_empty() {
                return Err(err());
            }
            let l = ends[0].parse::<u8>().map_err(|_| err())?;
            let h = ends[1].parse::<u8>().map_err(|_| err())?;
            if l > h || l < min || h > max {
                return Err(err());
            }
            (l, h)
        } else {
            let l = pieces[0].parse::<u8>().map_err(|_| err())?;
            if l < min || l > max {
                return Err(err());
            }
            let h = if pieces.len() == 2 { max } else { l };
            (l, h)
        };
        let mut out = Vec::new();
        let mut cur = low;
        loop {
            out.push(cur);
            match cur.checked_add(step) {
                Some(next) if next <= high => cur = next,
                _ => break,
            }
        }
        Ok(out)
    }
}
