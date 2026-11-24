use std::collections::HashMap;

use serde_json::{Map, Value, json};

use crate::control::ControlError;
use crate::model::serde_ext::{format_iso_timestamp, uppercase_uuid};
use crate::model::{Routine, RunOutcome, RunRecord};
use crate::schedule::{CalendarDay, CalendarEntry, CalendarEntryKind, CalendarQuery, ScheduleCalendar};
use crate::scheduler::Scheduler;

impl Scheduler {
    pub(crate) fn calendar_overview(&self, params: &Map<String, Value>) -> Result<Value, ControlError> {
        let routine_id = opt_str(params, "id")?;
        let target_routines = if let Some(ref rid) = routine_id {
            let found = self
                .routine(rid)
                .ok_or_else(|| ControlError::new(format!("No routine {rid}.")))?;
            vec![found]
        } else {
            self.routines()
        };
        let day_count = opt_i64(params, "days")?.unwrap_or(7);
        if !(1..=366).contains(&day_count) {
            return Err(ControlError::new("days must be between 1 and 366."));
        }
        let include_paused = opt_bool(params, "includePaused")?.unwrap_or(false);
        let current = self.now();
        let tz = self.time_zone();
        let start = if let Some(raw_from) = opt_str(params, "from")? {
            ScheduleCalendar::parse_calendar_anchor(&raw_from, &tz).ok_or_else(|| {
                ControlError::new("from needs YYYY-MM-DD or an ISO 8601 date and time with a zone.")
            })?
        } else {
            ScheduleCalendar::start_of_local_day(current, &tz)
        };
        let (win_start, win_end) = ScheduleCalendar::agenda_interval(start, day_count as usize, &tz);
        let query = CalendarQuery {
            start: win_start,
            end: win_end,
            now: current,
            include_paused,
            routine_id,
            tz: tz.clone(),
        };
        let target_records: Vec<RunRecord> = target_routines
            .iter()
            .flat_map(|r| {
                self.records_for(&r.id)
                    .into_iter()
                    .filter(|rec| rec.started_at >= win_start && rec.started_at < win_end)
            })
            .collect();
        let days = ScheduleCalendar::days(&query, &target_routines, &target_records);
        let tz_id = tz.iana_name().unwrap_or("UTC");
        Ok(json!({
            "start": format_iso_timestamp(win_start),
            "end": format_iso_timestamp(win_end),
            "days": day_count,
            "timeZone": tz_id,
            "includePaused": include_paused,
            "calendar": days.iter().map(|d| self.describe_calendar_day(d)).collect::<Vec<_>>(),
        }))
    }

    fn describe_calendar_day(&self, day: &CalendarDay) -> Value {
        json!({
            "date": day.id,
            "isToday": day.is_today,
            "entries": day.entries.iter().map(|e| self.describe_calendar_entry(e)).collect::<Vec<_>>(),
        })
    }

    fn describe_calendar_entry(&self, entry: &CalendarEntry) -> Value {
        let mut m = Map::new();
        m.insert("routine".into(), json!(entry.routine_id));
        m.insert("name".into(), json!(entry.routine_name));
        m.insert("harness".into(), json!(entry.harness.as_str()));
        m.insert("startedAt".into(), json!(format_iso_timestamp(entry.start)));
        m.insert("count".into(), json!(entry.count));
        m.insert("frequent".into(), json!(entry.is_frequent()));
        m.insert("paused".into(), json!(entry.is_paused()));
        if let Some(end) = entry.end {
            m.insert("endedAt".into(), json!(format_iso_timestamp(end)));
        }
        if let Some(summary) = &entry.schedule_summary {
            m.insert("scheduleText".into(), json!(summary));
        }
        match &entry.kind {
            CalendarEntryKind::Record(rec) => {
                m.insert(
                    "kind".into(),
                    json!(if rec.is_skip() { "skip" } else { "session" }),
                );
                m.insert(
                    "status".into(),
                    json!(rec.compact_status_title(self.can_message(rec))),
                );
                if !rec.is_skip() {
                    m.insert("session".into(), json!(uppercase_uuid(rec.id)));
                }
                if let Some(attn) = &rec.attention {
                    m.insert("needsReply".into(), json!(attn));
                }
            }
            CalendarEntryKind::Scheduled { paused } => {
                m.insert("kind".into(), json!("scheduled"));
                m.insert(
                    "status".into(),
                    json!(if *paused { "Paused" } else { "Scheduled" }),
                );
            }
        }
        Value::Object(m)
    }

    pub fn describe_routine(&self, routine: &Routine) -> Value {
        let mut val = serde_json::to_value(routine).unwrap_or_else(|_| json!({}));
        let Some(m) = val.as_object_mut() else {
            return val;
        };
        let tz = self.time_zone();
        m.insert("scheduleText".into(), json!(routine.schedule_description_in(&tz)));
        let state = if routine.is_schedule_complete() {
            "completed"
        } else if routine.enabled {
            "scheduled"
        } else {
            "paused"
        };
        m.insert("scheduleState".into(), json!(state));
        if let Some(rem) = routine.remaining_scheduled_runs() {
            m.insert("remainingRuns".into(), json!(rem));
        }
        m.insert("running".into(), json!(self.is_running(&routine.id)));
        if let Some(last) = self.records_for(&routine.id).into_iter().find(|r| !r.is_skip()) {
            m.insert("lastSession".into(), self.describe_record(&last));
        }
        val
    }

    pub fn describe_record(&self, record: &RunRecord) -> Value {
        let active = self.is_session_active(record.id);
        let outcome_str = match &record.outcome {
            RunOutcome::Succeeded => "Succeeded".to_string(),
            other => other.title(),
        };
        let mut m = Map::new();
        m.insert("session".into(), json!(uppercase_uuid(record.id)));
        m.insert("routine".into(), json!(record.routine_id));
        m.insert("harness".into(), json!(record.harness.as_str()));
        m.insert("trigger".into(), json!(record.trigger.as_str()));
        m.insert("startedAt".into(), json!(format_iso_timestamp(record.started_at)));
        m.insert("outcome".into(), json!(outcome_str));
        m.insert("running".into(), json!(active));
        if active && let Some(st) = record.terminal_state {
            m.insert("terminalState".into(), json!(st.as_str()));
        }
        if let Some(ended) = record.ended_at {
            m.insert("endedAt".into(), json!(format_iso_timestamp(ended)));
        }
        if let Some(model) = record.reported_model.as_ref().or(record.model.as_ref()) {
            m.insert("model".into(), json!(model));
        }
        if let Some(effort) = record.reported_effort.as_ref().or(record.effort.as_ref()) {
            m.insert("effort".into(), json!(effort));
        }
        if let Some(exe) = &record.executable_path {
            m.insert("executablePath".into(), json!(exe));
        }
        if let Some(cli_ver) = &record.cli_version {
            m.insert("cliVersion".into(), json!(cli_ver));
        }
        if let Some(srv_ver) = &record.server_version {
            m.insert("serverVersion".into(), json!(srv_ver));
        }
        if let Some(notice) = record.compatibility_notice() {
            m.insert("compatibilityNotice".into(), json!(notice));
        }
        m.insert(
            "needsReconciliation".into(),
            json!(record.needs_reconciliation == Some(true)),
        );
        if let Some(mode) = record.launch_mode {
            m.insert("launchMode".into(), json!(mode.name()));
        }
        m.insert("unread".into(), json!(record.is_unread()));
        m.insert("canMessage".into(), json!(self.accepts_message(record)));
        m.insert("canDelete".into(), json!(self.can_delete(record)));
        if let Ok(qs) = serde_json::to_value(record.questions.as_deref().unwrap_or(&[])) {
            m.insert("questions".into(), qs);
        }
        if let Some(attn) = &record.attention {
            m.insert("needsReply".into(), json!(attn));
        }
        Value::Object(m)
    }
}

pub(crate) fn require_str(params: &Map<String, Value>, key: &str) -> Result<String, ControlError> {
    opt_str(params, key)?.ok_or_else(|| ControlError::new(format!("Missing {key}.")))
}

pub fn opt_str(params: &Map<String, Value>, key: &str) -> Result<Option<String>, ControlError> {
    let Some(raw) = params.get(key) else {
        return Ok(None);
    };
    if raw.is_null() {
        return Ok(None);
    }
    raw.as_str()
        .map(|s| Some(s.to_string()))
        .ok_or_else(|| ControlError::new(format!("{key} should be text.")))
}

pub(crate) fn require_bool(params: &Map<String, Value>, key: &str) -> Result<bool, ControlError> {
    opt_bool(params, key)?.ok_or_else(|| ControlError::new(format!("Missing {key}.")))
}

pub fn opt_bool(params: &Map<String, Value>, key: &str) -> Result<Option<bool>, ControlError> {
    let Some(raw) = params.get(key) else {
        return Ok(None);
    };
    if raw.is_null() {
        return Ok(None);
    }
    raw.as_bool()
        .map(Some)
        .ok_or_else(|| ControlError::new(format!("{key} should be true or false.")))
}

pub fn opt_i64(params: &Map<String, Value>, key: &str) -> Result<Option<i64>, ControlError> {
    let Some(raw) = params.get(key) else {
        return Ok(None);
    };
    if raw.is_null() {
        return Ok(None);
    }
    raw.as_i64()
        .map(Some)
        .ok_or_else(|| ControlError::new(format!("{key} should be a number (an integer in range).")))
}

pub(crate) fn opt_str_list(params: &Map<String, Value>, key: &str) -> Result<Vec<String>, ControlError> {
    let Some(raw) = params.get(key) else {
        return Ok(Vec::new());
    };
    if raw.is_null() {
        return Ok(Vec::new());
    }
    let Some(arr) = raw.as_array() else {
        return Err(ControlError::new(format!("{key} should be an array of strings.")));
    };
    arr.iter()
        .map(|v| {
            v.as_str()
                .map(ToOwned::to_owned)
                .ok_or_else(|| ControlError::new(format!("{key} should be an array of strings.")))
        })
        .collect()
}

pub(crate) fn opt_values_map(
    params: &Map<String, Value>,
    key: &str,
) -> Result<HashMap<String, Vec<String>>, ControlError> {
    let Some(raw) = params.get(key) else {
        return Ok(HashMap::new());
    };
    if raw.is_null() {
        return Ok(HashMap::new());
    }
    serde_json::from_value(raw.clone())
        .map_err(|_| ControlError::new(format!("{key} should map field ids to arrays of strings.")))
}
