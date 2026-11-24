pub mod editing;
pub mod events;
pub mod handoff;
pub mod messaging;
pub mod notifier;
pub mod questions;
pub mod resilience;
pub mod seams;
pub mod sessions;

use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Condvar, Mutex, Weak};
use std::time::Duration;

use jiff::Timestamp;
use rota_platform::{Logger, NetworkMonitorHandle, bundled_helper_path};
use uuid::Uuid;

use crate::control::{ControlServer, ControlServerHandle};
use crate::model::serde_ext::uppercase_uuid;
use crate::model::{Harness, LaunchMode, QuestionAnswer, Routine, RunOutcome, RunRecord, RunTrigger};
use crate::runners::{
    AgentLauncher, ClaudeUserSettings, LaunchSpec, QuestionReplyFn, RoutineLaunching, RunControl,
};
use crate::storage::{RoutineStore, RunHistory, StorageLocation};

pub use handoff::SessionRestart;
pub use notifier::{
    SchedulerNotifier, build_routine_added_payload, build_routine_paused_payload, build_run_ended_payload,
    build_session_notified_payload,
};
pub use resilience::{NetworkFailure, ServiceProbe, ServiceProbeFn};
use seams::SchedulerSeams;
pub use seams::{
    ClaudeSettingsFn, ClockFn, HistoryReaderFn, OnlineFn, SessionAliveFn, TerminalOpenerFn,
    TranscriptLookupFn,
};

pub(crate) struct SchedulerState {
    pub routines: Vec<Routine>,
    pub active: HashMap<Uuid, RunRecord>,
    pub surviving_sessions: HashMap<Uuid, RunRecord>,
    pub reconciliation_retry: HashMap<Uuid, Timestamp>,
    pub slept_through: HashSet<Uuid>,
    pub pending_resumes: HashMap<Uuid, String>,
    pub pending_reruns: HashMap<String, RunTrigger>,
    pub reruns: HashMap<String, usize>,
    pub retry_scheduled: bool,
    pub opening_terminals: HashSet<Uuid>,
    pub question_deliveries: HashMap<Uuid, HashSet<String>>,
    pub question_replies: HashMap<Uuid, HashMap<String, QuestionReplyFn>>,
    pub hook_answers: HashMap<String, QuestionAnswer>,
    pub controls: HashMap<Uuid, Arc<dyn RunControl>>,
    pub launch_ids: HashMap<Uuid, Uuid>,
    pub run_starts: HashMap<Uuid, Timestamp>,
    pub late_messages: HashMap<Uuid, Vec<String>>,
    pub cached_history: HashMap<String, Vec<RunRecord>>,
    pub cached_sessions: Option<Vec<RunRecord>>,
    pub last_error: Option<String>,
    pub executable_overrides: HashMap<Harness, String>,
    pub command_path: Option<String>,
}

/// Owns scheduled routines, active runs, session state, resilience, and control commands.
pub struct Scheduler {
    pub(crate) self_weak: Weak<Self>,
    location: StorageLocation,
    pub(crate) store: RoutineStore,
    pub(crate) history: RunHistory,
    pub(crate) launcher: Arc<dyn RoutineLaunching>,
    pub(crate) notifier: Option<Arc<dyn SchedulerNotifier>>,
    revision: AtomicU64,
    pub(crate) claude_interactive: AtomicBool,
    pub(crate) completion_notifications: AtomicBool,
    pub(crate) online: Arc<AtomicBool>,
    shutdown: Arc<(Mutex<bool>, Condvar)>,
    network_monitor: Mutex<Option<NetworkMonitorHandle>>,
    pub(crate) seams: Mutex<SchedulerSeams>,
    pub(crate) state: Mutex<SchedulerState>,
}

impl Scheduler {
    pub(crate) const LOG: Logger = Logger::new("scheduler");

    pub fn new(
        location: StorageLocation,
        launcher: Arc<dyn RoutineLaunching>,
        notifier: Option<Arc<dyn SchedulerNotifier>>,
    ) -> Result<Arc<Self>, String> {
        let store = RoutineStore::new(location.clone());
        let history = RunHistory::new(location.clone());
        let routines = store
            .load()
            .map_err(|e| format!("Could not read routines: {e}"))?;
        let command_path = bundled_helper_path().map(|p| p.to_string_lossy().into_owned());
        let online = Arc::new(AtomicBool::new(true));

        Ok(Arc::new_cyclic(|weak| Self {
            self_weak: weak.clone(),
            location,
            store,
            history,
            launcher,
            notifier,
            revision: AtomicU64::new(1),
            claude_interactive: AtomicBool::new(false),
            completion_notifications: AtomicBool::new(false),
            online,
            shutdown: Arc::new((Mutex::new(false), Condvar::new())),
            network_monitor: Mutex::new(None),
            seams: Mutex::new(SchedulerSeams::default()),
            state: Mutex::new(SchedulerState {
                routines,
                active: HashMap::new(),
                surviving_sessions: HashMap::new(),
                reconciliation_retry: HashMap::new(),
                slept_through: HashSet::new(),
                pending_resumes: HashMap::new(),
                pending_reruns: HashMap::new(),
                reruns: HashMap::new(),
                retry_scheduled: false,
                opening_terminals: HashSet::new(),
                question_deliveries: HashMap::new(),
                question_replies: HashMap::new(),
                hook_answers: HashMap::new(),
                controls: HashMap::new(),
                launch_ids: HashMap::new(),
                run_starts: HashMap::new(),
                late_messages: HashMap::new(),
                cached_history: HashMap::new(),
                cached_sessions: None,
                last_error: None,
                executable_overrides: HashMap::new(),
                command_path,
            }),
        }))
    }

    pub fn start_standard(
        location: StorageLocation,
        notifier: Option<Arc<dyn SchedulerNotifier>>,
    ) -> Result<(Arc<Self>, ControlServerHandle), String> {
        let scheduler = Self::new(location.clone(), Arc::new(AgentLauncher::new()), notifier)?;
        let server = ControlServer::for_scheduler(location.socket_path(), Arc::clone(&scheduler))
            .map_err(|e| e.message)?;
        scheduler.recover_orphans();
        scheduler.tick();
        scheduler.resume_pending();
        scheduler.start_background_services();
        Ok((scheduler, server))
    }

    fn start_background_services(self: &Arc<Self>) {
        let weak_net = Arc::downgrade(self);
        let monitor = NetworkMonitorHandle::start(move |satisfied| {
            if let Some(s) = weak_net.upgrade() {
                if satisfied {
                    s.network_became_available();
                } else {
                    s.online.store(false, Ordering::Release);
                }
            }
        });
        *self.network_monitor.lock().unwrap() = Some(monitor);

        let weak_tick = Arc::downgrade(self);
        let shutdown = Arc::clone(&self.shutdown);
        let _ = std::thread::Builder::new()
            .name("rota-scheduler-tick".to_string())
            .spawn(move || {
                let (lock, cvar) = &*shutdown;
                loop {
                    let guard = lock.lock().unwrap();
                    let (guard, _) = cvar.wait_timeout(guard, Duration::from_secs(30)).unwrap();
                    if *guard {
                        break;
                    }
                    drop(guard);
                    let Some(s) = weak_tick.upgrade() else {
                        break;
                    };
                    s.tick();
                }
            });
    }

    pub fn revision(&self) -> u64 {
        self.revision.load(Ordering::Acquire)
    }

    pub(crate) fn bump_revision(&self) {
        self.revision.fetch_add(1, Ordering::AcqRel);
    }

    pub(crate) fn invalidate_caches_and_bump(&self) {
        let mut g = self.state.lock().unwrap();
        g.cached_history.clear();
        g.cached_sessions = None;
        drop(g);
        self.bump_revision();
    }

    pub fn location(&self) -> &StorageLocation {
        &self.location
    }

    pub fn history(&self) -> &RunHistory {
        &self.history
    }

    pub fn last_error(&self) -> Option<String> {
        self.state.lock().unwrap().last_error.clone()
    }

    pub fn routines(&self) -> Vec<Routine> {
        self.state.lock().unwrap().routines.clone()
    }

    pub fn routine(&self, id: &str) -> Option<Routine> {
        self.state
            .lock()
            .unwrap()
            .routines
            .iter()
            .find(|r| r.id == id)
            .cloned()
    }

    pub fn run_now(&self, routine_id: &str) -> Result<RunRecord, String> {
        let Some(routine) = self.routine(routine_id) else {
            return Err(format!("No routine {routine_id}."));
        };
        if self.is_running(routine_id) {
            return Err(format!("{routine_id} is already running."));
        }
        self.run_routine(&routine, RunTrigger::Manual, true)
    }

    pub fn run_routine(
        &self,
        routine: &Routine,
        trigger: RunTrigger,
        consuming_scheduled_slot: bool,
    ) -> Result<RunRecord, String> {
        if self.is_running(&routine.id) {
            return Err(format!("{} is already running.", routine.id));
        }
        if self.has_surviving_session(&routine.id) {
            let msg = "This routine still has a native session running. Close it before starting another."
                .to_string();
            self.state.lock().unwrap().last_error = Some(msg.clone());
            return Err(msg);
        }
        if consuming_scheduled_slot
            && matches!(trigger, RunTrigger::Scheduled | RunTrigger::CatchUp)
            && !self.reserve_scheduled_run(routine)
        {
            return Err("This schedule is already complete.".to_string());
        }
        let mut record = RunRecord::new(
            routine.id.clone(),
            trigger,
            routine.harness,
            self.now(),
            RunOutcome::Running,
        );
        record.model = routine.model.clone();
        record.effort = routine.effort.clone();
        let log_path = self.history.log_file(&record);
        record.log_path = Some(log_path.to_string_lossy().into_owned());
        let spec = self.build_spec(routine, &record, routine.harness, &routine.prompt, log_path, None);
        let id = record.id;
        self.start_launch(record.clone(), spec)?;
        Ok(self.current_record_in(id, Some(&routine.id)).unwrap_or(record))
    }

    pub(crate) fn build_spec(
        &self,
        routine: &Routine,
        record: &RunRecord,
        harness: Harness,
        prompt: &str,
        log: PathBuf,
        resume: Option<String>,
    ) -> LaunchSpec {
        let settings = if harness == Harness::Claude {
            self.claude_settings()
        } else {
            ClaudeUserSettings::default()
        };
        let mut env = HashMap::new();
        env.insert("ROTA_SESSION".to_string(), uppercase_uuid(record.id));
        env.insert("ROTA_ROUTINE".to_string(), record.routine_id.clone());
        if let Some(cli) = self.state.lock().unwrap().command_path.clone() {
            env.insert("ROTA_CLI".to_string(), cli);
        }
        let mut mode = harness.launch_mode();
        let mut notice = None;
        if harness == Harness::Claude && self.claude_interactive() {
            if settings.trusts(&routine.working_directory) {
                mode = LaunchMode::ClaudeInteractive;
            } else {
                notice = Some(
                    "ran with claude -p: Claude Code has not been trusted in this folder; \
open Claude Code there once and trust it to run interactively, with computer use"
                        .to_string(),
                );
            }
        }
        LaunchSpec {
            executable: self.executable_for(harness),
            prompt: prompt.to_string(),
            arguments: harness.claude_arguments(settings.chrome_by_default, resume.as_deref()),
            working_directory: routine.working_directory.clone(),
            environment: env,
            mode,
            timeout_secs: routine.time_limit_minutes.map(|m| (m * 60) as f64),
            log,
            resume,
            model: record.model.clone(),
            effort: record.effort.clone(),
            notice,
            terminal_transcript: None,
            adopt: false,
        }
    }

    pub(crate) fn start_launch(&self, mut record: RunRecord, spec: LaunchSpec) -> Result<(), String> {
        if self.has_native_conflict(&record) {
            return Err("Native conversation is already active.".to_string());
        }
        let now = self.now();
        let id = record.id;
        let launch_id = Uuid::new_v4();
        record.updated_at = Some(now);
        record.launch_mode = Some(spec.mode);
        record.executable_path = Some(spec.executable.clone());
        record.cli_version = None;
        record.server_version = None;
        record.needs_reconciliation = None;
        record.execution_id = Some(launch_id);

        {
            let mut g = self.state.lock().unwrap();
            if g.active.contains_key(&id) {
                return Err(format!("{} is already running.", record.routine_id));
            }
            g.active.insert(id, record.clone());
            g.launch_ids.insert(id, launch_id);
            g.run_starts.insert(id, now);
            g.cached_history.remove(&record.routine_id);
            g.cached_sessions = None;
        }
        self.bump_revision();

        let events = self.build_events(&record, launch_id);
        match self.launcher.launch(spec, events) {
            Ok(control) => {
                let snapshot = {
                    let mut g = self.state.lock().unwrap();
                    if g.launch_ids.get(&id) != Some(&launch_id) {
                        return Ok(());
                    }
                    g.controls.insert(id, control);
                    g.active.get(&id).cloned().unwrap_or(record)
                };
                self.save_record(&snapshot);
                Self::LOG.info(&format!(
                    "Started {} on {}",
                    uppercase_uuid(id),
                    snapshot.harness.as_str()
                ));
                Ok(())
            }
            Err(err) => {
                let err_msg = err.to_string();
                let still_current = {
                    let mut g = self.state.lock().unwrap();
                    if g.launch_ids.get(&id) == Some(&launch_id) {
                        g.launch_ids.remove(&id);
                        g.run_starts.remove(&id);
                        g.active.remove(&id);
                        g.last_error = Some(err_msg.clone());
                        true
                    } else {
                        false
                    }
                };
                if still_current {
                    record.outcome = RunOutcome::LaunchFailed(err_msg.clone());
                    record.ended_at = Some(self.now());
                    self.save_record(&record);
                    if let (Some(notifier), Some(routine)) =
                        (&self.notifier, self.routine(&record.routine_id))
                    {
                        notifier.run_ended(&record, &routine, self.completion_notifications());
                    }
                }
                Err(err_msg)
            }
        }
    }

    pub fn stop_routine(&self, routine_id: &str) -> Result<Option<RunRecord>, String> {
        if self.routine(routine_id).is_none() {
            return Err(format!("No routine {routine_id}."));
        }
        let active_ids: Vec<Uuid> = self
            .state
            .lock()
            .unwrap()
            .active
            .values()
            .filter(|r| r.routine_id == routine_id)
            .map(|r| r.id)
            .collect();
        if active_ids.is_empty() {
            return Ok(None);
        }
        let mut last = None;
        for id in active_ids {
            if let Ok(rec) = self.stop_session(id) {
                last = Some(rec);
            }
        }
        Ok(last)
    }

    pub fn stop_session(&self, session_id: Uuid) -> Result<RunRecord, String> {
        let (record_opt, ctrl_opt) = {
            let g = self.state.lock().unwrap();
            (
                g.active.get(&session_id).cloned(),
                g.controls.get(&session_id).cloned(),
            )
        };
        if let Some(rec) = &record_opt {
            self.cancel_questions(rec);
        }
        if let Some(ctrl) = ctrl_opt {
            ctrl.stop();
        }
        self.current_record(session_id)
            .or(record_opt)
            .ok_or_else(|| format!("No session {session_id}."))
    }

    pub fn stop_all(&self) {
        let ids: Vec<Uuid> = self.state.lock().unwrap().controls.keys().copied().collect();
        for id in ids {
            let _ = self.stop_session(id);
        }
    }

    pub fn save_record(&self, record: &RunRecord) {
        let err_opt = self.history.upsert(record).err();
        let mut g = self.state.lock().unwrap();
        if let Some(err) = err_opt {
            g.last_error = Some(format!("Could not save run history: {err}"));
        }
        g.cached_history.remove(&record.routine_id);
        g.cached_sessions = None;
        drop(g);
        self.bump_revision();
    }
}

impl Drop for Scheduler {
    fn drop(&mut self) {
        let (lock, cvar) = &*self.shutdown;
        if let Ok(mut stopped) = lock.lock() {
            *stopped = true;
            cvar.notify_all();
        }
    }
}
