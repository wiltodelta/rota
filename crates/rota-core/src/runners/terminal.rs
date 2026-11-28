use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};

use rota_platform::{OwnedProcess, home_dir};
use uuid::Uuid;

use crate::model::{Harness, LaunchMode, RunOutcome};
use crate::runners::{LaunchError, LaunchSpec, RunControl, ScreenRun};
use crate::storage::{RunLease, atomic_write_bytes};
use crate::transcript::{RunJournal, TranscriptItemKind, shell_quote};

pub use super::native_transcript::{NativeTranscript, NativeTranscriptEvent};

pub(super) struct TermState {
    pub(super) child: Option<OwnedProcess>,
    pub(super) transcript: NativeTranscript,
    pub(super) stop_reason: Option<RunOutcome>,
    pub(super) stopping: Vec<OwnedProcess>,
    pub(super) reading_transcript: bool,
    pub(super) lease: Option<RunLease>,
    pub(super) was_attached: bool,
    pub(super) waiting: bool,
    pub(super) closed_polls: usize,
}

pub struct TerminalRun {
    pub(super) journal: Arc<RunJournal>,
    pub(super) name: String,
    pub(super) script: PathBuf,
    pub(super) exit_file: PathBuf,
    pub(super) child_file: PathBuf,
    pub(super) log: PathBuf,
    pub(super) state: Mutex<TermState>,
}

impl TerminalRun {
    pub fn script_text(spec: &LaunchSpec, exit_file: &Path, child_file: &Path) -> String {
        let mut wrapper = "print -r -- \"$$ $PPID\" > \"$0\"; ".to_string();
        if spec.mode == LaunchMode::Terminal(Harness::Codex)
            && let Some(src) = &spec.terminal_transcript
            && src.parent().and_then(|p| p.file_name()).and_then(|n| n.to_str()) == Some("archived_sessions")
            && let Some(session) = &spec.resume
        {
            wrapper.push_str(&format!("\"$1\" unarchive {} || exit $?; ", shell_quote(session)));
        }
        wrapper.push_str("exec \"$@\"");

        let child_s = child_file.to_string_lossy();
        let exit_q = shell_quote(&exit_file.to_string_lossy());
        let mut tokens = vec![
            "/bin/zsh".to_string(),
            "-c".to_string(),
            wrapper,
            child_s.into_owned(),
            spec.executable.clone(),
        ];
        tokens.extend(spec.arguments.iter().cloned());
        let cmd = tokens
            .iter()
            .map(|t| shell_quote(t))
            .collect::<Vec<_>>()
            .join(" ");
        format!(
            "cd {} || {{ print -r -- 1 > {exit_q}; exit 1 }}\n\
{cmd}\n\
print -r -- $? > {exit_q}",
            shell_quote(&spec.working_directory)
        )
    }

    pub fn start(
        spec: LaunchSpec,
        harness: Harness,
        journal: Arc<RunJournal>,
    ) -> Result<Arc<dyn RunControl>, LaunchError> {
        let folder = ScreenRun::caches_folder();
        std::fs::create_dir_all(&folder).map_err(|e| LaunchError::Message(e.to_string()))?;

        let run = if spec.adopt {
            let lease = RunLease::read(&spec.log)
                .ok_or_else(|| LaunchError::Message("Missing terminal lease".into()))?;
            let name = lease
                .screen_name
                .clone()
                .ok_or_else(|| LaunchError::Message("Missing screen name".into()))?;
            if !name.starts_with("rota-terminal-") || name.contains('/') || name.contains("..") {
                return Err(LaunchError::Message("Invalid terminal screen name".into()));
            }
            let offset = lease
                .native_offset
                .ok_or_else(|| LaunchError::Message("Missing native offset".into()))?;
            let session = spec
                .resume
                .as_deref()
                .ok_or_else(|| LaunchError::Message("Missing session".into()))?;
            let source = spec
                .terminal_transcript
                .clone()
                .or_else(|| NativeTranscript::locate(harness, session))
                .ok_or_else(|| LaunchError::Message("Missing native transcript".into()))?;
            let nt = NativeTranscript::open(source, harness, Some(offset), lease.native_since, home_dir())
                .map_err(LaunchError::Message)?;
            let script = folder.join(format!("{name}.zsh"));
            let exit_file = folder.join(format!("{name}.exit"));
            let mut pid_s = script.as_os_str().to_os_string();
            pid_s.push(".pid");
            Arc::new(Self {
                journal,
                name,
                script,
                exit_file,
                child_file: PathBuf::from(pid_s),
                log: spec.log,
                state: Mutex::new(TermState {
                    child: None,
                    transcript: nt,
                    stop_reason: None,
                    stopping: Vec::new(),
                    reading_transcript: true,
                    lease: Some(lease),
                    was_attached: false,
                    waiting: false,
                    closed_polls: 0,
                }),
            })
        } else {
            let source = spec
                .terminal_transcript
                .clone()
                .ok_or_else(|| LaunchError::Message("Missing terminal transcript".into()))?;
            let nt = NativeTranscript::open(source, harness, None, None, home_dir())
                .map_err(LaunchError::Message)?;
            let name = format!("rota-terminal-{}", Uuid::new_v4());
            let script = folder.join(format!("{name}.zsh"));
            let exit_file = folder.join(format!("{name}.exit"));
            let mut pid_s = script.as_os_str().to_os_string();
            pid_s.push(".pid");
            let child_file = PathBuf::from(pid_s);
            let script_body = Self::script_text(&spec, &exit_file, &child_file);
            atomic_write_bytes(&script, script_body.as_bytes()).map_err(LaunchError::Message)?;
            if let Err(err) =
                ScreenRun::launch_detached(&name, &script, &spec.working_directory, &spec.environment, true)
            {
                let _ = std::fs::remove_file(&script);
                let _ = std::fs::remove_file(&exit_file);
                let _ = std::fs::remove_file(&child_file);
                return Err(err);
            }
            journal.record(TranscriptItemKind::Status, "Continued in Terminal");
            let lease = RunLease {
                process: ScreenRun::pid(&name).and_then(OwnedProcess::capture),
                id: Uuid::new_v4().to_string(),
                screen_name: Some(name.clone()),
                native_offset: Some(nt.checkpoint()),
                native_since: nt.since,
            };
            lease.write(&spec.log).map_err(LaunchError::Message)?;
            Arc::new(Self {
                journal,
                name,
                script,
                exit_file,
                child_file,
                log: spec.log,
                state: Mutex::new(TermState {
                    child: None,
                    transcript: nt,
                    stop_reason: None,
                    stopping: Vec::new(),
                    reading_transcript: true,
                    lease: Some(lease),
                    was_attached: false,
                    waiting: true,
                    closed_polls: 0,
                }),
            })
        };

        let worker = Arc::clone(&run);
        std::thread::spawn(move || worker.poll_loop());
        Ok(run)
    }
}

impl RunControl for TerminalRun {
    fn stop(&self) {
        self.capture_child();
        let already = {
            let mut g = self.state.lock().unwrap();
            if g.stop_reason.is_some() {
                true
            } else {
                g.stop_reason = Some(RunOutcome::Cancelled);
                if let Some(child) = g.child {
                    let mut list = child.descendants();
                    list.push(child);
                    g.stopping = list;
                }
                false
            }
        };
        if !already {
            ScreenRun::command(&self.name, &["-X", "stuff", "\x03"]);
            self.quit_screen();
        }
    }

    fn attach_command(&self) -> Option<Vec<String>> {
        Some(vec![ScreenRun::SCREEN.into(), "-x".into(), self.name.clone()])
    }
}
