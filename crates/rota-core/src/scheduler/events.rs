use std::sync::Arc;

use uuid::Uuid;

use crate::model::{QuestionAnswer, RunOutcome, RunRecord, RunTrigger, SessionConfiguration, TerminalState};
use crate::runners::RunEvents;
use crate::scheduler::Scheduler;

impl Scheduler {
    pub const FAILURES_BEFORE_PAUSE: usize = 5;

    pub(crate) fn build_events(&self, record: &RunRecord, launch_id: Uuid) -> RunEvents {
        let run_id = record.id;
        let routine_id = record.routine_id.clone();

        let w_sess = self.self_weak.clone();
        let w_fin = self.self_weak.clone();
        let w_cfg = self.self_weak.clone();
        let rid_cfg = routine_id.clone();
        let w_q = self.self_weak.clone();
        let w_qr = self.self_weak.clone();
        let w_ts = self.self_weak.clone();
        let w_ti = self.self_weak.clone();
        let w_late = self.self_weak.clone();
        let rid_late = routine_id;
        let w_prov = self.self_weak.clone();
        let w_rec = self.self_weak.clone();

        RunEvents {
            session: Arc::new(move |session| {
                if let Some(s) = w_sess.upgrade()
                    && s.is_current_launch(run_id, launch_id)
                {
                    s.attach_session(&session, run_id);
                }
            }),
            finished: Arc::new(move |outcome| {
                if let Some(s) = w_fin.upgrade()
                    && s.is_current_launch(run_id, launch_id)
                {
                    s.finish_run(run_id, outcome);
                }
            }),
            configuration: Arc::new(move |cfg| {
                if let Some(s) = w_cfg.upgrade()
                    && s.is_current_launch(run_id, launch_id)
                {
                    s.update_configuration(cfg, &rid_cfg, run_id);
                }
            }),
            question: Arc::new(move |question, reply| {
                if let Some(s) = w_q.upgrade()
                    && s.is_current_launch(run_id, launch_id)
                {
                    s.receive_question(question, run_id, reply);
                } else {
                    reply(QuestionAnswer::cancel());
                }
            }),
            question_resolved: Arc::new(move |qid| {
                if let Some(s) = w_qr.upgrade()
                    && s.is_current_launch(run_id, launch_id)
                {
                    s.resolve_question(&qid, run_id);
                }
            }),
            terminal_state: Arc::new(move |state| {
                if let Some(s) = w_ts.upgrade()
                    && s.is_current_launch(run_id, launch_id)
                {
                    s.apply_terminal_state(run_id, state);
                }
            }),
            terminal_input: Arc::new(move || {
                if let Some(s) = w_ti.upgrade()
                    && s.is_current_launch(run_id, launch_id)
                {
                    let _ = s.dismiss_attention(run_id);
                }
            }),
            undelivered: Arc::new(move |msg| {
                if let Some(s) = w_late.upgrade() {
                    s.receive_late(&msg, &rid_late, run_id);
                }
            }),
            provenance: Arc::new(move |cli, srv| {
                if let Some(s) = w_prov.upgrade() {
                    s.update_provenance(cli, srv, run_id, launch_id);
                }
            }),
            reconciliation_required: Arc::new(move || {
                if let Some(s) = w_rec.upgrade()
                    && s.is_current_launch(run_id, launch_id)
                {
                    s.mark_reconciliation_required(run_id);
                }
            }),
        }
    }

    fn is_current_launch(&self, run_id: Uuid, launch_id: Uuid) -> bool {
        self.state.lock().unwrap().launch_ids.get(&run_id) == Some(&launch_id)
    }

    pub(crate) fn attach_session(&self, session: &str, run_id: Uuid) {
        let updated = {
            let mut g = self.state.lock().unwrap();
            let Some(rec) = g.active.get_mut(&run_id) else {
                return;
            };
            rec.session_id = Some(session.to_string());
            rec.clone()
        };
        self.save_record(&updated);
    }

    fn apply_terminal_state(&self, run_id: Uuid, state: TerminalState) {
        let now = self.now();
        let updated = {
            let mut g = self.state.lock().unwrap();
            let Some(rec) = g.active.get(&run_id) else {
                return;
            };
            if rec.terminal_state == Some(state) {
                return;
            }
            if state == TerminalState::Working {
                g.run_starts.insert(run_id, now);
            }
            let rec = g.active.get_mut(&run_id).unwrap();
            rec.updated_at = Some(now);
            rec.terminal_state = Some(state);
            rec.clone()
        };
        self.save_record(&updated);
    }

    fn mark_reconciliation_required(&self, run_id: Uuid) {
        let updated = {
            let mut g = self.state.lock().unwrap();
            let Some(rec) = g.active.get_mut(&run_id) else {
                return;
            };
            rec.needs_reconciliation = Some(true);
            rec.clone()
        };
        self.save_record(&updated);
    }

    pub(crate) fn finish_run(&self, run_id: Uuid, outcome: RunOutcome) {
        let initial = {
            let g = self.state.lock().unwrap();
            let Some(rec) = g.active.get(&run_id).cloned() else {
                return;
            };
            rec
        };
        let routine_id = initial.routine_id.clone();
        self.cancel_questions(&initial);

        let now = self.now();
        let mut record = self
            .current_record_in(run_id, Some(&routine_id))
            .unwrap_or(initial);
        record.outcome = outcome.clone();
        record.ended_at = Some(now);

        let (slept, late) = {
            let mut g = self.state.lock().unwrap();
            g.active.remove(&run_id);
            g.launch_ids.remove(&run_id);
            g.controls.remove(&run_id);
            g.run_starts.remove(&run_id);
            let slept = g.slept_through.remove(&run_id);
            let late = g.late_messages.remove(&run_id);
            (slept, late)
        };
        self.save_record(&record);

        if record.needs_reconciliation == Some(true) {
            self.reserve_unverified(&record);
        } else {
            self.recover(&record, slept);
        }
        Self::LOG.info(&format!("{routine_id} ended: {}", outcome.title()));
        if let (Some(notifier), Some(routine)) = (&self.notifier, self.routine(&routine_id)) {
            notifier.run_ended(&record, &routine, self.completion_notifications());
        }
        self.pause_after_repeated_failures(&routine_id);
        if let Some(messages) = late {
            let joined = messages.join("\n\n");
            if !self.continue_session(&record, &joined) {
                Self::LOG.error(&format!(
                    "{routine_id}: a late message could not continue the session"
                ));
            }
        }
    }

    fn receive_late(&self, message: &str, routine_id: &str, run_id: Uuid) {
        {
            let mut g = self.state.lock().unwrap();
            if g.active.contains_key(&run_id) {
                g.late_messages
                    .entry(run_id)
                    .or_default()
                    .push(message.to_string());
                return;
            }
        }
        if let Some(record) = self.current_record_in(run_id, Some(routine_id))
            && record.outcome != RunOutcome::Running
            && !self.continue_session(&record, message)
        {
            Self::LOG.error(&format!(
                "{routine_id}: a late message could not continue the session"
            ));
        }
    }

    fn pause_after_repeated_failures(&self, routine_id: &str) {
        let Some(routine) = self.routine(routine_id) else {
            return;
        };
        if !routine.enabled {
            return;
        }
        let scheduled: Vec<RunRecord> = self
            .history
            .records(routine_id)
            .into_iter()
            .filter(|r| {
                r.trigger != RunTrigger::Manual
                    && r.terminal_state.is_none()
                    && r.outcome != RunOutcome::Running
                    && !r.is_skip()
            })
            .take(Self::FAILURES_BEFORE_PAUSE)
            .collect();
        if scheduled.len() != Self::FAILURES_BEFORE_PAUSE || !scheduled.iter().all(|r| r.outcome.is_failure())
        {
            return;
        }
        let _ = self.set_enabled(routine_id, false);
        Self::LOG.warning(&format!(
            "{routine_id} paused after {} failures",
            Self::FAILURES_BEFORE_PAUSE
        ));
        if let Some(notifier) = &self.notifier {
            notifier.routine_paused(&routine, Self::FAILURES_BEFORE_PAUSE);
        }
    }

    pub(crate) fn update_configuration(
        &self,
        configuration: SessionConfiguration,
        routine_id: &str,
        run_id: Uuid,
    ) {
        let updated = {
            let mut g = self.state.lock().unwrap();
            let Some(record) = g.active.get_mut(&run_id) else {
                return;
            };
            if record.routine_id != routine_id {
                return;
            }
            let prev = record.clone();
            if let Some(model) = configuration.model {
                if record.reported_model.as_deref() != Some(model.as_str()) {
                    record.reported_model_title = None;
                }
                record.reported_model = Some(model);
            }
            if let Some(title) = configuration.model_title {
                record.reported_model_title = Some(title);
            }
            if let Some(effort) = configuration.effort {
                record.reported_effort = Some(effort);
            }
            if let Some(start) = configuration.from_item {
                let mut marks: Vec<_> = record
                    .configurations
                    .clone()
                    .unwrap_or_default()
                    .into_iter()
                    .filter(|m| m.from_item != start)
                    .collect();
                let mark = record.reported_mark(start);
                if marks.last().is_none_or(|last| !last.labels_like(&mark)) {
                    marks.push(mark);
                }
                record.configurations = Some(marks);
            }
            if *record == prev {
                return;
            }
            record.clone()
        };
        self.save_record(&updated);
    }

    fn update_provenance(&self, cli: Option<String>, server: Option<String>, run_id: Uuid, launch_id: Uuid) {
        let Some(mut record) = self.current_record(run_id) else {
            return;
        };
        if record.execution_id != Some(launch_id) {
            return;
        }
        if let Some(c) = cli {
            record.cli_version = Some(c);
        }
        if let Some(s) = server {
            record.server_version = Some(s);
        }
        {
            let mut g = self.state.lock().unwrap();
            if g.active.contains_key(&record.id) {
                g.active.insert(record.id, record.clone());
            }
        }
        self.save_record(&record);
    }
}
