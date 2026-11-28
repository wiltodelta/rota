use std::path::PathBuf;
use std::time::{SystemTime, UNIX_EPOCH};

use jiff::Timestamp;
use jiff::civil::date;
use jiff::tz::TimeZone;
use rota_core::{
    CalendarQuery, CronSchedule, Harness, Routine, RunOutcome, RunRecord, RunTrigger, ScheduleCalendar,
    ScheduleText,
};
use uuid::Uuid;

struct TempDir(PathBuf);

impl TempDir {
    fn new() -> Self {
        let dir = std::env::temp_dir().join(format!("rota-test-{}", Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        Self(dir)
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn ts(iso: &str) -> Timestamp {
    iso.parse::<Timestamp>().unwrap()
}

#[test]
fn cron_parses_presets_steps_weekdays_and_rejects_invalid() {
    for preset in ScheduleText::PRESETS {
        assert!(CronSchedule::parse(preset).is_ok(), "{preset}");
    }
    assert!(CronSchedule::parse("0 9 * * 1-5").is_ok());
    assert!(CronSchedule::parse("*/15 8-18 * * 0,7").is_ok());
    assert!(CronSchedule::parse("0 9 * *").is_err());
    assert!(CronSchedule::parse("60 9 * * *").is_err());
    assert!(CronSchedule::parse("0 24 * * *").is_err());
    assert!(CronSchedule::parse("0 9 0 * *").is_err());
    assert!(CronSchedule::parse("0 9 * 13 *").is_err());
    assert!(CronSchedule::parse("*/0 * * * *").is_err());

    assert_eq!(
        ScheduleText::describe("0 9 * * 1-5").as_deref(),
        Some("Weekdays at 9:00 AM")
    );
    assert_eq!(
        ScheduleText::describe("30 7 * * *").as_deref(),
        Some("Every day at 7:30 AM")
    );
    assert_eq!(
        ScheduleText::describe("*/15 * * * *").as_deref(),
        Some("Every 15 minutes")
    );
}

#[test]
fn cron_handles_dst_spring_forward_and_fall_back() {
    let la = TimeZone::get("America/Los_Angeles").unwrap();

    // 2026-03-08: clocks jump from 01:59 PST (-08) to 03:00 PDT (-07). 02:30 local does not exist.
    let spring_cron = CronSchedule::parse("30 2 * * *").unwrap();
    let before_gap = ts("2026-03-08T09:00:00Z"); // 01:00 PST on 2026-03-08
    let next = spring_cron.next_date(before_gap, &la).unwrap();
    let zoned = next.to_zoned(la.clone());
    // Must land on a real 02:30 local time (2026-03-09 02:30 PDT) or valid resolved instant after before_gap.
    assert!(next > before_gap);
    assert_eq!(
        (zoned.month(), zoned.day(), zoned.hour(), zoned.minute()),
        (3, 9, 2, 30)
    );

    // 2026-11-01: clocks repeat 01:00-01:59 (-07 then -08).
    let fall_cron = CronSchedule::parse("30 1 * * *").unwrap();
    let before_repeat = ts("2026-11-01T07:30:00Z"); // 00:30 PDT
    let first_hit = fall_cron.next_date(before_repeat, &la).unwrap();
    assert_eq!(first_hit, ts("2026-11-01T08:30:00Z")); // First 01:30 (-07)

    // Advancing past the first 01:30 must move to tomorrow's 01:30 rather than firing twice on the same day.
    let day_slots = fall_cron.times_on_day(
        date(2026, 11, 1),
        ts("2026-11-01T07:00:00Z"),
        ts("2026-11-02T08:00:00Z"),
        &la,
    );
    assert_eq!(day_slots.len(), 1);
}

#[test]
fn rrule_converts_to_expected_cron() {
    let utc = TimeZone::UTC;
    let anchor = Some(ts("2026-10-12T14:30:00Z")); // Monday 14:30 UTC
    assert_eq!(
        ScheduleText::cron_from_rrule("FREQ=DAILY;BYHOUR=9;BYMINUTE=15", anchor, &utc).as_deref(),
        Some("15 9 * * *")
    );
    assert_eq!(
        ScheduleText::cron_from_rrule("FREQ=WEEKLY;BYDAY=MO,WE,FR", anchor, &utc).as_deref(),
        Some("30 14 * * 1,3,5")
    );
    assert!(ScheduleText::cron_from_rrule("FREQ=YEARLY", anchor, &utc).is_none());
}

#[test]
fn calendar_projects_slots_collapses_bursts_and_honors_run_limits() {
    let tmp = TempDir::new();
    let utc = TimeZone::UTC;
    let now = ts("2026-11-15T08:00:00Z");
    let (start, end) = ScheduleCalendar::agenda_interval(now, 3, &utc);

    let mut daily = Routine::new(
        "daily",
        "Daily Digest",
        tmp.0.to_string_lossy(),
        "0 9 * * *",
        Harness::Codex,
        true,
        "Summarize",
    );
    daily.run_limit = Some(2);
    daily.next_fire = daily.next_scheduled_fire(now, &utc);

    let frequent = Routine::new(
        "frequent",
        "Frequent",
        tmp.0.to_string_lossy(),
        "*/15 * * * *",
        Harness::Shell,
        true,
        "echo tick",
    );

    let paused = Routine::new(
        "paused",
        "Paused Task",
        tmp.0.to_string_lossy(),
        "0 12 * * *",
        Harness::Claude,
        false,
        "Review",
    );

    // Record 8 quiet runs on 2026-11-15 so they collapse into a single burst entry, plus 1 prominent run.
    let mut records = Vec::new();
    for i in 0..8 {
        let s = Timestamp::from_second(ts("2026-11-15T01:00:00Z").as_second() + i * 600).unwrap();
        let mut r = RunRecord::new(
            "frequent",
            RunTrigger::Scheduled,
            Harness::Shell,
            s,
            RunOutcome::Succeeded,
        );
        r.ended_at = Some(s);
        records.push(r);
    }
    let mut attention_rec = RunRecord::new(
        "frequent",
        RunTrigger::Scheduled,
        Harness::Shell,
        ts("2026-11-15T03:00:00Z"),
        RunOutcome::Succeeded,
    );
    attention_rec.ended_at = Some(ts("2026-11-15T03:01:00Z"));
    attention_rec.attention = Some("Check output".to_string());
    let prominent_id = attention_rec.id;
    records.push(attention_rec);

    let query = CalendarQuery {
        start,
        end,
        now,
        include_paused: false,
        routine_id: None,
        tz: utc.clone(),
    };
    let routines = vec![daily, frequent, paused];
    let days = ScheduleCalendar::days(&query, &routines, &records);
    assert_eq!(days.len(), 3);
    assert!(days[0].is_today);

    // Prominent attention run stays individual, while 8 quiet runs collapse into 1 frequent burst.
    assert!(
        days[0]
            .entries
            .iter()
            .any(|e| e.record().map(|r| r.id) == Some(prominent_id) && !e.is_frequent())
    );
    assert!(
        days[0]
            .entries
            .iter()
            .any(|e| e.routine_id == "frequent" && e.record().is_some() && e.count == 8 && e.is_frequent())
    );

    // Paused routine excluded by default, daily limited to 2 projected runs across the 3 days.
    let daily_slots: usize = days
        .iter()
        .flat_map(|d| &d.entries)
        .filter(|e| e.routine_id == "daily" && e.record().is_none())
        .map(|e| e.count)
        .sum();
    assert_eq!(daily_slots, 2);
    assert!(
        !days
            .iter()
            .flat_map(|d| &d.entries)
            .any(|e| e.routine_id == "paused")
    );

    // Including paused routines surfaces projected paused entries.
    let mut with_paused = query;
    with_paused.include_paused = true;
    let days_with_paused = ScheduleCalendar::days(&with_paused, &routines, &records);
    assert!(
        days_with_paused
            .iter()
            .flat_map(|d| &d.entries)
            .any(|e| e.routine_id == "paused" && e.is_paused())
    );

    let _ = SystemTime::now().duration_since(UNIX_EPOCH);
}
