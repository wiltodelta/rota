use std::collections::HashSet;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::{Duration, UNIX_EPOCH};

use jiff::Timestamp;
use rota_platform::{Logger, OwnedProcess, home_dir, system_uptime_seconds};
use serde_json::Value;
use uuid::Uuid;

use crate::model::RunOutcome;
use crate::runners::{
    ClaudeConfiguration, ClaudeDialogBridge, ClaudeRunSettings, LaunchError, LaunchSpec, RunControl,
    ScreenRun,
};
use crate::storage::atomic_write_bytes;
use crate::transcript::{RunJournal, TranscriptItemKind, shell_quote};

pub use super::claude_transcript::{ClaudeToolCall, ClaudeTranscript};

pub(super) struct InteractiveState {
    pub(super) transcript: Option<PathBuf>,
    pub(super) offset: u64,
    pub(super) partial: Vec<u8>,
    pub(super) prompt_pending: bool,
    pub(super) unanswered: usize,
    pub(super) turn_ended: bool,
    pub(super) errored_at: Option<f64>,
    pub(super) background: HashSet<String>,
    pub(super) failed: bool,
    pub(super) exiting: bool,
    pub(super) stop_reason: Option<RunOutcome>,
    pub(super) stopping: Vec<OwnedProcess>,
    pub(super) header_written: bool,
}

pub struct ClaudeInteractiveRun {
    pub(super) spec: LaunchSpec,
    pub(super) journal: Arc<RunJournal>,
    pub(super) session: String,
    pub(super) name: String,
    pub(super) exit_file: PathBuf,
    pub(super) script: PathBuf,
    pub(super) effort_file: PathBuf,
    pub(super) settings_file: Option<PathBuf>,
    pub(super) dialogs: Arc<ClaudeDialogBridge>,
    pub(super) uptime: Arc<dyn Fn() -> f64 + Send + Sync>,
    pub(super) state: Mutex<InteractiveState>,
}

impl ClaudeInteractiveRun {
    pub(super) const LOG: Logger = Logger::new("claude");
    /// How long Claude may sit silent on an API error before the run takes its turn as over.
    pub const STALL_GRACE_SECS: f64 = 300.0;

    pub fn screen_name(session: &str) -> String {
        let prefix: String = session.chars().take(8).collect();
        format!("rota-claude-{}", prefix.to_ascii_lowercase())
    }

    pub fn transcript_file(session: &str) -> Option<PathBuf> {
        Self::transcript_file_in(session, &home_dir().join(".claude/projects"))
    }

    pub fn transcript_file_in(session: &str, projects: &Path) -> Option<PathBuf> {
        let entries = std::fs::read_dir(projects).ok()?;
        let target = format!("{session}.jsonl");
        for entry in entries.flatten() {
            let candidate = entry.path().join(&target);
            if candidate.exists() {
                return Some(candidate);
            }
        }
        None
    }

    pub fn arguments(
        session: &str,
        resume: bool,
        settings: &str,
        model_flags: &[String],
        prompt: &str,
    ) -> Vec<String> {
        let mut args = vec![
            if resume { "--resume" } else { "--session-id" }.to_string(),
            session.to_string(),
            "--settings".to_string(),
            settings.to_string(),
            "--permission-mode".to_string(),
            "bypassPermissions".to_string(),
        ];
        args.extend(model_flags.iter().cloned());
        args.push("--".to_string());
        args.push(prompt.to_string());
        args
    }

    pub fn script_text(executable: &str, arguments: &[String], directory: &str, exit_file: &Path) -> String {
        let exit_q = shell_quote(&exit_file.to_string_lossy());
        let cmd = std::iter::once(executable)
            .chain(arguments.iter().map(String::as_str))
            .map(shell_quote)
            .collect::<Vec<_>>()
            .join(" ");
        format!(
            "cd {} || {{ print -r -- 1 > {exit_q}; exit 1 }}\n\
{cmd}\n\
print -r -- $? > {exit_q}",
            shell_quote(directory)
        )
    }

    pub fn start(spec: LaunchSpec, journal: Arc<RunJournal>) -> Result<Arc<dyn RunControl>, LaunchError> {
        let folder = ScreenRun::caches_folder();
        std::fs::create_dir_all(&folder).map_err(|e| LaunchError::Message(e.to_string()))?;
        let session = spec.resume.clone().unwrap_or_else(|| Uuid::new_v4().to_string());
        let name = Self::screen_name(&session);
        let settings_file = if spec.adopt {
            None
        } else {
            Some(ClaudeRunSettings::hooks(&folder).map_err(LaunchError::Message)?)
        };
        let dialogs = ClaudeDialogBridge::new(&name, &session, &folder, Arc::clone(&journal));
        let run = Arc::new(Self {
            exit_file: folder.join(format!("{name}-{}.exit", Uuid::new_v4())),
            script: folder.join(format!("{name}.zsh")),
            effort_file: folder.join(format!("{name}-{}.effort", Uuid::new_v4())),
            settings_file,
            dialogs,
            uptime: Arc::new(system_uptime_seconds),
            spec,
            journal,
            session,
            name,
            state: Mutex::new(InteractiveState {
                transcript: None,
                offset: 0,
                partial: Vec::new(),
                prompt_pending: true,
                unanswered: 0,
                turn_ended: false,
                errored_at: None,
                background: HashSet::new(),
                failed: false,
                exiting: false,
                stop_reason: None,
                stopping: Vec::new(),
                header_written: false,
            }),
        });

        let worker = Arc::clone(&run);
        std::thread::spawn(move || {
            if worker.spec.adopt {
                worker.adopt();
            } else {
                worker.launch_worker();
            }
        });
        Ok(run)
    }

    fn launch_worker(self: Arc<Self>) {
        if let Some(resolved) = ClaudeConfiguration::read(
            &self.spec.executable,
            Path::new(&self.spec.working_directory),
            self.spec.model.as_deref(),
            self.spec.effort.as_deref(),
            self.spec.resume.as_deref(),
            Duration::from_secs(8),
        ) {
            self.journal.configure(resolved.session);
        }
        let Some(settings) = &self.settings_file else {
            return;
        };
        let args = Self::arguments(
            &self.session,
            self.spec.resume.is_some(),
            &settings.to_string_lossy(),
            &self.spec.model_flags("--effort"),
            &self.spec.prompt,
        );
        let script_text = Self::script_text(
            &self.spec.executable,
            &args,
            &self.spec.working_directory,
            &self.exit_file,
        );
        if let Err(err) = atomic_write_bytes(&self.script, script_text.as_bytes()) {
            self.clean_up();
            self.journal.finish(RunOutcome::LaunchFailed(err));
            return;
        }
        let _ = std::fs::remove_file(&self.exit_file);
        self.dialogs.clean_up();
        if let Some(existing) = Self::transcript_file(&self.session) {
            let sz = std::fs::metadata(&existing).map(|m| m.len()).unwrap_or(0);
            let mut g = self.state.lock().unwrap();
            g.transcript = Some(existing);
            g.offset = sz;
        }
        let mut env = self.spec.environment.clone();
        env.insert(
            "ROTA_SESSION_EFFORT".into(),
            self.effort_file.to_string_lossy().into_owned(),
        );
        env.insert(
            "ROTA_SESSION_DIALOG".into(),
            self.dialogs.file.to_string_lossy().into_owned(),
        );
        // A screen still open under this name belongs to a finished run (an active or surviving one
        // blocks continuing): two Claudes would write one transcript, and two screens one name.
        if ScreenRun::terminate(&self.name) > 0 {
            Self::LOG.info(&format!("ended a screen left open for claude {}", self.session));
        }
        if let Err(err) =
            ScreenRun::launch_detached(&self.name, &self.script, &self.spec.working_directory, &env, true)
        {
            self.clean_up();
            self.journal.finish(RunOutcome::LaunchFailed(err.to_string()));
            return;
        }
        self.journal.session(&self.session);
        if let Some(secs) = self.spec.timeout_secs {
            let weak = Arc::downgrade(&self);
            std::thread::spawn(move || {
                std::thread::sleep(Duration::from_secs_f64(secs.max(0.0)));
                if let Some(r) = weak.upgrade() {
                    r.end(RunOutcome::TimedOut);
                }
            });
        }
        self.poll_loop();
    }

    fn adopt(self: Arc<Self>) {
        let Some(file) = self.spec.terminal_transcript.clone() else {
            self.journal.finish(RunOutcome::Interrupted);
            return;
        };
        let Ok(bytes) = std::fs::read(&file) else {
            self.journal.finish(RunOutcome::Interrupted);
            return;
        };
        let since = std::fs::metadata(&self.spec.log)
            .and_then(|m| m.modified())
            .ok()
            .and_then(|t| t.duration_since(UNIX_EPOCH).ok())
            .and_then(|d| Timestamp::from_second(d.as_secs() as i64).ok());

        let mut start = 0usize;
        if let Some(since_ts) = since {
            while let Some(rel_nl) = bytes[start..].iter().position(|&b| b == b'\n') {
                let nl = start + rel_nl;
                let Ok(val) = serde_json::from_slice::<Value>(&bytes[start..nl]) else {
                    break;
                };
                let Some(written) = ClaudeTranscript::timestamp(&val) else {
                    break;
                };
                if written > since_ts {
                    break;
                }
                let entry = ClaudeTranscript::read_entry(&val);
                self.restore_state(&entry);
                self.dialogs.track(&val, false);
                start = nl + 1;
            }
        }
        {
            let mut g = self.state.lock().unwrap();
            g.transcript = Some(file);
            g.prompt_pending = false;
            g.header_written = true;
            g.offset = start as u64;
        }
        self.journal.session(&self.session);
        self.journal.record(
            TranscriptItemKind::Status,
            "Following the session Claude kept running while Rota was closed",
        );
        self.dialogs.adopt();
        self.poll_loop();
    }

    pub(super) fn exit_status(&self) -> Option<i32> {
        std::fs::read_to_string(&self.exit_file).ok()?.trim().parse().ok()
    }

    pub(super) fn end(&self, reason: RunOutcome) {
        if self.journal.is_finished() {
            return;
        }
        let owned = {
            let mut g = self.state.lock().unwrap();
            if g.stop_reason.is_some() {
                return;
            }
            g.stop_reason = Some(reason);
            if let Some(pid) = ScreenRun::pid(&self.name)
                && let Some(root) = OwnedProcess::capture(pid)
            {
                let mut list = root.descendants();
                list.push(root);
                g.stopping = list;
            }
            g.stopping.clone()
        };
        ScreenRun::type_keys(&self.name, "\x1B");
        let name = self.name.clone();
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_secs(1));
            ScreenRun::quit(&name);
            std::thread::sleep(Duration::from_secs(2));
            for p in &owned {
                p.signal(libc::SIGTERM);
            }
            std::thread::sleep(Duration::from_secs(7));
            for p in owned {
                p.signal(libc::SIGKILL);
            }
        });
    }

    pub(super) fn finish(&self, status: i32) {
        self.read_effort();
        self.read_transcript();
        let outcome = {
            let g = self.state.lock().unwrap();
            if let Some(r) = &g.stop_reason {
                r.clone()
            } else if g.failed {
                RunOutcome::Failed { exit_code: 1 }
            } else if g.exiting {
                RunOutcome::Succeeded
            } else if status == 0 {
                RunOutcome::Interrupted
            } else {
                RunOutcome::Failed { exit_code: status }
            }
        };
        Self::LOG.info(&format!(
            "interactive claude {} ended: {}",
            self.session,
            outcome.title()
        ));
        self.journal.finish(outcome);
        self.clean_up();
    }

    pub(super) fn clean_up(&self) {
        self.dialogs.clean_up();
        let _ = std::fs::remove_file(&self.exit_file);
        let _ = std::fs::remove_file(&self.script);
        let _ = std::fs::remove_file(&self.effort_file);
        if let Some(s) = &self.settings_file {
            let _ = std::fs::remove_file(s);
        }
    }

    pub fn new_for_test(
        spec: LaunchSpec,
        journal: Arc<RunJournal>,
        session: &str,
        folder: &Path,
        uptime: Arc<dyn Fn() -> f64 + Send + Sync>,
    ) -> Self {
        let name = Self::screen_name(session);
        let dialogs = ClaudeDialogBridge::new(&name, session, folder, Arc::clone(&journal));
        Self {
            exit_file: folder.join(format!("{name}-{}.exit", Uuid::new_v4())),
            script: folder.join(format!("{name}.zsh")),
            effort_file: folder.join(format!("{name}-{}.effort", Uuid::new_v4())),
            settings_file: None,
            dialogs,
            uptime,
            spec,
            journal,
            session: session.to_string(),
            name,
            state: Mutex::new(InteractiveState {
                transcript: None,
                offset: 0,
                partial: Vec::new(),
                prompt_pending: true,
                unanswered: 0,
                turn_ended: false,
                errored_at: None,
                background: HashSet::new(),
                failed: false,
                exiting: false,
                stop_reason: None,
                stopping: Vec::new(),
                header_written: false,
            }),
        }
    }

    /// The last turn ended, or Claude sat on an API error for `STALL_GRACE_SECS`, and nothing is left to wait for.
    pub fn ready_to_exit(&self) -> bool {
        let now_up = (self.uptime)();
        let g = self.state.lock().unwrap();
        let stalled = g.errored_at.is_some_and(|t| now_up - t >= Self::STALL_GRACE_SECS);
        (g.turn_ended || stalled) && g.unanswered == 0 && g.background.is_empty()
    }
}

impl RunControl for ClaudeInteractiveRun {
    fn stop(&self) {
        self.end(RunOutcome::Cancelled);
    }

    fn send(&self, message: &str) {
        let can_send = {
            let mut g = self.state.lock().unwrap();
            if self.journal.is_finished() || g.exiting {
                false
            } else {
                g.unanswered += 1;
                g.turn_ended = false;
                true
            }
        };
        if !can_send {
            self.journal.undelivered(message);
            return;
        }
        ScreenRun::type_keys(&self.name, &format!("\x1B[200~{message}\x1B[201~"));
        ScreenRun::type_keys(&self.name, "\r");
    }

    fn attach_command(&self) -> Option<Vec<String>> {
        Some(vec![ScreenRun::SCREEN.into(), "-r".into(), self.name.clone()])
    }
}
