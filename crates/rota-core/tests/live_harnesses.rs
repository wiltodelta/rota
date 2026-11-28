mod common;

use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, mpsc};
use std::time::Duration;

use common::{TempDir, configured_or_installed_executable};
use rota_core::model::{Harness, LaunchMode, RunOutcome, SessionConfiguration};
use rota_core::runners::{
    ClaudeUserSettings, LaunchSpec, ProcessLauncher, RoutineLaunching, RunControl, RunEvents,
};
use rota_core::transcript::{TranscriptItemKind, TranscriptReader};
use uuid::Uuid;

fn live_enabled() -> bool {
    std::env::var("ROTA_LIVE").ok().as_deref() == Some("1")
}

fn executable(harness: Harness) -> String {
    configured_or_installed_executable(harness).unwrap_or_else(|| harness.default_executable())
}

struct LiveRunResult {
    outcome: RunOutcome,
    log_path: PathBuf,
    log_text: String,
    session: Option<String>,
}

fn run_live(
    folder: &Path,
    harness: Harness,
    prompt: &str,
    steer_message: Option<&str>,
    model: Option<&str>,
    effort: Option<&str>,
    mode: Option<LaunchMode>,
) -> LiveRunResult {
    let log_path = folder.join(format!("{}.log", harness.as_str()));
    let settings = ClaudeUserSettings::read();
    let spec = LaunchSpec {
        executable: executable(harness),
        prompt: prompt.to_string(),
        arguments: harness.claude_arguments(settings.chrome_by_default, None),
        working_directory: folder.to_string_lossy().into_owned(),
        environment: HashMap::new(),
        mode: mode.unwrap_or_else(|| harness.launch_mode()),
        timeout_secs: Some(240.0),
        log: log_path.clone(),
        resume: None,
        model: model.map(ToOwned::to_owned),
        effort: effort.map(ToOwned::to_owned),
        notice: None,
        terminal_transcript: None,
        adopt: false,
    };

    let (done_tx, done_rx) = mpsc::channel::<RunOutcome>();
    let session_slot: Arc<Mutex<Option<String>>> = Arc::new(Mutex::new(None));
    let config_slot: Arc<Mutex<SessionConfiguration>> = Arc::new(Mutex::new(SessionConfiguration::default()));
    let control_slot: Arc<Mutex<Option<Arc<dyn RunControl>>>> = Arc::new(Mutex::new(None));

    let session_cb = Arc::clone(&session_slot);
    let control_cb = Arc::clone(&control_slot);
    let steer = steer_message.map(ToOwned::to_owned);
    let mut events = RunEvents::new(
        move |id| {
            let mut guard = session_cb.lock().unwrap();
            if guard.as_deref() == Some(id.as_str()) {
                return;
            }
            *guard = Some(id);
            drop(guard);
            if let Some(msg) = steer.clone() {
                let ctrl = Arc::clone(&control_cb);
                std::thread::spawn(move || {
                    std::thread::sleep(Duration::from_secs(4));
                    if let Some(c) = ctrl.lock().unwrap().clone() {
                        c.send(&msg);
                    }
                });
            }
        },
        move |outcome| {
            let _ = done_tx.send(outcome);
        },
    );
    let config_cb = Arc::clone(&config_slot);
    events.configuration = Arc::new(move |cfg| {
        *config_cb.lock().unwrap() = cfg;
    });

    let control = ProcessLauncher::new()
        .launch(spec, events)
        .expect("launch live harness");
    *control_slot.lock().unwrap() = Some(Arc::clone(&control));

    let outcome = done_rx
        .recv_timeout(Duration::from_secs(270))
        .expect("live run finished within timeout");
    let log_text = fs::read_to_string(&log_path).unwrap_or_default();
    let mut reader = TranscriptReader::default();
    let snapshot = reader.read(&log_path, harness == Harness::Shell, true);
    assert!(
        snapshot.problem.is_none(),
        "transcript problem for {}: {:?}\n{log_text}",
        harness.as_str(),
        snapshot.problem
    );
    assert_eq!(snapshot.structured, harness != Harness::Shell);

    let configuration = config_slot.lock().unwrap().clone();
    if harness.is_agent() && outcome == RunOutcome::Succeeded {
        assert!(
            configuration.model.is_some(),
            "{} must report its resolved session model",
            harness.as_str()
        );
        assert!(
            configuration.effort.is_some(),
            "{} must report its resolved effort",
            harness.as_str()
        );
        if let Some(expected_effort) = effort {
            assert_eq!(
                configuration.effort.as_deref(),
                Some(expected_effort),
                "{}",
                harness.as_str()
            );
        }
    }
    if harness.is_agent() {
        assert!(
            snapshot
                .items
                .iter()
                .any(|item| item.kind == TranscriptItemKind::User && item.text == prompt),
            "missing user prompt in {} snapshot: {:?}",
            harness.as_str(),
            snapshot.items
        );
    }

    let session = session_slot.lock().unwrap().clone();
    LiveRunResult {
        outcome,
        log_path,
        log_text,
        session,
    }
}

fn check_tool_output(harness: Harness, model: Option<&str>, effort: Option<&str>) {
    let dir = TempDir::new(&format!("rota-live-{}", harness.as_str()));
    let proof = format!("ROTA-TOOL-{}", Uuid::new_v4());
    let prompt = format!(
        "Use a shell tool to run exactly: printf '{proof}'. \
         Then reply with the single word Checked, without punctuation. Do not change files or use other tools."
    );
    let res = run_live(dir.path(), harness, &prompt, None, model, effort, None);
    assert_eq!(res.outcome, RunOutcome::Succeeded, "{}", res.log_text);
    let mut reader = TranscriptReader::default();
    let items = reader.read(&res.log_path, false, true).items;
    assert!(
        items.iter().any(|i| i.kind == TranscriptItemKind::Tool),
        "missing tool item for {}:\n{}",
        harness.as_str(),
        res.log_text
    );
    assert!(
        items
            .iter()
            .any(|i| i.kind == TranscriptItemKind::Output && i.text.contains(&proof)),
        "missing tool output proof {proof} for {}:\n{}",
        harness.as_str(),
        res.log_text
    );
    assert!(
        items
            .iter()
            .any(|i| i.kind == TranscriptItemKind::Agent && i.text.trim() == "Checked"),
        "missing Checked agent reply for {}:\n{}",
        harness.as_str(),
        res.log_text
    );
}

#[test]
#[ignore]
fn live_shell_session_runs_and_records_output() {
    if !live_enabled() {
        return;
    }
    let dir = TempDir::new("rota-live-shell");
    let proof = format!("ROTA-SHELL-{}", Uuid::new_v4());
    let res = run_live(
        dir.path(),
        Harness::Shell,
        &format!("printf '{proof}\\n'"),
        None,
        None,
        None,
        None,
    );
    assert_eq!(res.outcome, RunOutcome::Succeeded, "{}", res.log_text);
    assert!(res.log_text.contains(&proof), "{}", res.log_text);
}

#[test]
#[ignore]
fn live_agent_sessions_preserve_tool_output_separately_from_answer() {
    if !live_enabled() {
        return;
    }
    check_tool_output(Harness::Claude, Some("haiku"), Some("low"));
    check_tool_output(Harness::Codex, None, None);
    check_tool_output(Harness::Grok, None, None);
    check_tool_output(Harness::Antigravity, None, None);
}

#[test]
#[ignore]
fn live_codex_takes_message_mid_turn() {
    if !live_enabled() {
        return;
    }
    let dir = TempDir::new("rota-live-codex-steer");
    let steerable = "Run the shell command `sleep 12; echo first`. When it is done, reply with exactly \
                     the phrase a later user message gives you, or with the word done if there is none.";
    let res = run_live(
        dir.path(),
        Harness::Codex,
        steerable,
        Some("Reply with exactly: purple otter"),
        None,
        None,
        None,
    );
    assert_eq!(res.outcome, RunOutcome::Succeeded, "{}", res.log_text);
    assert!(res.session.is_some());
    assert!(
        res.log_text.contains("[you] Reply with exactly: purple otter"),
        "{}",
        res.log_text
    );
    let lower = res.log_text.to_ascii_lowercase();
    assert!(
        lower.contains("purple otter\n") || lower.ends_with("purple otter"),
        "{}",
        res.log_text
    );
}
