use std::path::Path;

use jiff::Timestamp;
use jiff::tz::TimeZone;
use serde::{Deserialize, Deserializer, Serialize};

use crate::model::Harness;
use crate::model::serde_ext::opt_iso_timestamp;
use crate::schedule::{CronSchedule, ScheduleText};

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Routine {
    pub id: String,
    pub name: String,
    pub working_directory: String,
    pub schedule: String,
    #[serde(default, skip_serializing_if = "Option::is_none", with = "opt_iso_timestamp")]
    pub scheduled_at: Option<Timestamp>,
    pub repeats: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub run_limit: Option<i64>,
    pub scheduled_run_count: i64,
    #[serde(default, skip_serializing_if = "Option::is_none", with = "opt_iso_timestamp")]
    pub schedule_completed_at: Option<Timestamp>,
    pub harness: Harness,
    pub enabled: bool,
    pub prompt: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub time_limit_minutes: Option<i64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub effort: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none", with = "opt_iso_timestamp")]
    pub next_fire: Option<Timestamp>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub import_identity: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RawRoutine {
    id: String,
    name: String,
    working_directory: String,
    schedule: String,
    #[serde(default, with = "opt_iso_timestamp")]
    scheduled_at: Option<Timestamp>,
    repeats: Option<bool>,
    run_limit: Option<i64>,
    scheduled_run_count: Option<i64>,
    #[serde(default, with = "opt_iso_timestamp")]
    schedule_completed_at: Option<Timestamp>,
    harness: Harness,
    enabled: bool,
    prompt: String,
    time_limit_minutes: Option<i64>,
    timeout_minutes: Option<i64>,
    model: Option<String>,
    effort: Option<String>,
    #[serde(default, with = "opt_iso_timestamp")]
    next_fire: Option<Timestamp>,
    import_identity: Option<String>,
}

impl<'de> Deserialize<'de> for Routine {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let raw = RawRoutine::deserialize(deserializer)?;
        let scheduled_run_count = raw.scheduled_run_count.unwrap_or(0);
        if scheduled_run_count < 0 {
            return Err(serde::de::Error::custom(
                "Scheduled run count cannot be negative.",
            ));
        }
        let time_limit_minutes = raw
            .time_limit_minutes
            .or_else(|| raw.timeout_minutes.filter(|&legacy| legacy != 60));
        Ok(Self {
            id: raw.id,
            name: raw.name,
            working_directory: raw.working_directory,
            schedule: raw.schedule,
            scheduled_at: raw.scheduled_at,
            repeats: raw.repeats.unwrap_or(true),
            run_limit: raw.run_limit,
            scheduled_run_count,
            schedule_completed_at: raw.schedule_completed_at,
            harness: raw.harness,
            enabled: raw.enabled,
            prompt: raw.prompt,
            time_limit_minutes,
            model: raw.model,
            effort: raw.effort,
            next_fire: raw.next_fire,
            import_identity: raw.import_identity,
        })
    }
}

impl Routine {
    pub const MISSED_RUN_GRACE_SECS: i64 = 7 * 24 * 3600;

    pub fn new(
        id: impl Into<String>,
        name: impl Into<String>,
        working_directory: impl Into<String>,
        schedule: impl Into<String>,
        harness: Harness,
        enabled: bool,
        prompt: impl Into<String>,
    ) -> Self {
        Self {
            id: id.into(),
            name: name.into(),
            working_directory: working_directory.into(),
            schedule: schedule.into(),
            scheduled_at: None,
            repeats: true,
            run_limit: None,
            scheduled_run_count: 0,
            schedule_completed_at: None,
            harness,
            enabled,
            prompt: prompt.into(),
            time_limit_minutes: None,
            model: None,
            effort: None,
            next_fire: None,
            import_identity: None,
        }
    }

    pub fn default_prompt(skill: &str, working_directory: &str) -> String {
        format!(
            "Invoke the `{skill}` skill from this session's working directory, \
`{working_directory}`, and follow it exactly. Its canonical body is \
`.claude/skills/{skill}/SKILL.md` in the repository; read it there."
        )
    }

    pub fn is_valid_id(id: &str) -> bool {
        !id.is_empty()
            && id
                .bytes()
                .all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-' || b == b'_')
    }

    pub fn problem(&self, checking_id: bool, now: Timestamp) -> Option<String> {
        if checking_id && self.id.is_empty() {
            return Some("Give the routine an id, such as weekly-report.".to_string());
        }
        if checking_id && !Self::is_valid_id(&self.id) {
            return Some("An id is lowercase letters, digits, - and _, such as weekly-report.".to_string());
        }
        if self.working_directory.is_empty() {
            return Some("Choose the project folder.".to_string());
        }
        if !Path::new(&self.working_directory).is_dir() {
            return Some(format!(
                "The project folder {} does not exist.",
                self.working_directory
            ));
        }
        if let Some(sched_err) = self.schedule_problem(now) {
            return Some(sched_err);
        }
        if self.prompt.trim().is_empty() {
            return Some(if self.harness.is_agent() {
                "Give a prompt or a skill.".to_string()
            } else {
                "Give the command.".to_string()
            });
        }
        if let Some(limit) = self.time_limit_minutes
            && !(1..=1440).contains(&limit)
        {
            return Some("A time limit is 1 to 1440 minutes, or none.".to_string());
        }
        None
    }

    pub fn is_schedule_complete(&self) -> bool {
        self.schedule_completed_at.is_some()
            || if self.repeats {
                self.run_limit
                    .is_some_and(|limit| self.scheduled_run_count >= limit)
            } else {
                self.scheduled_run_count > 0
            }
    }

    pub fn remaining_scheduled_runs(&self) -> Option<i64> {
        let limit = if self.repeats { self.run_limit? } else { 1 };
        if self.is_schedule_complete() {
            Some(0)
        } else {
            Some((limit - self.scheduled_run_count).max(0))
        }
    }

    pub fn cron_floor(&self, after: Timestamp) -> Timestamp {
        if let Some(at) = self.scheduled_at {
            let before_at = Timestamp::from_second(at.as_second() - 1).unwrap_or(at);
            after.max(before_at)
        } else {
            after
        }
    }

    pub fn is_within_grace(&self, due: Timestamp, now: Timestamp) -> bool {
        due <= now && (now.as_second() - due.as_second()) <= Self::MISSED_RUN_GRACE_SECS
    }

    pub fn schedule_description(&self) -> String {
        self.schedule_description_in(&TimeZone::system())
    }

    pub fn schedule_description_in(&self, tz: &TimeZone) -> String {
        if !self.repeats {
            return match self.scheduled_at {
                Some(at) => format!("Once on {}", ScheduleText::format_abbreviated_date_time(at, tz)),
                None => "Choose a date and time".to_string(),
            };
        }
        let text = ScheduleText::describe(&self.schedule).unwrap_or_else(|| self.schedule.clone());
        match self.run_limit {
            None => text,
            Some(limit) => {
                let noun = if limit == 1 { "run" } else { "runs" };
                format!("{text}. Ends after {limit} scheduled {noun}")
            }
        }
    }

    pub fn next_scheduled_fire(&self, after: Timestamp, tz: &TimeZone) -> Option<Timestamp> {
        if self.is_schedule_complete() {
            return None;
        }
        if !self.repeats {
            return self.scheduled_at;
        }
        let cron = CronSchedule::parse(&self.schedule).ok()?;
        cron.next_date(self.cron_floor(after), tz)
    }

    pub fn schedule_problem(&self, now: Timestamp) -> Option<String> {
        if self.repeats {
            if self.schedule.is_empty() {
                return Some("Choose a one-time date and time or a repeating schedule.".to_string());
            }
            if let Err(err) = CronSchedule::parse(&self.schedule) {
                return Some(format!("The schedule \"{}\": {err}", self.schedule));
            }
        } else {
            if self.run_limit.is_some() {
                return Some(
                    "Run limits apply to repeating schedules. Choose a one-time date instead.".to_string(),
                );
            }
            let Some(scheduled_at) = self.scheduled_at else {
                return Some("Choose a date and time for the one-time run.".to_string());
            };
            if self.enabled && !self.is_schedule_complete() && scheduled_at <= now {
                return Some("Choose a future date and time for the one-time run.".to_string());
            }
        }
        if let Some(limit) = self.run_limit
            && limit < 1
        {
            return Some("A run limit must be a positive integer, or none.".to_string());
        }
        None
    }

    pub fn has_same_schedule(&self, other: &Self) -> bool {
        self.schedule == other.schedule
            && self.scheduled_at == other.scheduled_at
            && self.repeats == other.repeats
            && self.run_limit == other.run_limit
    }

    pub fn complete_schedule(&mut self, at: Timestamp) {
        self.enabled = false;
        self.next_fire = None;
        self.schedule_completed_at = Some(at);
    }
}

/// Shared display order for the sidebar and menu bar panel.
pub struct RoutineOrder;

impl RoutineOrder {
    pub fn by_next_run(routines: &[Routine]) -> Vec<Routine> {
        let mut out = routines.to_vec();
        out.sort_by(|lhs, rhs| {
            let left = if lhs.enabled { lhs.next_fire } else { None };
            let right = if rhs.enabled { rhs.next_fire } else { None };
            match (left, right) {
                (Some(l), Some(r)) => l.cmp(&r),
                (Some(_), None) => std::cmp::Ordering::Less,
                (None, Some(_)) => std::cmp::Ordering::Greater,
                (None, None) => std::cmp::Ordering::Equal,
            }
        });
        out
    }
}
