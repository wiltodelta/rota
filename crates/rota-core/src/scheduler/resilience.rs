use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::Ordering;
use std::time::Duration;

use jiff::Timestamp;
use rota_platform::{OwnedProcess, PowerEvent, probe_http_reachable};
use uuid::Uuid;

use crate::model::{Harness, LaunchMode, RunOutcome, RunRecord, RunTrigger};
use crate::runners::{ClaudeInteractiveRun, LaunchSpec, is_executable_file};
use crate::scheduler::Scheduler;
use crate::storage::RunLease;

pub type ServiceProbeFn = Arc<dyn Fn(Harness, Box<dyn FnOnce(bool) + Send>) + Send + Sync>;

/// Recognizes network/transport error strings emitted by Claude, Codex, Grok, and Antigravity CLIs.
pub struct NetworkFailure;

impl NetworkFailure {
    const PHRASES: [&'static str; 24] = [
        "connection error",
        "econnreset",
        "econnrefused",
        "etimedout",
        "enotfound",
        "eai_again",
        "getaddrinfo",
        "network is unreachable",
        "network connection was lost",
        "could not resolve host",
        "stream disconnected",
        "error sending request",
        "fetch failed",
        "socket hang up",
        "appears to be offline",
        "connection reset",
        "dns error",
        "failed to connect",
        "unable to connect",
        "read: operation timed out",
        "no route to host",
        "dial tcp: lookup",
        "went to sleep mid-response",
        "request failed: post",
    ];

    pub fn matches(text: &str) -> bool {
        let lowered = text.to_ascii_lowercase();
        Self::PHRASES.iter().any(|p| lowered.contains(p)) || lowered.contains("eligibility check failed")
    }
}

/// Reachability check for each agent provider's API host.
pub struct ServiceProbe;

impl ServiceProbe {
    pub fn host(harness: Harness) -> Option<&'static str> {
        match harness {
            Harness::Claude => Some("https://api.anthropic.com"),
            Harness::Codex => Some("https://api.openai.com"),
            Harness::Grok => Some("https://api.x.ai"),
            Harness::Antigravity | Harness::Shell => None,
        }
    }

    pub fn check(harness: Harness, done: Box<dyn FnOnce(bool) + Send>) {
        let Some(url) = Self::host(harness) else {
            done(true);
            return;
        };
        std::thread::spawn(move || {
            let reachable = probe_http_reachable(url, 10);
            done(reachable);
        });
    }
}

impl Scheduler {
    pub const RESUME_LIMIT: usize = 2;
    pub const RETRY_DELAY_SECS: i64 = 60;
    pub const RESUME_MESSAGE: &'static str = "Continue";

    pub fn system_will_sleep(&self) {
        let mut g = self.state.lock().unwrap();
        let active_ids: Vec<Uuid> = g.active.keys().copied().collect();
        g.slept_through.extend(active_ids);
    }

    pub fn system_did_wake(&self) {
        if self.is_online() {
            self.tick();
            self.resume_pending();
        }
    }

    pub fn network_became_available(&self) {
        self.online.store(true, Ordering::Release);
        self.tick();
        self.resume_pending();
    }

    pub fn handle_power_event(&self, event: PowerEvent) {
        match event {
            PowerEvent::WillSleep => self.system_will_sleep(),
            PowerEvent::DidWake => self.system_did_wake(),
            PowerEvent::NetworkChanged(true) => self.network_became_available(),
            PowerEvent::NetworkChanged(false) => {
                self.online.store(false, Ordering::Release);
            }
            PowerEvent::WillPowerOff => self.stop_all(),
        }
    }

    pub fn recover_orphans(&self) {
        let routine_ids: Vec<String> = self
            .state
            .lock()
            .unwrap()
            .routines
            .iter()
            .map(|r| r.id.clone())
            .collect();
        let now = self.now();
        let closed = self.history.close_orphans(&routine_ids, now);
        for record in closed {
            if self.still_running(&record) {
                if self.adopt_surviving(&record) {
                    continue;
                }
                self.state
                    .lock()
                    .unwrap()
                    .surviving_sessions
                    .insert(record.id, record);
            } else if record.session_id.is_some()
                || record
                    .log_path
                    .as_deref()
                    .is_some_and(|p| RunLease::read(Path::new(p)).is_some())
            {
                self.reconcile_native(&record);
            }
        }
        let home = rota_platform::home_dir();
        self.restore_antigravity_questions(&home);
        self.invalidate_caches_and_bump();
    }

    pub fn resumable(&self, record: &RunRecord) -> bool {
        record.terminal_state.is_none()
            && record.harness.is_agent()
            && record.session_id.is_some()
            && record.resumes.unwrap_or(0) < Self::RESUME_LIMIT
            && matches!(
                record.outcome,
                RunOutcome::Interrupted | RunOutcome::Failed { .. }
            )
    }

    pub(crate) fn recover(&self, record: &RunRecord, slept_through: bool) {
        if record.terminal_state.is_some() {
            return;
        }
        if record.session_id.is_some() {
            self.state.lock().unwrap().reruns.remove(&record.routine_id);
        }
        let failed = matches!(
            record.outcome,
            RunOutcome::Interrupted | RunOutcome::Failed { .. }
        );
        if !failed || self.stopped_by_operator(record) {
            return;
        }
        if !(slept_through || !self.is_online() || self.ended_on_network_error(record)) {
            return;
        }
        if self.resumable(record) {
            self.state
                .lock()
                .unwrap()
                .pending_resumes
                .insert(record.id, record.routine_id.clone());
        } else if record.harness.is_agent() && record.session_id.is_none() {
            let mut g = self.state.lock().unwrap();
            if g.reruns.get(&record.routine_id).copied().unwrap_or(0) < Self::RESUME_LIMIT {
                g.pending_reruns.insert(record.routine_id.clone(), record.trigger);
            }
        }
        self.resume_pending();
    }

    fn stopped_by_operator(&self, record: &RunRecord) -> bool {
        let Some(path) = &record.log_path else {
            return false;
        };
        Self::tail_of_file(Path::new(path), 4000)
            .0
            .to_ascii_lowercase()
            .contains("request interrupted by user")
    }

    fn ended_on_network_error(&self, record: &RunRecord) -> bool {
        let Some(path) = &record.log_path else {
            return false;
        };
        NetworkFailure::matches(&Self::tail_of_file(Path::new(path), 4000).0)
    }

    pub(crate) fn still_running(&self, record: &RunRecord) -> bool {
        let Some(session) = &record.session_id else {
            return false;
        };
        if let Some(path) = &record.log_path
            && let Some(lease) = RunLease::read(Path::new(path))
            && lease.process.as_ref().is_some_and(OwnedProcess::exists)
        {
            return true;
        }
        match record.harness {
            Harness::Claude => self.check_session_alive(&ClaudeInteractiveRun::screen_name(session)),
            Harness::Shell => self.check_session_alive(session),
            Harness::Codex | Harness::Grok | Harness::Antigravity => false,
        }
    }

    pub(crate) fn adopt_surviving(&self, record: &RunRecord) -> bool {
        if record.harness == Harness::Shell {
            return self.adopt(record, LaunchMode::Screen, None);
        }
        if record.harness == Harness::Claude
            && let Some(session) = &record.session_id
            && self.check_session_alive(&ClaudeInteractiveRun::screen_name(session))
        {
            let Some(transcript) = self.lookup_terminal_transcript(Harness::Claude, session) else {
                return false;
            };
            return self.adopt(record, LaunchMode::ClaudeInteractive, Some(transcript));
        }
        self.adopt_interrupted(record)
    }

    pub(crate) fn adopt_interrupted(&self, record: &RunRecord) -> bool {
        let mode = record.launch_mode.unwrap_or_else(|| record.harness.launch_mode());
        self.adopt(record, mode, None)
    }

    fn adopt(&self, original: &RunRecord, mode: LaunchMode, transcript: Option<PathBuf>) -> bool {
        let (mut record, mut spec): (RunRecord, LaunchSpec) = if let Some(reopened) =
            self.reopen(original, "")
        {
            reopened
        } else if let (Some(routine), Some(path)) = (self.routine(&original.routine_id), &original.log_path) {
            let mut rec = original.clone();
            rec.outcome = RunOutcome::Running;
            rec.ended_at = None;
            let sp = self.build_spec(
                &routine,
                original,
                original.harness,
                "",
                PathBuf::from(path),
                None,
            );
            (rec, sp)
        } else {
            return false;
        };

        spec.mode = mode;
        if let Some(exe) = &record.executable_path
            && is_executable_file(Path::new(exe))
        {
            spec.executable = exe.clone();
        }
        spec.adopt = true;
        spec.terminal_transcript = transcript;
        if let Some(timeout) = spec.timeout_secs {
            let elapsed = (self.now().as_second() - record.started_at.as_second()) as f64;
            spec.timeout_secs = Some((timeout - elapsed).max(0.0));
        }
        if let Some(qs) = &mut record.questions {
            qs.retain(|q| q.reply_via_message == Some(true));
        }
        self.start_launch(record, spec).is_ok()
    }

    pub(crate) fn refresh_surviving_sessions(&self) {
        let candidates: Vec<(Uuid, RunRecord)> = self
            .state
            .lock()
            .unwrap()
            .surviving_sessions
            .iter()
            .map(|(k, v)| (*k, v.clone()))
            .collect();
        let mut dead = Vec::new();
        for (id, rec) in candidates {
            if rec.needs_reconciliation != Some(true) && !self.still_running(&rec) {
                dead.push(id);
            }
        }
        if !dead.is_empty() {
            let mut g = self.state.lock().unwrap();
            for id in dead {
                g.surviving_sessions.remove(&id);
            }
        }
    }

    pub(crate) fn reserve_unverified(&self, record: &RunRecord) {
        let mut updated = record.clone();
        updated.needs_reconciliation = Some(true);
        self.save_record(&updated);
        let retry_at = Timestamp::from_second(self.now().as_second() + Self::RETRY_DELAY_SECS)
            .unwrap_or_else(|_| self.now());
        let mut g = self.state.lock().unwrap();
        g.surviving_sessions.insert(updated.id, updated.clone());
        g.reconciliation_retry.insert(updated.id, retry_at);
        g.last_error = Some(
            "The native session state is unknown. Rota will check it before starting another run."
                .to_string(),
        );
    }

    pub(crate) fn reconcile_native(&self, record: &RunRecord) {
        {
            let mut g = self.state.lock().unwrap();
            g.surviving_sessions.remove(&record.id);
            g.reconciliation_retry.remove(&record.id);
        }
        if !self.adopt_interrupted(record) {
            self.reserve_unverified(record);
        }
    }

    pub(crate) fn reconcile_pending(&self) {
        if !self.is_online() {
            return;
        }
        let now = self.now();
        let due: Vec<RunRecord> = {
            let g = self.state.lock().unwrap();
            g.surviving_sessions
                .values()
                .filter(|r| {
                    r.needs_reconciliation == Some(true)
                        && !g.active.contains_key(&r.id)
                        && g.reconciliation_retry
                            .get(&r.id)
                            .is_none_or(|&retry_at| retry_at <= now)
                })
                .cloned()
                .collect()
        };
        for rec in due {
            self.reconcile_native(&rec);
        }
    }

    pub fn resume_pending(&self) {
        type PendingBatch = (Vec<(Uuid, String)>, Vec<(String, RunTrigger)>);
        let (resumes, reruns): PendingBatch = {
            let g = self.state.lock().unwrap();
            if g.pending_resumes.is_empty() && g.pending_reruns.is_empty() {
                return;
            }
            (
                g.pending_resumes.iter().map(|(k, v)| (*k, v.clone())).collect(),
                g.pending_reruns.iter().map(|(k, v)| (k.clone(), *v)).collect(),
            )
        };
        if !self.is_online() {
            self.retry_later();
            return;
        }
        let probe = self.probe_fn();
        for (record_id, routine_id) in resumes {
            let Some(routine) = self.routine(&routine_id) else {
                self.state.lock().unwrap().pending_resumes.remove(&record_id);
                continue;
            };
            let weak = self.self_weak.clone();
            probe(
                routine.harness,
                Box::new(move |reachable| {
                    let Some(sched) = weak.upgrade() else {
                        return;
                    };
                    if !reachable || !sched.is_online() {
                        sched.retry_later();
                        return;
                    }
                    let removed = sched
                        .state
                        .lock()
                        .unwrap()
                        .pending_resumes
                        .remove(&record_id)
                        .is_some();
                    if !removed || sched.is_session_active(record_id) {
                        return;
                    }
                    let Some(mut rec) = sched
                        .history
                        .records(&routine_id)
                        .into_iter()
                        .find(|r| r.id == record_id)
                    else {
                        return;
                    };
                    if sched.is_surviving_session(rec.id) || sched.has_native_conflict(&rec) {
                        return;
                    }
                    rec.resumes = Some(rec.resumes.unwrap_or(0) + 1);
                    Self::LOG.info(&format!("Continuing {routine_id} after an interruption"));
                    let _ = sched.continue_session(&rec, Self::RESUME_MESSAGE);
                }),
            );
        }
        for (routine_id, trigger) in reruns {
            let Some(routine) = self.routine(&routine_id) else {
                self.state.lock().unwrap().pending_reruns.remove(&routine_id);
                continue;
            };
            let weak = self.self_weak.clone();
            probe(
                routine.harness,
                Box::new(move |reachable| {
                    let Some(sched) = weak.upgrade() else {
                        return;
                    };
                    if !reachable || !sched.is_online() {
                        sched.retry_later();
                        return;
                    }
                    let removed = sched
                        .state
                        .lock()
                        .unwrap()
                        .pending_reruns
                        .remove(&routine_id)
                        .is_some();
                    if !removed || sched.is_running(&routine_id) || sched.has_surviving_session(&routine_id) {
                        return;
                    }
                    let Some(r) = sched.routine(&routine_id) else {
                        return;
                    };
                    {
                        let mut g = sched.state.lock().unwrap();
                        *g.reruns.entry(routine_id.clone()).or_insert(0) += 1;
                    }
                    Self::LOG.info(&format!("Running {routine_id} again after a network failure"));
                    let _ = sched.run_routine(&r, trigger, false);
                }),
            );
        }
    }

    fn retry_later(&self) {
        {
            let mut g = self.state.lock().unwrap();
            if g.retry_scheduled {
                return;
            }
            g.retry_scheduled = true;
        }
        let weak = self.self_weak.clone();
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_secs(Self::RETRY_DELAY_SECS as u64));
            if let Some(sched) = weak.upgrade() {
                sched.state.lock().unwrap().retry_scheduled = false;
                sched.resume_pending();
            }
        });
    }
}
