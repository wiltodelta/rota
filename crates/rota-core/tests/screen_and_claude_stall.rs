use std::collections::HashMap;
use std::sync::{Arc, Mutex};

use rota_core::{
    ClaudeInteractiveRun, LaunchMode, LaunchSpec, NetworkFailure, RunEvents, RunJournal, RunOutcome,
    ScreenRun,
};
use rota_platform::OwnedProcess;
use serde_json::{Value, json};
use uuid::Uuid;

#[test]
fn network_failure_matches_claude_lost_stream_phrases() {
    for text in [
        "API Error: Can't reach the API server — check your internet or DNS (ENOTFOUND)",
        "API Error: Connection closed mid-response. The response above may be incomplete.",
        "API Error: Connection lost while your computer was asleep",
        "API Error: The response stopped arriving. The response above may be incomplete.",
        "API Error: Response stalled mid-stream. The response above may be incomplete.",
    ] {
        assert!(NetworkFailure::matches(text), "expected match for: {text}");
    }
    assert!(!NetworkFailure::matches(
        "You've hit your weekly limit · resets 10pm (America/Los_Angeles)"
    ));
    assert!(!NetworkFailure::matches("The test operation timed out"));
    assert!(!NetworkFailure::matches("API error: quota exceeded"));
    assert!(!NetworkFailure::matches("API error: unauthorized"));
}

#[test]
fn screen_pids_list_all_matching_sessions() {
    let list = "There are screens on:\n\
        \t63754.rota-claude-060c03c9\t(Detached)\n\
        \t811.rota-claude-060c03c9x\t(Detached)\n\
        2 Sockets in /tmp/.screen.\n";
    assert_eq!(ScreenRun::pid_in_list("rota-claude-060c03c9", list), Some(63754));
    assert_eq!(ScreenRun::pid_in_list("rota-claude-ffffffff", list), None);
    let twice = format!("{list}\t88674.rota-claude-060c03c9\t(Detached)\n");
    assert_eq!(
        ScreenRun::pids_in_list("rota-claude-060c03c9", &twice),
        vec![63754, 88674]
    );
}

#[test]
fn screen_terminate_ends_every_screen_under_duplicate_name() {
    let short = &Uuid::new_v4().simple().to_string()[..8];
    let name = format!("rota-test-{short}");
    let script = std::env::temp_dir().join(format!("{name}.zsh"));
    std::fs::write(&script, "sleep 60\n").expect("write sleep script");
    let tmp_str = std::env::temp_dir().to_string_lossy().into_owned();
    for _ in 0..2 {
        ScreenRun::launch_detached(&name, &script, &tmp_str, &HashMap::new(), false)
            .expect("launch detached screen");
    }

    let roots: Vec<OwnedProcess> = ScreenRun::pids_in_list(&name, &ScreenRun::list(&name))
        .into_iter()
        .filter_map(OwnedProcess::capture)
        .collect();
    assert_eq!(roots.len(), 2);

    let mut sleeps: Vec<OwnedProcess> = Vec::new();
    for _ in 0..50 {
        if sleeps.len() >= 4 {
            break;
        }
        std::thread::sleep(std::time::Duration::from_millis(20));
        sleeps = roots.iter().flat_map(OwnedProcess::descendants).collect();
    }
    let ambiguous = ScreenRun::command(&name, &["-X", "select", "0"]);
    let terminated = ScreenRun::terminate(&name);
    let _ = std::fs::remove_file(&script);
    for p in roots.iter().chain(sleeps.iter()) {
        p.signal(libc::SIGKILL);
    }

    assert_eq!(
        sleeps.len(),
        4,
        "zsh and sleep under each screen, past the root-owned login"
    );
    assert_ne!(ambiguous, 0, "screen refuses an ambiguous name");
    assert_eq!(terminated, 2);
    assert!(!ScreenRun::alive(&name));
    assert!(!roots.iter().chain(sleeps.iter()).any(OwnedProcess::exists));
}

#[test]
fn claude_interactive_api_error_followed_by_silence_ends_turn() {
    let folder = std::env::temp_dir().join(format!("rota-stall-{}", Uuid::new_v4()));
    std::fs::create_dir_all(&folder).expect("create stall dir");
    let log = folder.join("session.log");
    std::fs::write(&log, b"").expect("create log");

    let spec = LaunchSpec {
        executable: "/bin/false".into(),
        prompt: "Work".into(),
        arguments: Vec::new(),
        working_directory: folder.to_string_lossy().into_owned(),
        environment: HashMap::new(),
        mode: LaunchMode::ClaudeInteractive,
        timeout_secs: None,
        log: log.clone(),
        resume: None,
        model: None,
        effort: None,
        notice: None,
        terminal_transcript: None,
        adopt: false,
    };
    let log_file = std::fs::OpenOptions::new()
        .write(true)
        .open(&log)
        .expect("open log");
    let journal = RunJournal::new(log_file, RunEvents::new(|_| {}, |_| {}), None, None);
    let clock = Arc::new(Mutex::new(1000.0f64));
    let clock_read = Arc::clone(&clock);
    let run = ClaudeInteractiveRun::new_for_test(
        spec,
        Arc::clone(&journal),
        "synthetic",
        &folder,
        Arc::new(move || *clock_read.lock().unwrap()),
    );

    let write = |val: Value| {
        let bytes = serde_json::to_vec(&val).unwrap();
        run.handle_entry(&bytes);
    };
    let error = json!({
        "type": "assistant",
        "isApiErrorMessage": true,
        "message": {
            "model": "<synthetic>",
            "content": [{"type": "text", "text": "API Error: The response stopped arriving."}]
        }
    });
    let reply = json!({
        "type": "assistant",
        "message": {
            "model": "claude-opus-5-5",
            "content": [{"type": "text", "text": "Done."}]
        }
    });

    write(reply.clone());
    write(error.clone());
    write(json!({"type": "file-history-snapshot"}));
    *clock.lock().unwrap() += ClaudeInteractiveRun::STALL_GRACE_SECS - 1.0;
    assert!(!run.ready_to_exit(), "Claude may still go on by itself");
    *clock.lock().unwrap() += 1.0;
    assert!(run.ready_to_exit());

    write(json!({
        "type": "user",
        "toolUseResult": {"backgroundTaskId": "b1"},
        "message": {"content": [{"type": "tool_result", "content": "running"}]}
    }));
    *clock.lock().unwrap() += ClaudeInteractiveRun::STALL_GRACE_SECS;
    assert!(
        !run.ready_to_exit(),
        "a background task wakes Claude when it finishes"
    );

    write(error.clone());
    write(json!({"type": "user", "toolUseResult": {"task_id": "b1", "task_type": "local_bash"}}));
    write(error);
    *clock.lock().unwrap() += ClaudeInteractiveRun::STALL_GRACE_SECS * 0.5;
    write(json!({
        "type": "user",
        "message": {"content": [{"type": "tool_result", "content": "ok"}]}
    }));
    *clock.lock().unwrap() += ClaudeInteractiveRun::STALL_GRACE_SECS * 0.5;
    assert!(!run.ready_to_exit(), "a tool result restarts the silence");
    write(reply);
    *clock.lock().unwrap() += ClaudeInteractiveRun::STALL_GRACE_SECS;
    assert!(!run.ready_to_exit(), "Claude went on, and its turn has not ended");

    journal.finish(RunOutcome::Cancelled);
    let _ = std::fs::remove_dir_all(&folder);
}
