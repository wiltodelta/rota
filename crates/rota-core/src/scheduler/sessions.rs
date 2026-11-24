use uuid::Uuid;

use crate::model::{Harness, HarnessMessages, RunOutcome, RunRecord};
use crate::scheduler::Scheduler;

impl Scheduler {
    pub fn records_for(&self, routine_id: &str) -> Vec<RunRecord> {
        {
            let g = self.state.lock().unwrap();
            if let Some(cached) = g.cached_history.get(routine_id) {
                return cached.clone();
            }
        }
        let read_fn = self.history_reader_fn();
        let records = read_fn(&self.history, routine_id);
        let mut g = self.state.lock().unwrap();
        g.cached_history.insert(routine_id.to_string(), records.clone());
        records
    }

    pub fn all_sessions(&self) -> Vec<RunRecord> {
        {
            let g = self.state.lock().unwrap();
            if let Some(cached) = &g.cached_sessions {
                return cached.clone();
            }
        }
        let routine_ids: Vec<String> = self
            .state
            .lock()
            .unwrap()
            .routines
            .iter()
            .map(|r| r.id.clone())
            .collect();
        let mut sessions: Vec<RunRecord> = routine_ids
            .iter()
            .flat_map(|id| self.records_for(id))
            .filter(|r| !r.is_skip())
            .collect();
        sessions.sort_by(|a, b| {
            if a.is_more_recently_active_than(b) {
                std::cmp::Ordering::Less
            } else if b.is_more_recently_active_than(a) {
                std::cmp::Ordering::Greater
            } else {
                std::cmp::Ordering::Equal
            }
        });
        self.state.lock().unwrap().cached_sessions = Some(sessions.clone());
        sessions
    }

    pub fn current_record(&self, session_id: Uuid) -> Option<RunRecord> {
        self.current_record_in(session_id, None)
    }

    pub fn current_record_in(&self, id: Uuid, routine_id: Option<&str>) -> Option<RunRecord> {
        let routine_ids = {
            let g = self.state.lock().unwrap();
            if let Some(rid) = routine_id {
                if let Some(running) = g.active.get(&id)
                    && running.routine_id == rid
                {
                    return Some(running.clone());
                }
                vec![rid.to_string()]
            } else {
                if let Some(running) = g.active.get(&id) {
                    return Some(running.clone());
                }
                g.routines.iter().map(|r| r.id.clone()).collect()
            }
        };
        for rid in routine_ids {
            if let Some(found) = self.history.records(&rid).into_iter().find(|r| r.id == id) {
                return Some(found);
            }
        }
        None
    }

    pub(crate) fn current_record_str(&self, raw: &str, routine_id: Option<&str>) -> Option<RunRecord> {
        let id = Uuid::parse_str(raw).ok()?;
        self.current_record_in(id, routine_id)
    }

    pub fn is_running(&self, routine_id: &str) -> bool {
        self.state
            .lock()
            .unwrap()
            .active
            .values()
            .any(|r| r.routine_id == routine_id)
    }

    pub fn is_session_active(&self, session_id: Uuid) -> bool {
        self.state.lock().unwrap().active.contains_key(&session_id)
    }

    pub fn is_surviving_session(&self, session_id: Uuid) -> bool {
        self.state
            .lock()
            .unwrap()
            .surviving_sessions
            .contains_key(&session_id)
    }

    pub fn has_surviving_session(&self, routine_id: &str) -> bool {
        self.refresh_surviving_sessions();
        self.state
            .lock()
            .unwrap()
            .surviving_sessions
            .values()
            .any(|r| r.routine_id == routine_id)
    }

    pub fn active_record(&self, routine_id: &str) -> Option<RunRecord> {
        let g = self.state.lock().unwrap();
        g.active
            .values()
            .filter(|r| r.routine_id == routine_id)
            .max_by(|a, b| {
                let sa = g.run_starts.get(&a.id).copied().unwrap_or(a.started_at);
                let sb = g.run_starts.get(&b.id).copied().unwrap_or(b.started_at);
                sa.cmp(&sb).then_with(|| a.id.cmp(&b.id))
            })
            .cloned()
    }

    pub fn run_started_at(&self, session_id: Uuid) -> Option<jiff::Timestamp> {
        self.state.lock().unwrap().run_starts.get(&session_id).copied()
    }

    pub fn unread_and_attention_counts(&self) -> (usize, usize) {
        let all = self.all_sessions();
        let unread = all.iter().filter(|r| r.is_unread()).count();
        let attention = all.iter().filter(|r| r.attention.is_some()).count();
        (unread, attention)
    }

    pub(crate) fn has_native_conflict(&self, record: &RunRecord) -> bool {
        let Some(session) = &record.session_id else {
            return false;
        };
        let g = self.state.lock().unwrap();
        let matches = |other: &RunRecord| {
            other.id != record.id
                && other.harness == record.harness
                && other.session_id.as_ref() == Some(session)
        };
        g.active.values().any(matches) || g.surviving_sessions.values().any(matches)
    }

    pub fn can_message(&self, record: &RunRecord) -> bool {
        if record.session_id.is_none() || self.has_native_conflict(record) {
            return false;
        }
        let g = self.state.lock().unwrap();
        if g.opening_terminals.contains(&record.id) || g.surviving_sessions.contains_key(&record.id) {
            return false;
        }
        let running = g.active.contains_key(&record.id);
        if running && g.active.get(&record.id).and_then(|r| r.terminal_state).is_some() {
            return false;
        }
        drop(g);
        let mode = if running {
            record.launch_mode.unwrap_or_else(|| record.harness.launch_mode())
        } else {
            record.harness.launch_mode()
        };
        mode.capabilities().messages != HarnessMessages::Terminal
    }

    pub fn accepts_message(&self, record: &RunRecord) -> bool {
        self.can_message(record) && !record.has_blocking_question()
    }

    pub fn can_configure(&self, record: &RunRecord) -> bool {
        record.harness.is_agent() && !self.is_session_active(record.id) && self.can_message(record)
    }

    pub fn configure_session(
        &self,
        session_id: Uuid,
        model: Option<String>,
        effort: Option<String>,
    ) -> Result<RunRecord, String> {
        let Some(mut stored) = self.current_record(session_id) else {
            return Err(format!("No session {session_id}."));
        };
        if !self.can_configure(&stored) {
            return Err("This session cannot change its model while running.".to_string());
        }
        if stored.model == model && stored.effort == effort {
            return Ok(stored);
        }
        if stored.configurations.is_none() && (stored.reported_model.is_some() || stored.model.is_some()) {
            stored.configurations = Some(vec![stored.reported_mark(0)]);
        }
        stored.model = model;
        stored.effort = effort;
        stored.reported_model = None;
        stored.reported_model_title = None;
        stored.reported_effort = None;
        self.save_record(&stored);
        Ok(stored)
    }

    pub fn can_delete(&self, record: &RunRecord) -> bool {
        if self.is_session_active(record.id) || self.is_surviving_session(record.id) {
            return false;
        }
        let Some(stored) = self
            .records_for(&record.routine_id)
            .into_iter()
            .find(|r| r.id == record.id)
        else {
            return false;
        };
        stored.outcome != RunOutcome::Running && stored.needs_reconciliation != Some(true)
    }

    pub fn delete_session(&self, session_id: Uuid) -> Result<(), String> {
        let Some(stored) = self.current_record(session_id) else {
            return Err("The session is running or is no longer in history.".to_string());
        };
        if stored.outcome == RunOutcome::Running
            || stored.needs_reconciliation == Some(true)
            || self.is_session_active(session_id)
            || self.is_surviving_session(session_id)
            || self.still_running(&stored)
        {
            let msg = "The session is running or is no longer in history.".to_string();
            self.state.lock().unwrap().last_error = Some(msg.clone());
            return Err(msg);
        }
        match self.history.remove(session_id, &stored.routine_id) {
            Ok(true) => {
                let mut g = self.state.lock().unwrap();
                g.pending_resumes.remove(&session_id);
                g.cached_history.remove(&stored.routine_id);
                g.cached_sessions = None;
                drop(g);
                self.bump_revision();
                Ok(())
            }
            Ok(false) => Err("The session is running or is no longer in history.".to_string()),
            Err(err) => {
                let msg = format!("Could not delete the session: {err}");
                self.state.lock().unwrap().last_error = Some(msg.clone());
                Self::LOG.error(&msg);
                Err(msg)
            }
        }
    }

    pub(crate) fn can_start_from(&self, record: &RunRecord) -> bool {
        !record.is_skip()
            && record.outcome != RunOutcome::Running
            && self.routine(&record.routine_id).is_some()
            && !self.is_session_active(record.id)
            && !self.is_surviving_session(record.id)
            && !self.state.lock().unwrap().opening_terminals.contains(&record.id)
            && !self.has_native_conflict(record)
    }

    pub fn can_restart(&self, record: &RunRecord) -> bool {
        record.harness.is_agent() && self.can_start_from(record)
    }

    pub fn can_discuss(&self, record: &RunRecord) -> bool {
        record.harness == Harness::Shell && self.can_start_from(record)
    }

    pub fn discussions_of(&self, shell_session_id: Uuid) -> Vec<RunRecord> {
        let Some(shell) = self.current_record(shell_session_id) else {
            return Vec::new();
        };
        self.records_for(&shell.routine_id)
            .into_iter()
            .filter(|r| r.discussed_session_id == Some(shell_session_id))
            .collect()
    }
}
