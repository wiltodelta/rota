use std::fs::{File, OpenOptions};
use std::io::{Read, Seek, SeekFrom};
use std::os::fd::AsRawFd;
use std::os::unix::fs::PermissionsExt;
use std::os::unix::process::CommandExt;
use std::path::{Path, PathBuf};
use std::process::{Child, ChildStdin, Command, Stdio};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

use rota_platform::{OwnedProcess, owned_process_group, signal_pid_or_group};
use serde_json::{Map, Value, json};
use uuid::Uuid;

use crate::model::Harness;
use crate::runners::{AgentAccess, LaunchError, LaunchSpec, ProcessLauncher};
use crate::storage::RunLease;

pub(crate) fn make_pipe() -> Result<(i32, i32), String> {
    let mut fds = [0i32; 2];
    if unsafe { libc::pipe(fds.as_mut_ptr()) } != 0 {
        return Err(std::io::Error::last_os_error().to_string());
    }
    Ok((fds[0], fds[1]))
}

pub struct CommandCapture;

impl CommandCapture {
    pub fn read(child: &mut Child, read_fd: i32, timeout: Option<Duration>) -> (Vec<u8>, bool) {
        let started = Instant::now();
        let pid = child.id() as i32;
        let group = owned_process_group(pid);
        unsafe {
            let flags = libc::fcntl(read_fd, libc::F_GETFL);
            let _ = libc::fcntl(read_fd, libc::F_SETFL, flags | libc::O_NONBLOCK);
        }
        let mut data = Vec::new();
        let mut eof = false;
        let mut terminated_at: Option<Instant> = None;
        loop {
            let now = Instant::now();
            if let Some(limit) = timeout
                && terminated_at.is_none()
                && now.duration_since(started) >= limit
            {
                terminated_at = Some(now);
                signal_pid_or_group(pid, group, libc::SIGTERM);
            }
            if let Some(term_t) = terminated_at
                && now.duration_since(term_t) >= Duration::from_millis(200)
            {
                signal_pid_or_group(pid, group, libc::SIGKILL);
                Self::drain(read_fd, &mut data, &mut eof);
                break;
            }
            let running = matches!(child.try_wait(), Ok(None));
            if eof && !running && terminated_at.is_none() {
                break;
            }
            let mut pfd = libc::pollfd {
                fd: if eof { -1 } else { read_fd },
                events: libc::POLLIN | libc::POLLHUP,
                revents: 0,
            };
            unsafe {
                let _ = libc::poll(&raw mut pfd, 1, 20);
            }
            if pfd.revents != 0 {
                Self::drain(read_fd, &mut data, &mut eof);
            }
        }
        unsafe {
            libc::close(read_fd);
        }
        let _ = child.wait();
        (data, terminated_at.is_some())
    }

    fn drain(fd: i32, data: &mut Vec<u8>, eof: &mut bool) {
        let mut buf = [0u8; 65_536];
        for _ in 0..16 {
            let n = unsafe { libc::read(fd, buf.as_mut_ptr().cast(), buf.len()) };
            if n < 0 {
                if std::io::Error::last_os_error().raw_os_error() == Some(libc::EINTR) {
                    continue;
                }
                return;
            }
            if n == 0 {
                *eof = true;
                return;
            }
            data.extend_from_slice(&buf[..n as usize]);
        }
    }
}

/// Private stdout spool (`<log>.streams/<id>.jsonl` + `<id>.exit`) surviving host restarts.
pub struct DurableStream {
    child: Mutex<Option<Child>>,
    stdin: Mutex<Option<ChildStdin>>,
    lease: RunLease,
    source: PathBuf,
    exit_file: PathBuf,
    stopping: Mutex<Vec<OwnedProcess>>,
}

impl DurableStream {
    pub fn folder(log: &Path) -> PathBuf {
        let mut s = log.as_os_str().to_os_string();
        s.push(".streams");
        PathBuf::from(s)
    }

    pub fn spawn(spec: &LaunchSpec, arguments: &[String]) -> Result<Arc<Self>, LaunchError> {
        let id = Uuid::new_v4().to_string();
        let folder = Self::folder(&spec.log);
        std::fs::create_dir_all(&folder).map_err(|e| LaunchError::Message(e.to_string()))?;
        let _ = std::fs::set_permissions(&folder, std::fs::Permissions::from_mode(0o700));
        let source = folder.join(format!("{id}.jsonl"));
        let exit_file = folder.join(format!("{id}.exit"));
        let out_file = OpenOptions::new()
            .create(true)
            .truncate(true)
            .write(true)
            .open(&source)
            .map_err(|e| LaunchError::Message(e.to_string()))?;
        let _ = std::fs::set_permissions(&source, std::fs::Permissions::from_mode(0o600));
        let err_file = out_file
            .try_clone()
            .map_err(|e| LaunchError::Message(e.to_string()))?;

        let mut cmd = Command::new("/bin/zsh");
        cmd.arg("-lc")
            .arg("\"$@\"; rota_status=$?; print -r -- $rota_status > \"$0\"; exit $rota_status")
            .arg(&exit_file)
            .arg(&spec.executable)
            .args(arguments)
            .current_dir(&spec.working_directory)
            .env_clear()
            .envs(ProcessLauncher::base_environment())
            .envs(&spec.environment)
            .stdin(Stdio::piped())
            .stdout(Stdio::from(out_file))
            .stderr(Stdio::from(err_file))
            .process_group(0);

        let mut child = cmd.spawn().map_err(|e| LaunchError::Message(e.to_string()))?;
        let pid = child.id() as i32;
        let stdin = child.stdin.take();
        if let Some(s) = &stdin {
            let _ = s.as_raw_fd();
            crate::rpc::disable_sigpipe(s);
        }
        let lease = match RunLease::save_pid(pid, &spec.log, &id) {
            Ok(l) => l,
            Err(err) => {
                if let Some(owned) = OwnedProcess::capture(pid) {
                    for c in owned.descendants() {
                        c.signal(libc::SIGKILL);
                    }
                }
                let _ = child.kill();
                let _ = child.wait();
                return Err(LaunchError::Message(err));
            }
        };
        Ok(Arc::new(Self {
            child: Mutex::new(Some(child)),
            stdin: Mutex::new(stdin),
            lease,
            source,
            exit_file,
            stopping: Mutex::new(Vec::new()),
        }))
    }

    pub fn restore(log: &Path) -> Result<Arc<Self>, LaunchError> {
        let lease = RunLease::read(log).ok_or_else(|| LaunchError::Message("Missing run lease".into()))?;
        if Uuid::parse_str(&lease.id).is_err() {
            return Err(LaunchError::Message("Corrupt run lease id".into()));
        }
        let folder = Self::folder(log);
        Ok(Arc::new(Self {
            child: Mutex::new(None),
            stdin: Mutex::new(None),
            source: folder.join(format!("{}.jsonl", lease.id)),
            exit_file: folder.join(format!("{}.exit", lease.id)),
            lease,
            stopping: Mutex::new(Vec::new()),
        }))
    }

    pub fn write_input(&self, bytes: &[u8]) -> std::io::Result<()> {
        use std::io::Write;
        let mut g = self.stdin.lock().unwrap();
        let stdin = g
            .as_mut()
            .ok_or_else(|| std::io::Error::new(std::io::ErrorKind::BrokenPipe, "stdin closed"))?;
        stdin.write_all(bytes)?;
        stdin.flush()
    }

    pub fn close_input(&self) {
        let _ = self.stdin.lock().unwrap().take();
    }

    pub fn has_input(&self) -> bool {
        self.stdin.lock().unwrap().is_some()
    }

    pub fn alive(&self) -> bool {
        let child_alive = {
            let mut g = self.child.lock().unwrap();
            g.as_mut().map(|c| matches!(c.try_wait(), Ok(None)))
        };
        let root_alive =
            child_alive.unwrap_or_else(|| self.lease.process.as_ref().is_some_and(OwnedProcess::exists));
        root_alive || self.stopping.lock().unwrap().iter().any(OwnedProcess::exists)
    }

    pub fn follow<L, E>(self: &Arc<Self>, mut on_line: L, on_ended: E)
    where
        L: FnMut(&[u8], String) + Send + 'static,
        E: FnOnce(i32) + Send + 'static,
    {
        let me = Arc::clone(self);
        std::thread::spawn(move || {
            let mut offset = 0u64;
            let mut line_start = 0u64;
            let mut pending: Vec<u8> = Vec::new();
            loop {
                if let Ok(mut file) = File::open(&me.source) {
                    let size = file.seek(SeekFrom::End(0)).unwrap_or(0);
                    if size < offset {
                        on_ended(-1);
                        return;
                    }
                    let _ = file.seek(SeekFrom::Start(offset));
                    let mut buf = [0u8; 65_536];
                    while let Ok(n) = file.read(&mut buf) {
                        if n == 0 {
                            break;
                        }
                        offset += n as u64;
                        pending.extend_from_slice(&buf[..n]);
                        while let Some(nl) = pending.iter().position(|&b| b == b'\n') {
                            let line: Vec<u8> = pending.drain(..=nl).take(nl).collect();
                            on_line(&line, format!("{}/{line_start}", me.lease.id));
                            line_start += (line.len() as u64) + 1;
                        }
                    }
                } else {
                    on_ended(-1);
                    return;
                }
                if !me.alive() {
                    if !pending.is_empty() {
                        on_line(&pending, format!("{}/{line_start}", me.lease.id));
                        pending.clear();
                    }
                    let status = std::fs::read_to_string(&me.exit_file)
                        .ok()
                        .and_then(|s| s.trim().parse::<i32>().ok())
                        .unwrap_or(-1);
                    on_ended(status);
                    return;
                }
                std::thread::sleep(Duration::from_millis(100));
            }
        });
    }

    pub fn stop(&self, kill_delay: Duration) {
        let Some(root) = self.lease.process else {
            return;
        };
        let mut owned = root.descendants();
        owned.push(root);
        *self.stopping.lock().unwrap() = owned.clone();
        for p in &owned {
            p.signal(libc::SIGTERM);
        }
        std::thread::spawn(move || {
            std::thread::sleep(kill_delay);
            for p in owned {
                p.signal(libc::SIGKILL);
            }
        });
    }
}

pub struct SessionBridge;

impl SessionBridge {
    pub fn codex(spec: &LaunchSpec) -> Map<String, Value> {
        let mut out = Map::new();
        let Some(cli) = spec.environment.get("ROTA_CLI") else {
            return out;
        };
        if !AgentAccess::is_added(Harness::Codex, &spec.executable) {
            return out;
        }
        out.insert("mcp_servers.rota.command".into(), json!(cli));
        out.insert("mcp_servers.rota.args".into(), json!(["mcp"]));
        out.insert("mcp_servers.rota.enabled".into(), json!(true));
        for (k, v) in ProcessLauncher::session_variables(&spec.environment) {
            out.insert(format!("mcp_servers.rota.env.{k}"), json!(v));
        }
        out
    }

    pub fn grok(spec: &LaunchSpec) -> Vec<Value> {
        let Some(cli) = spec.environment.get("ROTA_CLI") else {
            return Vec::new();
        };
        if !AgentAccess::is_added(Harness::Grok, &spec.executable) {
            return Vec::new();
        }
        let env: Vec<Value> = ProcessLauncher::session_variables(&spec.environment)
            .into_iter()
            .map(|(k, v)| json!({"name": k, "value": v}))
            .collect();
        vec![json!({
            "name": AgentAccess::SERVER_NAME,
            "command": cli,
            "args": ["mcp"],
            "env": env,
        })]
    }
}

pub struct SubagentStatus;

impl SubagentStatus {
    pub fn grok(update: &Value) -> Option<String> {
        let id = update.get("subagent_id").and_then(Value::as_str)?;
        match update.get("sessionUpdate").and_then(Value::as_str) {
            Some("subagent_spawned") => Some(format!("Agent {id}: working")),
            Some("subagent_finished") => {
                let status = update.get("status").and_then(Value::as_str).unwrap_or("finished");
                let label = if status == "error" { "failed" } else { status };
                Some(format!("Agent {id}: {label}"))
            }
            _ => None,
        }
    }
}
