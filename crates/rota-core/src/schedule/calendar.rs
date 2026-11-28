use std::collections::HashMap;

use jiff::Timestamp;
use jiff::civil::Date;
use jiff::tz::TimeZone;

use crate::model::serde_ext::{parse_iso_timestamp, uppercase_uuid};
use crate::model::{Harness, Routine, RunRecord};
use crate::schedule::CronSchedule;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum CalendarEntryKind {
    Record(Box<RunRecord>),
    Scheduled { paused: bool },
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CalendarEntry {
    pub id: String,
    pub routine_id: String,
    pub routine_name: String,
    pub harness: Harness,
    pub start: Timestamp,
    pub end: Option<Timestamp>,
    pub count: usize,
    pub schedule_summary: Option<String>,
    pub kind: CalendarEntryKind,
}

impl CalendarEntry {
    pub fn is_frequent(&self) -> bool {
        self.count > 1
    }

    pub fn is_paused(&self) -> bool {
        matches!(self.kind, CalendarEntryKind::Scheduled { paused: true })
    }

    pub fn record(&self) -> Option<&RunRecord> {
        match &self.kind {
            CalendarEntryKind::Record(rec) => Some(rec),
            CalendarEntryKind::Scheduled { .. } => None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CalendarDay {
    pub id: String,
    pub date: Timestamp,
    pub is_today: bool,
    pub entries: Vec<CalendarEntry>,
}

impl CalendarDay {
    pub fn recorded_count(&self) -> usize {
        self.entries
            .iter()
            .map(|e| if e.record().is_some() { e.count } else { 0 })
            .sum()
    }

    pub fn scheduled_count(&self) -> usize {
        self.entries
            .iter()
            .map(|e| if e.record().is_none() { e.count } else { 0 })
            .sum()
    }
}

#[derive(Debug, Clone)]
pub struct CalendarQuery {
    pub start: Timestamp,
    pub end: Timestamp,
    pub now: Timestamp,
    pub include_paused: bool,
    pub routine_id: Option<String>,
    pub tz: TimeZone,
}

pub struct ScheduleCalendar;

impl ScheduleCalendar {
    pub const FREQUENT_THRESHOLD: usize = 6;

    pub fn start_of_local_day(ts: Timestamp, tz: &TimeZone) -> Timestamp {
        let z = ts.to_zoned(tz.clone());
        z.start_of_day().map(|sod| sod.timestamp()).unwrap_or_else(|_| ts)
    }

    pub fn start_of_date(day: Date, tz: &TimeZone) -> Timestamp {
        day.at(12, 0, 0, 0)
            .to_zoned(tz.clone())
            .and_then(|noon| noon.start_of_day())
            .map(|sod| sod.timestamp())
            .unwrap_or(Timestamp::UNIX_EPOCH)
    }

    pub fn agenda_interval(anchor: Timestamp, days: usize, tz: &TimeZone) -> (Timestamp, Timestamp) {
        let clamped = days.clamp(1, 366);
        let start_date = anchor.to_zoned(tz.clone()).date();
        let start = Self::start_of_date(start_date, tz);
        let mut end_date = start_date;
        for _ in 0..clamped {
            if let Ok(next) = end_date.tomorrow() {
                end_date = next;
            }
        }
        let end = Self::start_of_date(end_date, tz);
        (start, end)
    }

    pub fn day_identifier(ts: Timestamp, tz: &TimeZone) -> String {
        let d = ts.to_zoned(tz.clone()).date();
        Self::format_date_id(d)
    }

    pub fn format_date_id(d: Date) -> String {
        format!("{:04}-{:02}-{:02}", d.year(), d.month(), d.day())
    }

    /// Parses `"YYYY-MM-DD"` (anchored at local noon, then start of local day) or ISO 8601 with zone.
    pub fn parse_calendar_anchor(text: &str, tz: &TimeZone) -> Option<Timestamp> {
        let trimmed = text.trim();
        let parts: Vec<&str> = trimmed.split('-').collect();
        if parts.len() == 3 && parts[0].len() == 4 && parts[1].len() == 2 && parts[2].len() == 2 {
            let y: i16 = parts[0].parse().ok()?;
            let m: i8 = parts[1].parse().ok()?;
            let d: i8 = parts[2].parse().ok()?;
            let civil = Date::new(y, m, d).ok()?;
            let noon = civil.at(12, 0, 0, 0).to_zoned(tz.clone()).ok()?;
            if noon.year() != y || noon.month() != m || noon.day() != d {
                return None;
            }
            return noon.start_of_day().ok().map(|z| z.timestamp());
        }
        let instant = parse_iso_timestamp(trimmed)?;
        Some(Self::start_of_local_day(instant, tz))
    }

    pub fn days(query: &CalendarQuery, routines: &[Routine], records: &[RunRecord]) -> Vec<CalendarDay> {
        let active_routines: Vec<&Routine> = routines
            .iter()
            .filter(|r| query.routine_id.as_deref().is_none_or(|id| r.id == id))
            .collect();
        let active_records: Vec<&RunRecord> = records
            .iter()
            .filter(|r| query.routine_id.as_deref().is_none_or(|id| r.routine_id == id))
            .collect();
        let routines_by_id: HashMap<&str, &Routine> =
            active_routines.iter().map(|r| (r.id.as_str(), *r)).collect();

        let mut summaries: HashMap<String, String> = HashMap::new();
        let mut entries_by_day: HashMap<String, Vec<CalendarEntry>> = HashMap::new();

        Self::append_records(
            &active_records,
            query,
            &routines_by_id,
            &mut summaries,
            &mut entries_by_day,
        );

        for routine in active_routines {
            if routine.is_schedule_complete() || (!routine.enabled && !query.include_paused) {
                continue;
            }
            let summary = summaries
                .entry(routine.id.clone())
                .or_insert_with(|| routine.schedule_description_in(&query.tz))
                .clone();
            Self::append_projected(routine, &summary, query, &mut entries_by_day);
        }

        Self::build_days(query, &mut entries_by_day)
    }

    fn build_days(
        query: &CalendarQuery,
        entries_by_day: &mut HashMap<String, Vec<CalendarEntry>>,
    ) -> Vec<CalendarDay> {
        let mut out = Vec::new();
        let mut cur_date = query.start.to_zoned(query.tz.clone()).date();
        let today_date = query.now.to_zoned(query.tz.clone()).date();
        loop {
            let day_start = Self::start_of_date(cur_date, &query.tz);
            if day_start >= query.end {
                break;
            }
            let id = Self::format_date_id(cur_date);
            let mut entries = entries_by_day.remove(&id).unwrap_or_default();
            entries.sort_by(Self::entry_cmp);
            out.push(CalendarDay {
                id,
                date: day_start,
                is_today: cur_date == today_date,
                entries,
            });
            let Ok(next) = cur_date.tomorrow() else {
                break;
            };
            cur_date = next;
        }
        out
    }

    fn entry_cmp(lhs: &CalendarEntry, rhs: &CalendarEntry) -> std::cmp::Ordering {
        lhs.start
            .cmp(&rhs.start)
            .then_with(|| rhs.is_frequent().cmp(&lhs.is_frequent()))
            .then_with(|| lhs.routine_name.cmp(&rhs.routine_name))
            .then_with(|| lhs.id.cmp(&rhs.id))
    }

    fn append_records(
        records: &[&RunRecord],
        query: &CalendarQuery,
        routines_by_id: &HashMap<&str, &Routine>,
        summaries: &mut HashMap<String, String>,
        entries_by_day: &mut HashMap<String, Vec<CalendarEntry>>,
    ) {
        let mut groups: HashMap<(String, String), Vec<&RunRecord>> = HashMap::new();
        for &rec in records {
            if rec.started_at >= query.start && rec.started_at < query.end {
                let day_id = Self::day_identifier(rec.started_at, &query.tz);
                groups
                    .entry((day_id, rec.routine_id.clone()))
                    .or_default()
                    .push(rec);
            }
        }
        for ((day_id, routine_id), mut group) in groups {
            let routine = routines_by_id.get(routine_id.as_str()).copied();
            let name = routine.map_or_else(|| routine_id.clone(), |r| r.name.clone());
            let summary = routine.map(|r| {
                summaries
                    .entry(r.id.clone())
                    .or_insert_with(|| r.schedule_description_in(&query.tz))
                    .clone()
            });
            group.sort_by_key(|r| r.started_at);
            let mut quiet_runs = Vec::new();
            let mut quiet_skips = Vec::new();
            let day_entries = entries_by_day.entry(day_id.clone()).or_default();
            for rec in group {
                if rec.is_prominent() {
                    day_entries.push(Self::record_entry(rec, &name, summary.clone()));
                } else if rec.is_skip() {
                    quiet_skips.push(rec);
                } else {
                    quiet_runs.push(rec);
                }
            }
            day_entries.extend(Self::collapse_records(&quiet_runs, &day_id, &name, &summary));
            day_entries.extend(Self::collapse_records(&quiet_skips, &day_id, &name, &summary));
        }
    }

    fn collapse_records(
        group: &[&RunRecord],
        day_id: &str,
        name: &str,
        summary: &Option<String>,
    ) -> Vec<CalendarEntry> {
        if group.len() <= Self::FREQUENT_THRESHOLD {
            return group
                .iter()
                .map(|r| Self::record_entry(r, name, summary.clone()))
                .collect();
        }
        let first = group[0];
        let last = group[group.len() - 1];
        let tag = if last.is_skip() { "skip-burst" } else { "run-burst" };
        vec![CalendarEntry {
            id: format!("{tag}:{}:{day_id}", last.routine_id),
            routine_id: last.routine_id.clone(),
            routine_name: name.to_string(),
            harness: last.harness,
            start: first.started_at,
            end: Some(last.started_at),
            count: group.len(),
            schedule_summary: summary.clone(),
            kind: CalendarEntryKind::Record(Box::new(last.clone())),
        }]
    }

    fn record_entry(record: &RunRecord, name: &str, summary: Option<String>) -> CalendarEntry {
        CalendarEntry {
            id: format!("record:{}", uppercase_uuid(record.id)),
            routine_id: record.routine_id.clone(),
            routine_name: name.to_string(),
            harness: record.harness,
            start: record.started_at,
            end: record.ended_at,
            count: 1,
            schedule_summary: summary,
            kind: CalendarEntryKind::Record(Box::new(record.clone())),
        }
    }

    fn append_projected(
        routine: &Routine,
        summary: &str,
        query: &CalendarQuery,
        entries: &mut HashMap<String, Vec<CalendarEntry>>,
    ) {
        if !routine.repeats {
            let candidate = if routine.enabled {
                routine.next_fire.or(routine.scheduled_at)
            } else {
                routine.scheduled_at
            };
            let Some(fire) = candidate else {
                return;
            };
            let pending_due =
                routine.enabled && routine.next_fire.is_some() && routine.is_within_grace(fire, query.now);
            if (fire > query.now || pending_due) && fire >= query.start && fire < query.end {
                let day_id = Self::day_identifier(fire, &query.tz);
                entries
                    .entry(day_id)
                    .or_default()
                    .push(Self::slot_entry(routine, summary, fire, None, 1, ""));
            }
            return;
        }
        let Ok(cron) = CronSchedule::parse(&routine.schedule) else {
            return;
        };
        let mut remaining = routine.remaining_scheduled_runs();
        if remaining == Some(0) {
            return;
        }
        let earliest = routine.cron_floor(query.now);
        let cron_floor_secs = (earliest.as_second().div_euclid(60) + 1) * 60;
        let cron_floor = Timestamp::from_second(cron_floor_secs).unwrap_or(earliest);
        let mut first_floor = cron_floor;
        if routine.enabled
            && let Some(due) = routine.next_fire
        {
            if routine.is_within_grace(due, query.now) {
                if due >= query.start && due < query.end {
                    let day_id = Self::day_identifier(due, &query.tz);
                    entries
                        .entry(day_id)
                        .or_default()
                        .push(Self::slot_entry(routine, summary, due, None, 1, ""));
                }
                if let Some(left) = remaining {
                    remaining = Some(left - 1);
                    if remaining == Some(0) {
                        return;
                    }
                }
            } else if due > cron_floor {
                first_floor = due;
            }
        }
        if query.end <= first_floor {
            return;
        }
        if let Some(mut left) = remaining
            && query.start > first_floor
        {
            Self::consume_prior_slots(&cron, first_floor, query.start, &mut left, &query.tz);
            remaining = Some(left);
            if left == 0 {
                return;
            }
        }
        let vis_start = first_floor.max(query.start);
        let mut cur_date = vis_start.to_zoned(query.tz.clone()).date();
        for _ in 0..(366 * 5) {
            let day_start = Self::start_of_date(cur_date, &query.tz);
            if day_start >= query.end {
                break;
            }
            let Ok(next_date) = cur_date.tomorrow() else {
                break;
            };
            let next_start = Self::start_of_date(next_date, &query.tz);
            let mut slots = cron.times_on_day(cur_date, vis_start, next_start.min(query.end), &query.tz);
            if let Some(left) = remaining {
                let take = (left.max(0) as usize).min(slots.len());
                slots.truncate(take);
                remaining = Some(left - take as i64);
            }
            if !slots.is_empty() {
                let day_id = Self::format_date_id(cur_date);
                let frequent = slots.len() > 1
                    && (slots.len() > Self::FREQUENT_THRESHOLD
                        || cron.daily_slot_count() > Self::FREQUENT_THRESHOLD);
                let bucket = entries.entry(day_id.clone()).or_default();
                if frequent {
                    let first = slots[0];
                    let last = slots[slots.len() - 1];
                    bucket.push(Self::slot_entry(
                        routine,
                        summary,
                        first,
                        Some(last),
                        slots.len(),
                        &day_id,
                    ));
                } else {
                    for slot in slots {
                        bucket.push(Self::slot_entry(routine, summary, slot, None, 1, ""));
                    }
                }
            }
            if remaining == Some(0) {
                break;
            }
            cur_date = next_date;
        }
    }

    fn consume_prior_slots(
        cron: &CronSchedule,
        win_start: Timestamp,
        win_end: Timestamp,
        remaining: &mut i64,
        tz: &TimeZone,
    ) {
        let mut cur = win_start.to_zoned(tz.clone()).date();
        for _ in 0..(366 * 5) {
            let day_start = Self::start_of_date(cur, tz);
            if day_start >= win_end {
                return;
            }
            let Ok(next_date) = cur.tomorrow() else {
                return;
            };
            let next_start = Self::start_of_date(next_date, tz);
            let hits = if day_start >= win_start
                && next_start <= win_end
                && CronSchedule::is_standard_local_day(cur, tz)
            {
                if cron.matches_day(cur) {
                    cron.daily_slot_count()
                } else {
                    0
                }
            } else {
                cron.times_on_day(cur, win_start, next_start.min(win_end), tz)
                    .len()
            };
            *remaining = (*remaining - hits as i64).max(0);
            if *remaining == 0 {
                return;
            }
            cur = next_date;
        }
    }

    fn slot_entry(
        routine: &Routine,
        summary: &str,
        start: Timestamp,
        end: Option<Timestamp>,
        count: usize,
        day_id: &str,
    ) -> CalendarEntry {
        let id = if count > 1 {
            format!("burst:{}:{day_id}", routine.id)
        } else {
            format!("slot:{}:{}", routine.id, start.as_second())
        };
        CalendarEntry {
            id,
            routine_id: routine.id.clone(),
            routine_name: routine.name.clone(),
            harness: routine.harness,
            start,
            end,
            count,
            schedule_summary: Some(summary.to_string()),
            kind: CalendarEntryKind::Scheduled {
                paused: !routine.enabled,
            },
        }
    }
}
