use std::collections::{HashMap, HashSet};
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use rota_core::{
    ChatMessage, CliArguments, ControlCli, ControlClient, ControlError, ControlInterface, ControlMethod,
    ControlServer, LaunchError, LaunchSpec, RoutineLaunching, RunControl, RunEvents, RunOutcome, Scheduler,
    StorageLocation,
};
use serde_json::{Value, json};
use uuid::Uuid;

struct TempDir(PathBuf);

impl TempDir {
    fn new() -> Self {
        let dir = PathBuf::from(format!(
            "/tmp/rota-ctl-{}",
            &Uuid::new_v4().simple().to_string()[..8]
        ));
        std::fs::create_dir_all(&dir).unwrap();
        Self(dir)
    }

    fn location(&self) -> StorageLocation {
        StorageLocation::new(self.0.join("root"), self.0.join("logs"))
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

#[derive(Default)]
struct FakeCtrl {
    messages: Mutex<Vec<String>>,
}

impl RunControl for FakeCtrl {
    fn stop(&self) {}

    fn send(&self, message: &str) {
        self.messages.lock().unwrap().push(message.to_string());
    }
}

#[derive(Default)]
struct FakeLauncher {
    specs: Mutex<Vec<LaunchSpec>>,
    events: Mutex<Vec<RunEvents>>,
    controls: Mutex<Vec<Arc<FakeCtrl>>>,
    fail: Mutex<bool>,
}

impl RoutineLaunching for FakeLauncher {
    fn launch(&self, spec: LaunchSpec, events: RunEvents) -> Result<Arc<dyn RunControl>, LaunchError> {
        self.specs.lock().unwrap().push(spec);
        if *self.fail.lock().unwrap() {
            return Err(LaunchError::Message("Synthetic launch failure".into()));
        }
        self.events.lock().unwrap().push(events);
        let c = Arc::new(FakeCtrl::default());
        self.controls.lock().unwrap().push(Arc::clone(&c));
        Ok(c)
    }
}

#[test]
fn every_public_control_method_has_a_tool_and_cli_command_and_aliases_work() {
    let tools = ControlInterface::tools();
    let tool_methods: HashSet<_> = tools.iter().map(|t| t.method).collect();
    let public_methods: HashSet<_> = ControlMethod::ALL.into_iter().filter(|m| m.is_public()).collect();
    assert_eq!(tool_methods, public_methods);

    let empty_env = HashMap::new();
    for tool in &tools {
        let raw: Vec<String> = [
            tool.command,
            "digest",
            "hello",
            "--session",
            "s-1",
            "--question",
            "q-1",
            "--action",
            "cancel",
        ]
        .into_iter()
        .map(ToOwned::to_owned)
        .collect();
        let parsed = CliArguments::parse(&raw).unwrap();
        let (method, _) = ControlCli::request(tool.command, &parsed, &empty_env).unwrap();
        assert_eq!(method, tool.method.as_str());
    }

    // Check aliases!
    for (alias, expected_method) in [
        ("get", "routines.get"),
        ("create", "routines.create"),
        ("enable", "routines.setEnabled"),
        ("disable", "routines.setEnabled"),
        ("delete", "routines.delete"),
        ("read", "sessions.markRead"),
        ("unread", "sessions.markUnread"),
        ("message", "sessions.message"),
    ] {
        let raw = vec![alias.to_string(), "digest".to_string(), "hi".to_string()];
        let args = CliArguments::parse(&raw).unwrap();
        let (m, params) = ControlCli::request(alias, &args, &empty_env).unwrap();
        assert_eq!(m, expected_method);
        if alias == "disable" {
            assert_eq!(params["enabled"], Value::Bool(false));
        }
    }

    // Session context binding never selects a deletion target.
    let mut env = HashMap::new();
    env.insert("ROTA_SESSION".into(), "own-session".into());
    env.insert("ROTA_ROUTINE".into(), "digest".into());
    for tool in &tools {
        if tool.properties.contains_key("session") {
            let mut input = serde_json::Map::new();
            if tool.method != ControlMethod::Notify {
                input.insert("id".into(), json!("digest"));
            }
            let bound = ControlInterface::session_arguments(input, tool.method, &env);
            if tool.method == ControlMethod::SessionsDelete {
                assert!(!bound.contains_key("session"));
            } else {
                assert_eq!(bound.get("session").and_then(Value::as_str), Some("own-session"));
            }
        }
    }
}

#[test]
fn control_server_socket_permissions_attachments_and_error_handling() {
    let tmp = TempDir::new();
    let proj = tmp.0.join("project");
    std::fs::create_dir_all(&proj).unwrap();

    let launcher = Arc::new(FakeLauncher::default());
    let sched = Scheduler::new(tmp.location(), launcher.clone(), None).unwrap();
    let socket = tmp.location().socket_path();

    // Closed socket reports `not_running`.
    let closed_err =
        ControlClient::call("routines.list", json!({}), &socket, Duration::from_secs(2)).unwrap_err();
    assert_eq!(closed_err, ControlError::not_running());

    let handle = ControlServer::for_scheduler(socket.clone(), Arc::clone(&sched)).unwrap();
    let mode = std::fs::metadata(&socket).unwrap().permissions().mode() & 0o777;
    assert_eq!(mode, 0o600);

    // Parameter type validation rejects floats, booleans, and out-of-range integers.
    for bad_limit in [json!(0.5), json!(true), json!(u64::MAX), json!("ten")] {
        let err = ControlClient::call(
            "routines.create",
            json!({
                "id": "bad",
                "workingDirectory": proj.to_string_lossy(),
                "schedule": "0 9 * * *",
                "prompt": "x",
                "timeLimitMinutes": bad_limit,
            }),
            &socket,
            Duration::from_secs(5),
        )
        .unwrap_err();
        assert!(err.message.contains("a number"));
    }

    // Create, run, attach file, and check shell message refusal.
    let created = ControlClient::call(
        "routines.create",
        json!({
            "id": "digest",
            "workingDirectory": proj.to_string_lossy(),
            "schedule": "0 9 * * 1-5",
            "harness": "codex",
            "prompt": "Summarize.",
        }),
        &socket,
        Duration::from_secs(5),
    )
    .unwrap();
    assert_eq!(created["scheduleText"], "Weekdays at 9:00 AM");

    let run = ControlClient::call(
        "routines.run",
        json!({"id": "digest"}),
        &socket,
        Duration::from_secs(5),
    )
    .unwrap();
    assert_eq!(run["running"], true);
    (launcher.events.lock().unwrap()[0].session)("thread-1".to_string());

    let attachment_src = tmp.0.join("report.txt");
    std::fs::write(&attachment_src, "Attachment body").unwrap();
    ControlClient::call(
        "sessions.message",
        json!({
            "id": "digest",
            "text": "See file",
            "attachments": [attachment_src.to_string_lossy()],
        }),
        &socket,
        Duration::from_secs(5),
    )
    .unwrap();
    let raw_sent = launcher.controls.lock().unwrap()[0].messages.lock().unwrap()[0].clone();
    let decoded = ChatMessage::decode(&raw_sent);
    assert_eq!(decoded.text, "See file");
    assert_eq!(decoded.attachments.len(), 1);
    assert_eq!(
        std::fs::read_to_string(&decoded.attachments[0].path).unwrap(),
        "Attachment body"
    );

    // Failed continuation rolls back staged copies!
    (launcher.events.lock().unwrap()[0].finished)(RunOutcome::Succeeded);
    let stored = sched.records_for("digest").into_iter().next().unwrap();
    let att_folder = sched.history().attachments(&stored).unwrap().folder;
    let before_count = std::fs::read_dir(&att_folder).unwrap().count();
    *launcher.fail.lock().unwrap() = true;
    assert!(
        ControlClient::call(
            "sessions.message",
            json!({
                "id": "digest",
                "text": "Retry",
                "attachments": [attachment_src.to_string_lossy()],
            }),
            &socket,
            Duration::from_secs(5),
        )
        .is_err()
    );
    let after_count = std::fs::read_dir(&att_folder).unwrap().count();
    assert_eq!(
        after_count, before_count,
        "failed continuation cleans up staged file"
    );

    // Shell session refuses messages with exact wording expected by agent-check.sh.
    *launcher.fail.lock().unwrap() = false;
    ControlClient::call(
        "routines.create",
        json!({
            "id": "cli-shell",
            "workingDirectory": proj.to_string_lossy(),
            "schedule": "0 9 * * *",
            "harness": "shell",
            "prompt": "echo hi",
        }),
        &socket,
        Duration::from_secs(5),
    )
    .unwrap();
    ControlClient::call(
        "routines.run",
        json!({"id": "cli-shell"}),
        &socket,
        Duration::from_secs(5),
    )
    .unwrap();
    (launcher.events.lock().unwrap()[1].session)("rota-abcd1234".to_string());
    (launcher.events.lock().unwrap()[1].finished)(RunOutcome::Succeeded);
    let shell_err = ControlClient::call(
        "sessions.message",
        json!({"id": "cli-shell", "text": "hello"}),
        &socket,
        Duration::from_secs(5),
    )
    .unwrap_err();
    assert!(shell_err.message.contains("shell session takes no messages"));

    handle.stop();
    assert!(!socket.exists());
}
