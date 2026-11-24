use std::collections::HashMap;
use std::path::{Path, PathBuf};

use rota_platform::expand_tilde;
use serde_json::{Map, Value, json};

use crate::control::describe::{
    opt_bool, opt_i64, opt_str, opt_str_list, opt_values_map, require_bool, require_str,
};
use crate::control::{ControlError, ControlMethod};
use crate::model::serde_ext::{parse_iso_timestamp, uppercase_uuid};
use crate::model::{Harness, QuestionAnswer, Routine, RunRecord};
use crate::scheduler::Scheduler;

impl Scheduler {
    pub fn control_methods() -> Vec<&'static str> {
        ControlMethod::ALL.iter().map(|m| m.as_str()).collect()
    }

    pub fn control_request(&self, method: &str, params: Value) -> Result<Value, ControlError> {
        let obj = params.as_object().cloned().unwrap_or_default();
        if method.starts_with("questions.")
            && let Some(res) = self.question_command(method, &obj)?
        {
            return Ok(res);
        }
        let Some(op) = ControlMethod::parse(method) else {
            let known = Self::control_methods().join(", ");
            return Err(ControlError::new(format!(
                "Unknown method {method}. Known: {known}."
            )));
        };
        if let Some(res) = self.routine_command(op, &obj)? {
            return Ok(res);
        }
        if let Some(res) = self.session_command(op, &obj)? {
            return Ok(res);
        }
        if let Some(res) = self.session_state_command(op, &obj)? {
            return Ok(res);
        }
        let known = Self::control_methods().join(", ");
        Err(ControlError::new(format!(
            "Unknown method {method}. Known: {known}."
        )))
    }

    fn routine_command(
        &self,
        method: ControlMethod,
        params: &Map<String, Value>,
    ) -> Result<Option<Value>, ControlError> {
        let out = match method {
            ControlMethod::RoutinesList => {
                let items: Vec<Value> = self.routines().iter().map(|r| self.describe_routine(r)).collect();
                Value::Array(items)
            }
            ControlMethod::RoutinesCalendar => self.calendar_overview(params)?,
            ControlMethod::RoutinesGet => self.describe_routine(&self.existing_routine(params)?),
            ControlMethod::RoutinesCreate => self.describe_routine(&self.control_create(params)?),
            ControlMethod::RoutinesUpdate => self.describe_routine(&self.control_update(params)?),
            ControlMethod::RoutinesSetEnabled => {
                let routine = self.existing_routine(params)?;
                let enabled = require_bool(params, "enabled")?;
                let updated = self
                    .set_enabled(&routine.id, enabled)
                    .map_err(ControlError::new)?;
                self.describe_routine(&updated)
            }
            ControlMethod::RoutinesRun => {
                let routine = self.existing_routine(params)?;
                let rec = self.run_now(&routine.id).map_err(ControlError::new)?;
                self.describe_record(&rec)
            }
            ControlMethod::RoutinesStop => {
                let routine = self.existing_routine(params)?;
                match self.stop_routine(&routine.id).map_err(ControlError::new)? {
                    Some(_) => json!({"stopping": routine.id}),
                    None => {
                        return Err(ControlError::new(format!("{} is not running.", routine.id)));
                    }
                }
            }
            ControlMethod::RoutinesDelete => {
                let routine = self.existing_routine(params)?;
                self.delete_routine(&routine.id).map_err(ControlError::new)?;
                json!({"deleted": routine.id})
            }
            _ => return Ok(None),
        };
        Ok(Some(out))
    }

    fn session_command(
        &self,
        method: ControlMethod,
        params: &Map<String, Value>,
    ) -> Result<Option<Value>, ControlError> {
        let out = match method {
            ControlMethod::SessionsList => {
                let routine = self.existing_routine(params)?;
                let limit = opt_i64(params, "limit")?.unwrap_or(10).max(1) as usize;
                let items: Vec<Value> = self
                    .records_for(&routine.id)
                    .into_iter()
                    .filter(|r| !r.is_skip())
                    .take(limit)
                    .map(|r| self.describe_record(&r))
                    .collect();
                Value::Array(items)
            }
            ControlMethod::SessionsRead => {
                let record = self.resolve_session(params)?;
                let limit_i64 = opt_i64(params, "limit")?.unwrap_or(20_000).max(1);
                let limit = usize::try_from(limit_i64).unwrap_or(usize::MAX);
                let (log, truncated) = record.log_path.as_deref().map_or_else(
                    || (String::new(), false),
                    |p| Self::tail_of_file(Path::new(p), limit),
                );
                let mut desc = self.describe_record(&record);
                if let Some(m) = desc.as_object_mut() {
                    m.insert("log".to_string(), Value::String(log));
                    m.insert("truncated".to_string(), Value::Bool(truncated));
                }
                desc
            }
            ControlMethod::SessionsMessage => {
                let record = self.resolve_session(params)?;
                let text = require_str(params, "text")?;
                let paths = opt_str_list(params, "attachments")?;
                let path_bufs: Vec<PathBuf> = paths.into_iter().map(PathBuf::from).collect();
                let updated = self
                    .send_message(record.id, &text, &path_bufs)
                    .map_err(ControlError::new)?;
                self.describe_record(&updated)
            }
            ControlMethod::Notify => {
                let message = require_str(params, "message")?;
                let title = opt_str(params, "title")?;
                let session = opt_str(params, "session")?;
                let routine_id = opt_str(params, "routine")?;
                let needs_reply = opt_bool(params, "needsReply")?.unwrap_or(false);
                let rec = self
                    .notify_session(
                        &message,
                        title.as_deref(),
                        session.as_deref(),
                        routine_id.as_deref(),
                        needs_reply,
                    )
                    .map_err(ControlError::new)?;
                rec.map_or_else(|| json!({"notified": true}), |r| self.describe_record(&r))
            }
            _ => return Ok(None),
        };
        Ok(Some(out))
    }

    fn session_state_command(
        &self,
        method: ControlMethod,
        params: &Map<String, Value>,
    ) -> Result<Option<Value>, ControlError> {
        let out = match method {
            ControlMethod::SessionsGet => self.describe_record(&self.resolve_session(params)?),
            ControlMethod::SessionsDelete => {
                let _ = require_str(params, "session")?;
                let record = self.resolve_session(params)?;
                self.delete_session(record.id).map_err(ControlError::new)?;
                json!({"deleted": uppercase_uuid(record.id)})
            }
            ControlMethod::SessionsMarkRead => {
                let record = self.resolve_session(params)?;
                let updated = self.mark_read(record.id).map_err(ControlError::new)?;
                self.describe_record(&updated)
            }
            ControlMethod::SessionsMarkUnread => {
                let record = self.resolve_session(params)?;
                let updated = self.mark_unread(record.id).map_err(ControlError::new)?;
                self.describe_record(&updated)
            }
            ControlMethod::SessionsQuestions => {
                let record = self.resolve_session(params)?;
                serde_json::to_value(record.questions.unwrap_or_default())
                    .map_err(|e| ControlError::new(e.to_string()))?
            }
            ControlMethod::SessionsAnswer => {
                let record = self.resolve_session(params)?;
                let qid = require_str(params, "question")?;
                let action = require_str(params, "action")?;
                let values: HashMap<String, Vec<String>> = opt_values_map(params, "values")?;
                let updated = self
                    .answer_question(record.id, &qid, QuestionAnswer::new(action, values))
                    .map_err(ControlError::new)?;
                self.describe_record(&updated)
            }
            ControlMethod::SessionsDismiss => {
                let record = self.resolve_session(params)?;
                let updated = self.dismiss_attention(record.id).map_err(ControlError::new)?;
                self.describe_record(&updated)
            }
            _ => return Ok(None),
        };
        Ok(Some(out))
    }

    pub(crate) fn existing_routine(&self, params: &Map<String, Value>) -> Result<Routine, ControlError> {
        let id = require_str(params, "id")?;
        self.routine(&id)
            .ok_or_else(|| ControlError::new(format!("No routine {id}.")))
    }

    fn control_create(&self, params: &Map<String, Value>) -> Result<Routine, ControlError> {
        let id = require_str(params, "id")?;
        if self.routine(&id).is_some() {
            return Err(ControlError::new(format!(
                "A routine {id} exists; update it instead."
            )));
        }
        let mut routine = Routine::new(id.clone(), id, "", "", Harness::Claude, true, "");
        self.apply_routine_params(params, &mut routine)?;
        if let Some(problem) = routine.problem(true, self.now()) {
            return Err(ControlError::new(problem));
        }
        let saved = self.save_routine(routine).map_err(ControlError::new)?;
        if let Some(notifier) = &self.notifier {
            notifier.routine_added(&saved);
        }
        Ok(saved)
    }

    fn control_update(&self, params: &Map<String, Value>) -> Result<Routine, ControlError> {
        let mut routine = self.existing_routine(params)?;
        let prev_harness = routine.harness;
        self.apply_routine_params(params, &mut routine)?;
        if routine.harness != prev_harness && !params.contains_key("model") && !params.contains_key("effort")
        {
            routine.model = None;
            routine.effort = None;
        }
        if let Some(problem) = routine.problem(false, self.now()) {
            return Err(ControlError::new(problem));
        }
        self.save_routine(routine).map_err(ControlError::new)
    }

    fn apply_routine_params(
        &self,
        params: &Map<String, Value>,
        routine: &mut Routine,
    ) -> Result<(), ControlError> {
        if let Some(name) = opt_str(params, "name")? {
            routine.name = name;
        }
        if let Some(sched) = opt_str(params, "schedule")? {
            routine.schedule = sched;
        }
        if let Some(prompt) = opt_str(params, "prompt")? {
            routine.prompt = prompt;
        }
        Self::apply_schedule_params(params, routine)?;
        let folder = match opt_str(params, "workingDirectory")? {
            Some(wd) => Some(wd),
            None => opt_str(params, "folder")?,
        };
        if let Some(dir) = folder {
            routine.working_directory = expand_tilde(&dir);
        }
        if let Some(h_raw) = opt_str(params, "harness")? {
            let Some(h) = Harness::parse(&h_raw) else {
                let all: Vec<&str> = Harness::ALL.iter().map(|h| h.as_str()).collect();
                return Err(ControlError::new(format!(
                    "Unknown harness {h_raw}. Use one of {all:?}."
                )));
            };
            routine.harness = h;
        }
        if let Some(skill) = opt_str(params, "skill")? {
            routine.prompt = Routine::default_prompt(&skill, &routine.working_directory);
        }
        if params.contains_key("model") {
            routine.model = opt_str(params, "model")?;
        }
        if params.contains_key("effort") {
            routine.effort = opt_str(params, "effort")?;
        }
        if params.contains_key("timeLimitMinutes") {
            routine.time_limit_minutes = opt_i64(params, "timeLimitMinutes")?;
        }
        if let Some(enabled) = opt_bool(params, "enabled")? {
            routine.enabled = enabled;
        }
        Ok(())
    }

    fn apply_schedule_params(params: &Map<String, Value>, routine: &mut Routine) -> Result<(), ControlError> {
        if params.get("schedule").is_some_and(|v| !v.is_null()) {
            if !routine.repeats {
                routine.scheduled_at = None;
            }
            routine.repeats = true;
        }
        if params.contains_key("scheduledAt") {
            routine.scheduled_at = None;
            if let Some(text) = opt_str(params, "scheduledAt")? {
                let Some(ts) = parse_iso_timestamp(&text) else {
                    return Err(ControlError::new(
                        "scheduledAt needs an ISO 8601 date, time and time zone.",
                    ));
                };
                routine.scheduled_at = Some(ts);
                if !params.contains_key("schedule") && !params.contains_key("repeats") {
                    routine.repeats = false;
                }
            }
        }
        if let Some(repeats) = opt_bool(params, "repeats")? {
            routine.repeats = repeats;
        }
        if !routine.repeats {
            routine.run_limit = None;
        }
        if params.contains_key("runLimit") {
            routine.run_limit = opt_i64(params, "runLimit")?;
        }
        Ok(())
    }

    pub(crate) fn resolve_session(&self, params: &Map<String, Value>) -> Result<RunRecord, ControlError> {
        let routine = self.existing_routine(params)?;
        if let Some(sess_id) = opt_str(params, "session")? {
            return self
                .current_record_str(&sess_id, Some(&routine.id))
                .ok_or_else(|| ControlError::new(format!("No session {sess_id} of {}.", routine.id)));
        }
        self.active_record(&routine.id)
            .or_else(|| {
                self.history
                    .records(&routine.id)
                    .into_iter()
                    .find(|r| !r.is_skip())
            })
            .ok_or_else(|| ControlError::new(format!("{} has no sessions.", routine.id)))
    }
}
