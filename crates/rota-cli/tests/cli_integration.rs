use std::io::Write;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};

use rota_core::{
    ControlServer, LaunchError, LaunchSpec, RoutineLaunching, RunControl, RunEvents, RunOutcome, Scheduler,
    StorageLocation,
};

struct TempDir(PathBuf);

impl TempDir {
    fn new() -> Self {
        static SEQ: AtomicU64 = AtomicU64::new(0);
        let nanos = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .subsec_nanos();
        let n = SEQ.fetch_add(1, Ordering::Relaxed);
        let dir = PathBuf::from(format!("/tmp/rc-{}-{nanos}-{n}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        Self(dir)
    }

    fn location(&self) -> StorageLocation {
        let root = self.0.join("data");
        let logs = root.join("Logs");
        StorageLocation::new(root, logs)
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

struct DummyCtrl;
impl RunControl for DummyCtrl {
    fn stop(&self) {}
}

#[derive(Default)]
struct CliFakeLauncher {
    events: Mutex<Vec<RunEvents>>,
}

impl RoutineLaunching for CliFakeLauncher {
    fn launch(&self, spec: LaunchSpec, events: RunEvents) -> Result<Arc<dyn RunControl>, LaunchError> {
        if let Some(parent) = spec.log.parent() {
            let _ = std::fs::create_dir_all(parent);
        }
        let _ = std::fs::write(&spec.log, format!("[you] {}\nfrom cli\n", spec.prompt));
        (events.session)("rota-12345678".to_string());
        self.events.lock().unwrap().push(events);
        Ok(Arc::new(DummyCtrl))
    }
}

#[test]
fn rota_binary_subcommands_and_mcp_parity_with_agent_check() {
    let tmp = TempDir::new();
    let proj = tmp.0.join("project");
    std::fs::create_dir_all(&proj).unwrap();
    let loc = tmp.location();

    let launcher = Arc::new(CliFakeLauncher::default());
    let sched = Scheduler::new(loc.clone(), launcher.clone(), None).unwrap();
    let _server = ControlServer::for_scheduler(loc.socket_path(), Arc::clone(&sched)).unwrap();

    let bin = env!("CARGO_BIN_EXE_rota-cli");
    let run_rota = |args: &[&str]| -> (bool, String) {
        let out = Command::new(bin)
            .args(args)
            .env("ROTA_DATA_DIR", &loc.root)
            .stdin(Stdio::null())
            .output()
            .unwrap();
        let combined = format!(
            "{}{}",
            String::from_utf8_lossy(&out.stdout),
            String::from_utf8_lossy(&out.stderr)
        );
        (out.status.success(), combined.trim().to_string())
    };

    assert_eq!(run_rota(&["list"]), (true, "No routines.".to_string()));

    let (ok, add_out) = run_rota(&[
        "add",
        "cli-shell",
        "--folder",
        &proj.to_string_lossy(),
        "--schedule",
        "0 9 * * 1-5",
        "--harness",
        "shell",
        "--prompt",
        "echo from cli",
    ]);
    assert!(ok, "{add_out}");
    assert!(add_out.contains("cli-shell  on  shell  Weekdays"));

    let (dup_ok, dup_out) = run_rota(&[
        "add",
        "cli-shell",
        "--folder",
        &proj.to_string_lossy(),
        "--schedule",
        "0 9 * * 1-5",
        "--prompt",
        "x",
    ]);
    assert!(!dup_ok && dup_out.contains("exists"));

    let (bad_ok, bad_out) = run_rota(&[
        "add",
        "bad",
        "--folder",
        "/nonexistent-rota-folder",
        "--schedule",
        "0 9 * * *",
        "--prompt",
        "x",
    ]);
    assert!(!bad_ok && bad_out.contains("does not exist"));

    let (_, help_out) = run_rota(&["help"]);
    assert!(help_out.starts_with("Usage:"));

    let (run_ok, run_out) = run_rota(&["run", "cli-shell"]);
    assert!(run_ok, "{run_out}");
    assert!(run_out.starts_with("cli-shell  Running  "));
    assert!(run_out.contains("session "));

    (launcher.events.lock().unwrap()[0].finished)(RunOutcome::Succeeded);

    let (_, log_out) = run_rota(&["log", "cli-shell"]);
    assert!(log_out.contains("from cli"));

    let (_, sess_out) = run_rota(&["sessions", "cli-shell"]);
    assert!(sess_out.contains("Succeeded") && !sess_out.contains('Z'));

    let (_, upd_out) = run_rota(&["update", "cli-shell", "--schedule", "30 7 * * *"]);
    assert!(upd_out.contains("Every day"));

    let (_, off_out) = run_rota(&["off", "cli-shell"]);
    assert!(off_out.contains("cli-shell  off"));

    let (send_ok, send_out) = run_rota(&["send", "cli-shell", "hello"]);
    assert!(!send_ok && send_out.contains("shell session takes no messages"));

    // Real `rota mcp` stdio subprocess test matching agent-check.sh lines 42-49!
    let mut mcp_child = Command::new(bin)
        .arg("mcp")
        .env("ROTA_DATA_DIR", &loc.root)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    {
        let mut stdin = mcp_child.stdin.take().unwrap();
        let reqs = [
            r#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#,
            r#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            r#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
            r#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_routine","arguments":{"id":"cli-shell"}}}"#,
            r#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"get_routine","arguments":{"id":"nope"}}}"#,
        ]
        .join("\n")
            + "\n";
        stdin.write_all(reqs.as_bytes()).unwrap();
    }
    let mcp_out = mcp_child.wait_with_output().unwrap();
    assert!(mcp_out.status.success());
    let mcp_text = String::from_utf8(mcp_out.stdout).unwrap();
    let mcp_lines: Vec<&str> = mcp_text.lines().collect();
    assert_eq!(mcp_lines.len(), 4);
    assert!(mcp_lines[1].contains("\"create_routine\""));
    assert!(mcp_lines[2].contains("cli-shell"));
    assert!(mcp_lines[3].contains("\"isError\":true"));

    // Notify with --needs-reply inside session environment, then check `sessions --json`.
    let session_uuid = sched.records_for("cli-shell")[0].id.to_string();
    let notify_out = Command::new(bin)
        .args(["notify", "--needs-reply", "Approve the invoice?"])
        .env("ROTA_DATA_DIR", &loc.root)
        .env("ROTA_SESSION", &session_uuid)
        .env("ROTA_ROUTINE", "cli-shell")
        .output()
        .unwrap();
    assert!(notify_out.status.success());

    let (_, json_sessions) = run_rota(&["sessions", "cli-shell", "--json"]);
    assert!(json_sessions.contains(r#""needsReply" : "Approve the invoice?""#));

    let (rm_ok, _) = run_rota(&["remove", "cli-shell"]);
    assert!(rm_ok);
    let (show_ok, show_out) = run_rota(&["show", "cli-shell"]);
    assert!(!show_ok && show_out.contains("No routine"));
}
