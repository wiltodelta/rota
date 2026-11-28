use rota_platform::expand_tilde;

use crate::model::{Routine, RunOutcome, RunRecord, RunTrigger};
use crate::schedule::ScheduleText;
use crate::scheduler::Scheduler;

impl Scheduler {
    pub fn create_routine(&self, mut routine: Routine) -> Result<Routine, String> {
        if self.routine(&routine.id).is_some() {
            return Err(format!("A routine {} exists; update it instead.", routine.id));
        }
        if !routine.working_directory.is_empty() {
            routine.working_directory = expand_tilde(&routine.working_directory);
        }
        let now = self.now();
        if let Some(problem) = routine.problem(true, now) {
            return Err(problem);
        }
        self.save_routine(routine)
    }

    pub fn update_routine(&self, mut routine: Routine) -> Result<Routine, String> {
        if self.routine(&routine.id).is_none() {
            return Err(format!("No routine {}.", routine.id));
        }
        if !routine.working_directory.is_empty() {
            routine.working_directory = expand_tilde(&routine.working_directory);
        }
        let now = self.now();
        if let Some(problem) = routine.problem(false, now) {
            return Err(problem);
        }
        self.save_routine(routine)
    }

    /// Upserts `routine` into `routines.json`, recomputing `next_fire` and preserving run counts
    /// when scheduling fields are unchanged.
    pub fn save_routine(&self, mut routine: Routine) -> Result<Routine, String> {
        let now = self.now();
        let tz = self.time_zone();
        let mut g = self.state.lock().unwrap();
        if let Some(prev) = g.routines.iter().find(|r| r.id == routine.id) {
            let unchanged = routine.has_same_schedule(prev);
            routine.scheduled_run_count = if unchanged { prev.scheduled_run_count } else { 0 };
            routine.schedule_completed_at = if unchanged {
                prev.schedule_completed_at
            } else {
                None
            };
        }
        if routine.is_schedule_complete() {
            routine.enabled = false;
        }
        routine.next_fire = if routine.enabled {
            routine.next_scheduled_fire(now, &tz)
        } else {
            None
        };
        let mut next = g.routines.clone();
        if let Some(pos) = next.iter().position(|r| r.id == routine.id) {
            next[pos] = routine.clone();
        } else {
            next.push(routine.clone());
        }
        if let Err(err) = self.store.save(&next) {
            let msg = format!("Could not save routines: {err}");
            g.last_error = Some(msg.clone());
            Self::LOG.error(&msg);
            return Err(msg);
        }
        g.routines = next;
        g.cached_sessions = None;
        drop(g);
        self.bump_revision();
        Ok(routine)
    }

    pub fn set_enabled(&self, id: &str, enabled: bool) -> Result<Routine, String> {
        let Some(mut routine) = self.routine(id) else {
            return Err(format!("No routine {id}."));
        };
        if enabled && routine.is_schedule_complete() {
            let msg =
                "This schedule is complete. Edit its date, repetition or run limit to schedule it again."
                    .to_string();
            self.state.lock().unwrap().last_error = Some(msg.clone());
            return Err(msg);
        }
        routine.enabled = enabled;
        if enabled && let Some(problem) = routine.schedule_problem(self.now()) {
            self.state.lock().unwrap().last_error = Some(problem.clone());
            return Err(problem);
        }
        self.save_routine(routine)
    }

    pub fn delete_routine(&self, id: &str) -> Result<(), String> {
        if self.routine(id).is_none() {
            return Err(format!("No routine {id}."));
        }
        if self.has_surviving_session(id) {
            let msg = "Close this routine's surviving native session before deleting it.".to_string();
            self.state.lock().unwrap().last_error = Some(msg.clone());
            return Err(msg);
        }
        let active_records: Vec<RunRecord> = self
            .state
            .lock()
            .unwrap()
            .active
            .values()
            .filter(|r| r.routine_id == id)
            .cloned()
            .collect();
        for rec in &active_records {
            self.cancel_questions(rec);
        }
        let owned_controls = {
            let mut g = self.state.lock().unwrap();
            let next: Vec<Routine> = g.routines.iter().filter(|r| r.id != id).cloned().collect();
            if let Err(err) = self.store.save(&next) {
                let msg = format!("Could not save routines: {err}");
                g.last_error = Some(msg.clone());
                Self::LOG.error(&msg);
                return Err(msg);
            }
            let mut ctrls = Vec::new();
            for rec in &active_records {
                g.launch_ids.remove(&rec.id);
                g.active.remove(&rec.id);
                if let Some(c) = g.controls.remove(&rec.id) {
                    ctrls.push(c);
                }
                g.run_starts.remove(&rec.id);
                g.late_messages.remove(&rec.id);
                g.slept_through.remove(&rec.id);
            }
            g.pending_resumes.retain(|_, rid| rid != id);
            g.pending_reruns.remove(id);
            g.reruns.remove(id);
            g.routines = next;
            g.cached_history.remove(id);
            g.cached_sessions = None;
            ctrls
        };
        for ctrl in owned_controls {
            ctrl.stop();
        }
        self.history.remove_all(id);
        self.bump_revision();
        Ok(())
    }

    pub fn import_routines(&self, routines: Vec<Routine>) -> Result<Vec<Routine>, String> {
        let mut g = self.state.lock().unwrap();
        let mut next = g.routines.clone();
        let mut imported = Vec::with_capacity(routines.len());
        for mut routine in routines {
            let base = routine.id.clone();
            let mut suffix = 2usize;
            while next.iter().any(|r| r.id == routine.id) {
                routine.id = format!("{base}-{suffix}");
                suffix += 1;
            }
            routine.enabled = false;
            routine.next_fire = None;
            next.push(routine.clone());
            imported.push(routine);
        }
        if let Err(err) = self.store.save(&next) {
            let msg = format!("Could not save routines: {err}");
            g.last_error = Some(msg.clone());
            return Err(msg);
        }
        g.routines = next;
        g.cached_sessions = None;
        drop(g);
        self.bump_revision();
        Ok(imported)
    }

    pub fn tick(&self) {
        if !self.is_online() {
            return;
        }
        self.refresh_surviving_sessions();
        self.reconcile_pending();
        let current = self.now();
        let tz = self.time_zone();
        let ids: Vec<String> = self
            .state
            .lock()
            .unwrap()
            .routines
            .iter()
            .map(|r| r.id.clone())
            .collect();
        let mut changed = false;
        for id in ids {
            let action = {
                let mut g = self.state.lock().unwrap();
                let Some(idx) = g.routines.iter().position(|r| r.id == id) else {
                    continue;
                };
                if !g.routines[idx].enabled {
                    continue;
                }
                let Some(due) = g.routines[idx].next_fire else {
                    let nf = g.routines[idx].next_scheduled_fire(current, &tz);
                    g.routines[idx].next_fire = nf;
                    changed = true;
                    continue;
                };
                if due > current {
                    continue;
                }
                let busy = g.active.values().any(|a| a.routine_id == id)
                    || g.surviving_sessions.values().any(|s| s.routine_id == id);
                let lag = current.as_second() - due.as_second();
                if !g.routines[idx].repeats && busy && lag <= Routine::MISSED_RUN_GRACE_SECS {
                    continue;
                }
                g.routines[idx].next_fire = if g.routines[idx].repeats {
                    g.routines[idx].next_scheduled_fire(current, &tz)
                } else {
                    None
                };
                changed = true;
                if lag > Routine::MISSED_RUN_GRACE_SECS && !g.routines[idx].repeats {
                    g.routines[idx].complete_schedule(current);
                }
                let snapshot = g.routines[idx].clone();
                Some((snapshot, due, lag, busy))
            };

            let Some((routine, due, lag, busy)) = action else {
                continue;
            };
            if lag > Routine::MISSED_RUN_GRACE_SECS {
                let formatted = ScheduleText::format_abbreviated_date_time(due, &tz);
                self.record_skipped(&format!("missed the {formatted} slot"), &routine, current, true);
            } else if busy {
                self.record_skipped("the previous run was still going", &routine, current, false);
            } else {
                let trigger = if lag > 120 {
                    RunTrigger::CatchUp
                } else {
                    RunTrigger::Scheduled
                };
                if self.run_routine(&routine, trigger, true).is_err() {
                    let mut g = self.state.lock().unwrap();
                    if let Some(r) = g.routines.iter_mut().find(|r| r.id == routine.id) {
                        r.next_fire = Some(due);
                    }
                }
            }
        }
        if changed {
            let routines_to_save = self.state.lock().unwrap().routines.clone();
            if let Err(err) = self.store.save(&routines_to_save) {
                let msg = format!("Could not save routines: {err}");
                self.state.lock().unwrap().last_error = Some(msg.clone());
                Self::LOG.error(&msg);
            }
            self.bump_revision();
        }
    }

    fn record_skipped(&self, reason: &str, routine: &Routine, at: jiff::Timestamp, notify: bool) {
        let mut record = RunRecord::new(
            routine.id.clone(),
            RunTrigger::Scheduled,
            routine.harness,
            at,
            RunOutcome::Skipped(reason.to_string()),
        );
        record.ended_at = Some(at);
        self.save_record(&record);
        Self::LOG.warning(&format!("{} skipped: {reason}", routine.id));
        if notify && let Some(notifier) = &self.notifier {
            notifier.run_ended(&record, routine, self.completion_notifications());
        }
    }

    pub(crate) fn reserve_scheduled_run(&self, routine: &Routine) -> bool {
        let now = self.now();
        let mut g = self.state.lock().unwrap();
        let Some(index) = g.routines.iter().position(|r| r.id == routine.id) else {
            return routine.repeats && routine.run_limit.is_none();
        };
        if g.routines[index].is_schedule_complete() {
            return false;
        }
        let mut next = g.routines.clone();
        next[index].scheduled_run_count = next[index].scheduled_run_count.saturating_add(1);
        if !next[index].repeats || next[index].is_schedule_complete() {
            next[index].complete_schedule(now);
        }
        if let Err(err) = self.store.save(&next) {
            g.last_error = Some(format!("Could not save routines: {err}"));
            return false;
        }
        g.routines = next;
        g.cached_sessions = None;
        drop(g);
        self.bump_revision();
        true
    }
}
