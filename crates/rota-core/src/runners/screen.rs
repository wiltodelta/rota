use std::collections::HashMap;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use rota_platform::{OwnedProcess, home_dir};
use uuid::Uuid;

use crate::model::RunOutcome;
use crate::runners::{LaunchError, LaunchSpec, ProcessLauncher, RunControl};
use crate::storage::atomic_write_bytes;
use crate::transcript::{RunJournal, TranscriptItemKind, shell_quote};

pub struct ScreenRun {
    journal: Arc<RunJournal>,
    name: String,
    exit_file: PathBuf,
    script: PathBuf,
    child_file: PathBuf,
    state: Mutex<ScreenState>,
}

#[derive(Default)]
struct ScreenState {
    children: Vec<OwnedProcess>,
    stop_reason: Option<RunOutcome>,
}

impl ScreenRun {
    pub const SCREEN: &'static str = "/usr/bin/screen";
    pub const COMMAND_TIMEOUT: Duration = Duration::from_secs(5);

    pub fn caches_folder() -> PathBuf {
        home_dir().join("Library/Caches/Rota/screen")
    }

    pub fn command(name: &str, arguments: &[&str]) -> i32 {
        let mut args = vec!["-S".to_string(), name.to_string()];
        args.extend(arguments.iter().map(|s| (*s).to_string()));
        ProcessLauncher::capture(
            Self::SCREEN,
            &args,
            &std::env::temp_dir(),
            Some(Self::COMMAND_TIMEOUT),
            true,
            false,
            &HashMap::new(),
        )
        .0
    }

    pub fn list(name: &str) -> String {
        let args = vec!["-ls".to_string(), name.to_string()];
        ProcessLauncher::capture(
            Self::SCREEN,
            &args,
            &std::env::temp_dir(),
            Some(Self::COMMAND_TIMEOUT),
            true,
            false,
            &HashMap::new(),
        )
        .1
    }

    pub fn pid_in_list(name: &str, list: &str) -> Option<i32> {
        Self::pids_in_list(name, list).into_iter().next()
    }

    /// Every session named exactly `name` in a `screen -ls` listing.
    pub fn pids_in_list(name: &str, list: &str) -> Vec<i32> {
        list.split_whitespace()
            .filter_map(|token| {
                let (pid_str, session_name) = token.split_once('.')?;
                (session_name == name).then(|| pid_str.parse::<i32>().ok())?
            })
            .collect()
    }

    /// Ends every session named exactly `name` with all its processes, and returns how many there were.
    /// Two sessions under one name refuse each `screen -S name` command ("several suitable screens").
    pub fn terminate(name: &str) -> usize {
        let roots: Vec<OwnedProcess> = Self::pids_in_list(name, &Self::list(name))
            .into_iter()
            .filter_map(OwnedProcess::capture)
            .collect();
        if roots.is_empty() {
            return 0;
        }
        let mut owned: Vec<OwnedProcess> = Vec::new();
        for r in &roots {
            owned.extend(r.descendants());
            owned.push(*r);
        }
        for p in &owned {
            p.signal(libc::SIGTERM);
        }
        for _ in 0..50 {
            if !owned.iter().any(OwnedProcess::exists) {
                break;
            }
            std::thread::sleep(Duration::from_millis(100));
        }
        for p in &owned {
            p.signal(libc::SIGKILL);
        }
        // A killed screen leaves its socket listed as dead, which would still read as alive.
        let wipe_args = vec!["-wipe".to_string(), name.to_string()];
        let _ = ProcessLauncher::capture(
            Self::SCREEN,
            &wipe_args,
            &std::env::temp_dir(),
            Some(Self::COMMAND_TIMEOUT),
            true,
            false,
            &HashMap::new(),
        );
        roots.len()
    }

    pub fn pid(name: &str) -> Option<i32> {
        Self::pid_in_list(name, &Self::list(name))
    }

    pub fn attached(name: &str, list: &str) -> bool {
        list.lines()
            .any(|line| Self::pid_in_list(name, line).is_some() && line.contains("(Attached)"))
    }

    pub fn alive(name: &str) -> bool {
        Self::pid(name).is_some()
    }

    pub fn launch_detached(
        name: &str,
        script: &Path,
        directory: &str,
        environment: &HashMap<String, String>,
        login_shell: bool,
    ) -> Result<(), LaunchError> {
        let mut args = vec!["-U".into(), "-dmS".into(), name.into(), "/bin/zsh".into()];
        if login_shell {
            args.push("-l".into());
        }
        args.push(script.to_string_lossy().into_owned());
        let mut cmd =
            ProcessLauncher::login_shell_command(Self::SCREEN, &args, Path::new(directory), environment);
        let status = cmd.status().map_err(|e| LaunchError::Message(e.to_string()))?;
        let code = status.code().unwrap_or(-1);
        if code != 0 {
            return Err(LaunchError::ScreenFailed(code));
        }
        Ok(())
    }

    pub fn hardcopy(name: &str, file: &Path) -> Option<Vec<u8>> {
        let _ = std::fs::remove_file(file);
        let path_str = file.to_string_lossy();
        Self::command(name, &["-p", "0", "-X", "hardcopy", &path_str]);
        for _ in 0..10 {
            if file.exists() {
                break;
            }
            std::thread::sleep(Duration::from_millis(50));
        }
        let data = std::fs::read(file).ok();
        let _ = std::fs::remove_file(file);
        data
    }

    pub fn type_keys(name: &str, text: &str) {
        Self::command(name, &["-p", "0", "-X", "stuff", text]);
    }

    /// Quits session `name`; a wedged screen that ignores its own commands, or one of two sharing
    /// the name, is ended with its processes.
    pub fn quit(name: &str) {
        if Self::command(name, &["-X", "quit"]) != 0 {
            let _ = Self::terminate(name);
        }
    }

    pub fn script_text(command: &str, directory: &str, log: &Path, exit_file: &Path) -> String {
        let mut pid_path = exit_file.as_os_str().to_os_string();
        pid_path.push(".pid");
        let pid_str = PathBuf::from(pid_path).to_string_lossy().into_owned();
        let exit_str = exit_file.to_string_lossy();
        let log_str = log.to_string_lossy();
        format!(
            "cd {} || {{ print -r -- 1 > {}; exit 1 }}\n\
{{ zmodload zsh/system\n\
print -r -- \"$sysparams[pid] $sysparams[ppid]\" > {}\n\
{command}\n\
}} 2>&1 | tee -a {}\n\
print -r -- ${{pipestatus[1]}} > {}",
            shell_quote(directory),
            shell_quote(&exit_str),
            shell_quote(&pid_str),
            shell_quote(&log_str),
            shell_quote(&exit_str),
        )
    }

    pub fn start(spec: LaunchSpec, journal: Arc<RunJournal>) -> Result<Arc<dyn RunControl>, LaunchError> {
        let name = if spec.adopt {
            spec.resume.clone().unwrap_or_default()
        } else {
            let short = &Uuid::new_v4().simple().to_string()[..8];
            format!("rota-{short}")
        };
        if !name.starts_with("rota-") || name.contains('/') || name.contains("..") {
            return Err(LaunchError::Message("Invalid screen session name".into()));
        }
        let folder = Self::caches_folder();
        std::fs::create_dir_all(&folder).map_err(|e| LaunchError::Message(e.to_string()))?;
        let script = folder.join(format!("{name}.zsh"));
        let exit_file = folder.join(format!("{name}.exit"));
        let mut pid_os = exit_file.as_os_str().to_os_string();
        pid_os.push(".pid");
        let child_file = PathBuf::from(pid_os);

        let run = Arc::new(Self {
            journal: Arc::clone(&journal),
            name: name.clone(),
            exit_file: exit_file.clone(),
            script: script.clone(),
            child_file,
            state: Mutex::new(ScreenState::default()),
        });

        if !spec.adopt {
            let text = Self::script_text(&spec.prompt, &spec.working_directory, &spec.log, &exit_file);
            atomic_write_bytes(&script, text.as_bytes()).map_err(LaunchError::Message)?;
            Self::launch_detached(&name, &script, &spec.working_directory, &spec.environment, true)?;
        } else {
            journal.record(
                TranscriptItemKind::Status,
                "Following the shell command that kept running while Rota was closed",
            );
        }
        journal.session(&name);

        if let Some(secs) = spec.timeout_secs {
            let weak = Arc::downgrade(&run);
            std::thread::spawn(move || {
                std::thread::sleep(Duration::from_secs_f64(secs.max(0.0)));
                if let Some(r) = weak.upgrade() {
                    r.end(RunOutcome::TimedOut);
                }
            });
        }

        let poll_run = Arc::clone(&run);
        std::thread::spawn(move || poll_run.poll_loop());
        Ok(run)
    }

    fn poll_loop(self: Arc<Self>) {
        loop {
            if self.journal.is_finished() {
                return;
            }
            self.capture_children();
            {
                let g = self.state.lock().unwrap();
                if g.stop_reason.is_some() && g.children.iter().any(OwnedProcess::exists) {
                    drop(g);
                    std::thread::sleep(Duration::from_millis(100));
                    continue;
                }
            }
            let mut status = self.exit_status();
            if status.is_none() && !Self::alive(&self.name) {
                status = self.exit_status();
                if status.is_none() {
                    let reason = self
                        .state
                        .lock()
                        .unwrap()
                        .stop_reason
                        .clone()
                        .unwrap_or(RunOutcome::Interrupted);
                    self.finish(reason);
                    return;
                }
            }
            if let Some(code) = status {
                let reason = self
                    .state
                    .lock()
                    .unwrap()
                    .stop_reason
                    .clone()
                    .unwrap_or(if code == 0 {
                        RunOutcome::Succeeded
                    } else {
                        RunOutcome::Failed { exit_code: code }
                    });
                self.finish(reason);
                return;
            }
            std::thread::sleep(Duration::from_secs(2));
        }
    }

    fn exit_status(&self) -> Option<i32> {
        std::fs::read_to_string(&self.exit_file).ok()?.trim().parse().ok()
    }

    fn capture_children(&self) {
        let Ok(text) = std::fs::read_to_string(&self.child_file) else {
            return;
        };
        let ids: Vec<i32> = text.split_whitespace().filter_map(|t| t.parse().ok()).collect();
        if ids.len() == 2
            && let Some(child) = OwnedProcess::capture(ids[0])
            && child.parent == ids[1] as u32
        {
            let mut list = child.descendants();
            list.push(child);
            self.state.lock().unwrap().children = list;
        }
    }

    fn end(&self, reason: RunOutcome) {
        if self.journal.is_finished() {
            return;
        }
        self.capture_children();
        let owned = {
            let mut g = self.state.lock().unwrap();
            if g.stop_reason.is_some() {
                return;
            }
            g.stop_reason = Some(reason);
            if let Some(pid) = Self::pid(&self.name)
                && let Some(screen_proc) = OwnedProcess::capture(pid)
            {
                let mut desc = screen_proc.descendants();
                desc.extend(g.children.iter().copied());
                g.children = desc;
            }
            g.children.clone()
        };
        for child in &owned {
            child.signal(libc::SIGTERM);
        }
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_secs(2));
            for child in owned {
                child.signal(libc::SIGKILL);
            }
        });
        Self::quit(&self.name);
    }

    fn finish(&self, outcome: RunOutcome) {
        self.journal.finish(outcome);
        let _ = std::fs::remove_file(&self.exit_file);
        let _ = std::fs::remove_file(&self.script);
        let _ = std::fs::remove_file(&self.child_file);
    }
}

impl RunControl for ScreenRun {
    fn stop(&self) {
        self.end(RunOutcome::Cancelled);
    }

    fn attach_command(&self) -> Option<Vec<String>> {
        Some(vec![Self::SCREEN.into(), "-r".into(), self.name.clone()])
    }
}
