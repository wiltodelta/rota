use std::path::PathBuf;

use jiff::Timestamp;
use rota_core::{
    AgentQuestion, AttachmentError, ChatAttachmentStore, ClaudeDesktopImport, Harness, HistoryDeletionError,
    ImportCandidate, ImportSource, Routine, RoutineImport, RoutineStore, RunHistory, RunOutcome, RunRecord,
    RunTrigger, StorageLocation,
};
use uuid::Uuid;

struct TempDir(PathBuf);

impl TempDir {
    fn new() -> Self {
        let dir = std::env::temp_dir().join(format!("rota-storage-test-{}", Uuid::new_v4()));
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

#[test]
fn routine_store_roundtrips_and_migrates_legacy_timeout() {
    let tmp = TempDir::new();
    let store = RoutineStore::new(tmp.location());
    assert!(store.load().unwrap().is_empty());

    let legacy_json = r#"[
        {
            "id": "legacy-default",
            "name": "Legacy 60",
            "workingDirectory": "/tmp",
            "schedule": "0 9 * * *",
            "harness": "claude",
            "enabled": false,
            "prompt": "hi",
            "timeoutMinutes": 60
        },
        {
            "id": "legacy-custom",
            "name": "Legacy 25",
            "workingDirectory": "/tmp",
            "schedule": "0 9 * * *",
            "harness": "claude",
            "enabled": false,
            "prompt": "hi",
            "timeoutMinutes": 25
        }
    ]"#;
    std::fs::create_dir_all(tmp.location().root).unwrap();
    std::fs::write(tmp.location().routines_file(), legacy_json).unwrap();
    let loaded = store.load().unwrap();
    assert_eq!(loaded.len(), 2);
    assert_eq!(loaded[0].time_limit_minutes, None);
    assert_eq!(loaded[1].time_limit_minutes, Some(25));

    store.save(&loaded).unwrap();
    assert_eq!(store.load().unwrap(), loaded);
}

#[test]
fn history_retains_running_and_questions_and_separates_skips_from_sessions() {
    let tmp = TempDir::new();
    let history = RunHistory::new(tmp.location());
    let base_secs = 1_790_000_000i64;

    let mut running = RunRecord::new(
        "digest",
        RunTrigger::Manual,
        Harness::Codex,
        Timestamp::from_second(base_secs).unwrap(),
        RunOutcome::Running,
    );
    let running_log = history.log_file(&running);
    std::fs::create_dir_all(running_log.parent().unwrap()).unwrap();
    std::fs::write(&running_log, "still running").unwrap();
    running.log_path = Some(running_log.to_string_lossy().into_owned());
    history.upsert(&running).unwrap();

    // Add 55 finished sessions and 55 skips: skips must never displace sessions, and running stays.
    let mut oldest_dropped_log = None;
    for i in 1..=55 {
        let t = Timestamp::from_second(base_secs + i * 60).unwrap();
        let mut sess = RunRecord::new(
            "digest",
            RunTrigger::Scheduled,
            Harness::Codex,
            t,
            RunOutcome::Succeeded,
        );
        sess.ended_at = Some(t);
        let log = history.log_file(&sess);
        std::fs::create_dir_all(log.parent().unwrap()).unwrap();
        std::fs::write(&log, format!("log {i}")).unwrap();
        if i == 1 {
            oldest_dropped_log = Some(log.clone());
        }
        sess.log_path = Some(log.to_string_lossy().into_owned());
        history.upsert(&sess).unwrap();

        let mut skip = RunRecord::new(
            "digest",
            RunTrigger::Scheduled,
            Harness::Codex,
            t,
            RunOutcome::Skipped("busy".into()),
        );
        skip.ended_at = Some(t);
        history.upsert(&skip).unwrap();
    }

    let kept = history.records("digest");
    assert_eq!(
        kept.iter().filter(|r| r.outcome == RunOutcome::Running).count(),
        1
    );
    assert_eq!(
        kept.iter()
            .filter(|r| !r.is_skip() && r.outcome != RunOutcome::Running)
            .count(),
        RunHistory::LIMIT
    );
    assert_eq!(
        kept.iter().filter(|r| r.is_skip()).count(),
        RunHistory::SKIP_LIMIT
    );
    assert!(running_log.exists(), "running session log is never evicted");
    assert!(
        !oldest_dropped_log.unwrap().exists(),
        "evicted session log is cleaned up"
    );
}

#[test]
fn close_orphans_marks_interrupted_and_handles_blocking_vs_async_questions() {
    let tmp = TempDir::new();
    let history = RunHistory::new(tmp.location());
    let started = Timestamp::from_second(1_790_000_000).unwrap();
    let now = Timestamp::from_second(1_790_000_600).unwrap();

    let mut blocking_rec = RunRecord::new(
        "r1",
        RunTrigger::Scheduled,
        Harness::Claude,
        started,
        RunOutcome::Running,
    );
    blocking_rec.questions = Some(vec![AgentQuestion::new("Approve command?")]);
    history.upsert(&blocking_rec).unwrap();

    let mut async_rec = RunRecord::new(
        "r1",
        RunTrigger::Scheduled,
        Harness::Antigravity,
        started,
        RunOutcome::Running,
    );
    let mut async_q = AgentQuestion::new("Async choice");
    async_q.reply_via_message = Some(true);
    async_rec.questions = Some(vec![async_q.clone()]);
    history.upsert(&async_rec).unwrap();

    let closed = history.close_orphans(&["r1".to_string()], now);
    assert_eq!(closed.len(), 2);

    let stored = history.records("r1");
    let b = stored.iter().find(|r| r.id == blocking_rec.id).unwrap();
    assert_eq!(b.outcome, RunOutcome::Interrupted);
    assert!(b.questions.as_ref().is_none_or(Vec::is_empty));
    assert!(
        b.attention
            .as_deref()
            .unwrap_or("")
            .contains("interrupted while waiting")
    );

    let a = stored.iter().find(|r| r.id == async_rec.id).unwrap();
    assert_eq!(a.outcome, RunOutcome::Interrupted);
    assert_eq!(a.questions.as_deref(), Some(&[async_q][..]));
    assert_eq!(a.attention.as_deref(), Some("Async choice"));
}

#[test]
fn symlink_and_foreign_log_protections_prevent_unsafe_deletions_and_attachments() {
    let tmp = TempDir::new();
    let loc = tmp.location();
    let history = RunHistory::new(loc.clone());

    let outside = tmp.0.join("outside.log");
    std::fs::write(&outside, "precious").unwrap();

    let mut foreign = RunRecord::new(
        "digest",
        RunTrigger::Manual,
        Harness::Shell,
        Timestamp::now(),
        RunOutcome::Succeeded,
    );
    foreign.ended_at = Some(Timestamp::now());
    foreign.log_path = Some(outside.to_string_lossy().into_owned());
    history.upsert(&foreign).unwrap();

    assert_eq!(
        history.remove(foreign.id, "digest"),
        Err(HistoryDeletionError::ForeignLog)
    );
    assert!(outside.exists());

    // Symlinked routine directory under logs must be rejected.
    std::fs::create_dir_all(&loc.logs).unwrap();
    let ext_dir = tmp.0.join("external-dir");
    std::fs::create_dir_all(&ext_dir).unwrap();
    let victim = ext_dir.join("victim.log");
    std::fs::write(&victim, "keep me").unwrap();
    std::os::unix::fs::symlink(&ext_dir, loc.logs.join("symlinked")).unwrap();

    assert_eq!(
        history.owned_log(
            &loc.logs.join("symlinked/victim.log").to_string_lossy(),
            "symlinked"
        ),
        Err(HistoryDeletionError::ForeignLog)
    );
    assert!(victim.exists());

    // Attachment staging copies regular files and refuses symlinked `.attachments` folders.
    let valid_log = loc.logs.join("digest/run.log");
    std::fs::create_dir_all(valid_log.parent().unwrap()).unwrap();
    std::fs::write(&valid_log, "ok").unwrap();
    let src_file = tmp.0.join("note.txt");
    std::fs::write(&src_file, "hello").unwrap();

    let att_store = ChatAttachmentStore::new(&valid_log);
    let staged = att_store.stage(std::slice::from_ref(&src_file)).unwrap();
    assert_eq!(staged.len(), 1);
    assert_eq!(std::fs::read_to_string(&staged[0].path).unwrap(), "hello");
    att_store.discard(&staged[0]).unwrap();
    assert!(!PathBuf::from(&staged[0].path).exists());
    assert!(src_file.exists());

    let _ = std::fs::remove_dir_all(&att_store.folder);
    std::os::unix::fs::symlink(&ext_dir, &att_store.folder).unwrap();
    assert_eq!(att_store.stage(&[src_file]), Err(AttachmentError::UnsafeFolder));
}

#[test]
fn claude_desktop_import_and_deduplication_start_disabled() {
    let tmp = TempDir::new();
    let stub = tmp.0.join("weekly.md");
    std::fs::write(&stub, "---\nname: Weekly\n---\n\nRun the weekly check.\n").unwrap();

    let session_dir = tmp
        .0
        .join("Library/Application Support/Claude/claude-code-sessions/s1");
    std::fs::create_dir_all(&session_dir).unwrap();
    let tasks_file = session_dir.join("scheduled-tasks.json");
    let json = serde_json::json!({
        "scheduledTasks": [{
            "id": "weekly",
            "displayName": "Weekly Check",
            "cronExpression": "0 9 * * 1",
            "enabled": true,
            "filePath": stub.to_string_lossy(),
            "cwd": tmp.0.to_string_lossy(),
        }]
    });
    std::fs::write(&tasks_file, serde_json::to_vec(&json).unwrap()).unwrap();

    let located = ClaudeDesktopImport::locate(&tmp.0).unwrap();
    assert_eq!(located, tasks_file);
    let candidates = ClaudeDesktopImport::candidates(&located).unwrap();
    assert_eq!(candidates.len(), 1);
    assert!(candidates[0].on_in_source);
    assert!(!candidates[0].routine.enabled, "imports always start disabled");
    assert_eq!(candidates[0].routine.prompt, "Run the weekly check.");

    let existing = vec![Routine::new(
        "weekly",
        "Existing",
        "/other",
        "0 8 * * *",
        Harness::Shell,
        true,
        "echo 1",
    )];
    let imported = RoutineImport::routine_to_import(&candidates[0], &existing).unwrap();
    assert_eq!(imported.id, "weekly-2");
    assert!(!imported.enabled);

    let dup_candidate = ImportCandidate::new(
        imported.clone(),
        ImportSource::ClaudeDesktop,
        true,
        None,
        Some("weekly"),
    );
    assert!(RoutineImport::is_imported(&dup_candidate, &[imported]));
}
