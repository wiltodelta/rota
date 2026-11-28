use std::collections::HashMap;
use std::fs::{File, OpenOptions};
use std::io::{Seek, SeekFrom};
use std::os::unix::fs::PermissionsExt;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::sync::Arc;
use std::time::Duration;

use rota_platform::{Logger, home_dir};

use crate::model::LaunchMode;
use crate::runners::streams::make_pipe;
use crate::runners::{
    AntigravityRun, ClaudeInteractiveRun, ClaudeStreamRun, CodexDaemonRun, CommandCapture,
    ExecutableDiscovery, GrokAcpRun, LaunchError, LaunchSpec, RoutineLaunching, RunControl, RunEvents,
    ScreenRun, TerminalRun,
};
use crate::storage::SessionImageStore;
use crate::transcript::{RunJournal, TranscriptItemKind, TranscriptJournal, TranscriptReader};

pub type AgentLauncher = ProcessLauncher;

#[derive(Default)]
pub struct ProcessLauncher;

impl ProcessLauncher {
    const LOG: Logger = Logger::new("runner");

    pub fn new() -> Self {
        Self
    }

    pub fn helper_directory() -> PathBuf {
        home_dir()
    }

    pub fn session_variables(env: &HashMap<String, String>) -> HashMap<String, String> {
        env.iter()
            .filter(|(k, _)| k.starts_with("ROTA_"))
            .map(|(k, v)| (k.clone(), v.clone()))
            .collect()
    }

    pub fn base_environment() -> HashMap<String, String> {
        Self::base_environment_from(&std::env::vars().collect())
    }

    pub fn base_environment_from(inherited: &HashMap<String, String>) -> HashMap<String, String> {
        const KEPT: [&str; 10] = [
            "HOME",
            "USER",
            "LOGNAME",
            "SHELL",
            "TMPDIR",
            "LANG",
            "LC_ALL",
            "LC_CTYPE",
            "SSH_AUTH_SOCK",
            "__CF_USER_TEXT_ENCODING",
        ];
        let mut base = HashMap::new();
        for (k, v) in inherited {
            if KEPT.contains(&k.as_str()) || k == "ROTA_DATA_DIR" {
                base.insert(k.clone(), v.clone());
            }
        }
        base.insert("PATH".to_string(), "/usr/bin:/bin:/usr/sbin:/sbin".to_string());
        base
    }

    pub fn login_shell_command(
        executable: &str,
        arguments: &[String],
        directory: &Path,
        environment: &HashMap<String, String>,
    ) -> Command {
        let mut cmd = Command::new("/bin/zsh");
        cmd.arg("-lc")
            .arg("exec \"$0\" \"$@\"")
            .arg(executable)
            .args(arguments)
            .current_dir(directory)
            .env_clear()
            .envs(Self::base_environment())
            .envs(environment)
            .stdin(Stdio::null())
            .process_group(0);
        cmd
    }

    pub fn capture(
        executable: &str,
        arguments: &[String],
        directory: &Path,
        timeout: Option<Duration>,
        include_stderr: bool,
        login_shell: bool,
        environment: &HashMap<String, String>,
    ) -> (i32, String) {
        let mut cmd = if login_shell {
            Self::login_shell_command(executable, arguments, directory, environment)
        } else {
            let mut c = Command::new(executable);
            c.args(arguments)
                .current_dir(directory)
                .env_clear()
                .envs(Self::base_environment())
                .envs(environment)
                .stdin(Stdio::null())
                .process_group(0);
            c
        };
        let (read_fd, write_fd) = match make_pipe() {
            Ok(fds) => fds,
            Err(err) => return (-1, err),
        };
        let stdout_stdio = unsafe { <Stdio as std::os::fd::FromRawFd>::from_raw_fd(write_fd) };
        cmd.stdout(stdout_stdio);
        if include_stderr {
            let dup_fd = unsafe { libc::fcntl(write_fd, libc::F_DUPFD_CLOEXEC, 0) };
            if dup_fd >= 0 {
                cmd.stderr(unsafe { <Stdio as std::os::fd::FromRawFd>::from_raw_fd(dup_fd) });
            } else {
                cmd.stderr(Stdio::null());
            }
        } else {
            cmd.stderr(Stdio::null());
        }
        let spawn_result = cmd.spawn();
        drop(cmd);
        let mut child = match spawn_result {
            Ok(c) => c,
            Err(err) => {
                unsafe {
                    libc::close(read_fd);
                }
                return (-1, err.to_string());
            }
        };
        let (bytes, timed_out) = CommandCapture::read(&mut child, read_fd, timeout);
        let status = if timed_out {
            -1
        } else {
            child.wait().ok().and_then(|s| s.code()).unwrap_or(-1)
        };
        (status, String::from_utf8_lossy(&bytes).into_owned())
    }

    pub fn journal_for(spec: &LaunchSpec, mut output: File, events: RunEvents) -> Arc<RunJournal> {
        let sidecar = TranscriptReader::journal_path(&spec.log);
        if spec.mode == LaunchMode::Screen || (spec.resume.is_some() && !sidecar.exists()) {
            return RunJournal::new(output, events, None, None);
        }
        let log_size = output.seek(SeekFrom::End(0)).unwrap_or(0);
        match TranscriptJournal::open(&spec.log, spec.resume.is_some(), log_size) {
            Ok(tj) => RunJournal::new(
                output,
                events,
                Some(tj),
                Some(SessionImageStore::new(
                    &spec.log,
                    Some(PathBuf::from(&spec.working_directory)),
                )),
            ),
            Err(_) => {
                let journal = RunJournal::new(output, events, None, None);
                journal.line("[error] Couldn't open chat history. This run will use the readable log.");
                Self::LOG.error("Couldn't open normalized chat history");
                journal
            }
        }
    }
}

impl RoutineLaunching for ProcessLauncher {
    fn launch(&self, spec: LaunchSpec, events: RunEvents) -> Result<Arc<dyn RunControl>, LaunchError> {
        if !is_executable_file(Path::new(&spec.executable)) {
            return Err(LaunchError::MissingExecutable(spec.executable));
        }
        if !Path::new(&spec.working_directory).exists() {
            return Err(LaunchError::MissingDirectory(spec.working_directory));
        }
        if let Some(parent) = spec.log.parent() {
            std::fs::create_dir_all(parent).map_err(|e| LaunchError::Message(e.to_string()))?;
        }
        if spec.resume.is_none() || !spec.log.exists() {
            File::create(&spec.log).map_err(|e| LaunchError::Message(e.to_string()))?;
        }
        let mut output = OpenOptions::new()
            .create(true)
            .truncate(false)
            .write(true)
            .open(&spec.log)
            .map_err(|e| LaunchError::Message(e.to_string()))?;
        output
            .seek(SeekFrom::End(0))
            .map_err(|e| LaunchError::Message(e.to_string()))?;
        Self::LOG.info(&format!(
            "Starting {} in {}",
            spec.executable, spec.working_directory
        ));
        let journal = Self::journal_for(&spec, output, events);
        let exe_for_ver = spec.executable.clone();
        let j_for_ver = Arc::clone(&journal);
        std::thread::spawn(move || {
            let ver = ExecutableDiscovery::version(&exe_for_ver, Duration::from_secs(5));
            j_for_ver.provenance(ver, None);
        });
        if spec.mode.records_initial_prompt() && !spec.adopt {
            journal.record(TranscriptItemKind::User, &spec.prompt);
        }
        match spec.mode {
            LaunchMode::ClaudeStream => {
                if let Some(notice) = &spec.notice {
                    journal.line(&format!("[rota: {notice}]"));
                }
                ClaudeStreamRun::start(spec, journal)
            }
            LaunchMode::ClaudeInteractive => ClaudeInteractiveRun::start(spec, journal),
            LaunchMode::CodexDaemon => Ok(CodexDaemonRun::start(spec, journal)),
            LaunchMode::GrokAcp => Ok(GrokAcpRun::start(spec, journal, None)),
            LaunchMode::AntigravityStream => AntigravityRun::start(spec, journal),
            LaunchMode::Screen => ScreenRun::start(spec, journal),
            LaunchMode::Terminal(harness) => TerminalRun::start(spec, harness, journal),
        }
    }
}

pub(crate) fn is_executable_file(path: &Path) -> bool {
    std::fs::metadata(path).is_ok_and(|m| m.is_file() && (m.permissions().mode() & 0o111) != 0)
}
