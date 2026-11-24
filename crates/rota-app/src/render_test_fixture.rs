//! Synthetic scheduler/history test fixture for headless GPU render tests.

use std::path::PathBuf;
use std::sync::Arc;

use jiff::Timestamp;
use rota_core::Scheduler;
use rota_core::model::{
    AgentQuestion, Harness, QuestionField, QuestionFieldKind, QuestionOption, Routine, RunOutcome, RunRecord,
    RunTrigger,
};
use rota_core::storage::{RunHistory, StorageLocation};
use rota_platform::MemoryPreferences;
use rota_ui::Appearance;
use uuid::Uuid;

use crate::app_state::AppState;
use crate::settings_store::SettingsStore;

pub(crate) struct TestFixture {
    pub dir: PathBuf,
    pub state: AppState,
    pub _control: rota_core::ControlServerHandle,
    pub session_review_id: Uuid,
    pub session_question_id: Uuid,
}

impl Drop for TestFixture {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.dir);
    }
}

pub(crate) fn make_fixture(appearance: Appearance) -> TestFixture {
    let short_id = (Uuid::new_v4().as_u128() & 0xffff_ffff) as u32;
    let dir = PathBuf::from(format!("/tmp/rt-app-{short_id:08x}"));
    let loc = StorageLocation::new(dir.join("d"), dir.join("l"));
    std::fs::create_dir_all(&loc.root).expect("create test root");
    std::fs::create_dir_all(&loc.logs).expect("create test logs");
    let proj_dir = dir.join("project");
    std::fs::create_dir_all(&proj_dir).expect("create project dir");

    let (scheduler, control) = Scheduler::start_standard(loc.clone(), None).expect("start test scheduler");

    let now = Timestamp::now();
    let mut r1 = Routine::new(
        "daily-review",
        "Daily code review",
        proj_dir.to_string_lossy().into_owned(),
        "0 9 * * 1-5",
        Harness::Claude,
        true,
        "Review recent changes and summarize findings.",
    );
    r1.model = Some("claude-sonnet-4-6".to_string());
    r1.effort = Some("high".to_string());
    r1.next_fire = Timestamp::from_second(now.as_second() + 3600).ok();
    scheduler.create_routine(r1).expect("create r1");

    let mut r2 = Routine::new(
        "weekly-report",
        "Weekly project report",
        proj_dir.to_string_lossy().into_owned(),
        "0 16 * * 5",
        Harness::Codex,
        false,
        "Prepare a short weekly report.",
    );
    r2.model = Some("gpt-5-codex".to_string());
    r2.effort = Some("high".to_string());
    scheduler.create_routine(r2).expect("create r2");

    let history = RunHistory::new(loc.clone());
    let log1 = loc.logs.join("daily-review").join("run1.log");
    std::fs::create_dir_all(log1.parent().unwrap()).unwrap();
    std::fs::write(
        &log1,
        concat!(
            "[you] Review recent changes.\n",
            "[reasoning] Checking modified crates and test coverage.\n",
            "-> Read crates/rota-app/src/main.rs\n",
            "## Morning review\n\n",
            "- **Tests:** all checks passed.\n",
            "- **Latency:** 120 Hz frame pacing verified.\n\n",
            "See [build report](https://example.com/report) for details.\n\n",
            "| Crate | Status | Coverage |\n",
            "| :--- | :---: | ---: |\n",
            "| `rota-ui` | Ready | 98% |\n",
            "| `rota-app` | Ready | 96% |\n\n",
            "```rust\nfn frame_budget_ms() -> f32 { 8.33 }\n```\n",
        ),
    )
    .unwrap();

    let mut rec1 = RunRecord::new(
        "daily-review",
        RunTrigger::Scheduled,
        Harness::Claude,
        Timestamp::from_second(now.as_second() - 300).unwrap(),
        RunOutcome::Succeeded,
    );
    rec1.ended_at = Some(Timestamp::from_second(now.as_second() - 220).unwrap());
    rec1.log_path = Some(log1.to_string_lossy().into_owned());
    rec1.session_id = Some("demo-claude-1".to_string());
    rec1.reported_model = Some("claude-sonnet-4-6".to_string());
    rec1.reported_effort = Some("high".to_string());
    history.upsert(&rec1).unwrap();

    let log2 = loc.logs.join("weekly-report").join("run2.log");
    std::fs::create_dir_all(log2.parent().unwrap()).unwrap();
    std::fs::write(
        &log2,
        "[you] Prepare weekly report.\n## This week\nWhich format should the report use?\n",
    )
    .unwrap();

    let mut q = AgentQuestion::new("Choose the report format");
    q.id = "report-format".to_string();
    q.allows_decline = Some(true);
    q.context = Some("Tool: ask_question(format)".to_string());
    q.fields = vec![QuestionField {
        id: "format".to_string(),
        title: "How should the weekly report be prepared?".to_string(),
        detail: "Pick a summary style for stakeholders.".to_string(),
        kind: QuestionFieldKind::Choice,
        options: vec![
            QuestionOption::new("short", "Short summary (Recommended)"),
            QuestionOption::new("detailed", "Detailed report with links"),
        ],
        required: true,
        allows_other: true,
        schema: None,
    }];

    let mut rec2 = RunRecord::new(
        "weekly-report",
        RunTrigger::Scheduled,
        Harness::Codex,
        Timestamp::from_second(now.as_second() - 120).unwrap(),
        RunOutcome::Succeeded,
    );
    rec2.ended_at = Some(Timestamp::from_second(now.as_second() - 60).unwrap());
    rec2.log_path = Some(log2.to_string_lossy().into_owned());
    rec2.session_id = Some("demo-codex-2".to_string());
    rec2.attention = Some("Choose a format for the weekly report.".to_string());
    rec2.questions = Some(vec![q]);
    history.upsert(&rec2).unwrap();

    drop(scheduler);
    drop(control);
    let (scheduler, control) =
        Scheduler::start_standard(loc, None).expect("restart test scheduler with seeded runs");

    let prefs: Arc<dyn rota_platform::PreferencesStore> = MemoryPreferences::new();
    let settings = SettingsStore::load(prefs);
    let state = AppState::new(scheduler, settings, Some(appearance));

    TestFixture {
        dir,
        state,
        _control: control,
        session_review_id: rec1.id,
        session_question_id: rec2.id,
    }
}
