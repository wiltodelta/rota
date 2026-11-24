use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};

use jiff::Timestamp;
use jiff::tz::TimeZone;
use rota_core::{
    AgentQuestion, Harness, LaunchError, LaunchMode, LaunchSpec, QuestionAnswer, QuestionField,
    QuestionFieldKind, QuestionOption, Routine, RoutineLaunching, RunControl, RunEvents, RunOutcome,
    RunRecord, RunTrigger, Scheduler, SchedulerNotifier, SessionConfiguration, StorageLocation,
    TerminalState,
};
use rota_platform::NotificationPayload;
use uuid::Uuid;

struct TempDir(PathBuf);

impl TempDir {
    fn new() -> Self {
        let dir = std::env::temp_dir().join(format!("rota-sched-test-{}", Uuid::new_v4()));
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
struct FakeControl {
    stopped: Mutex<bool>,
    sent: Mutex<Vec<String>>,
    attach: Option<Vec<String>>,
}

impl RunControl for FakeControl {
    fn stop(&self) {
        *self.stopped.lock().unwrap() = true;
    }

    fn send(&self, message: &str) {
        self.sent.lock().unwrap().push(message.to_string());
    }

    fn attach_command(&self) -> Option<Vec<String>> {
        self.attach.clone()
    }
}

#[derive(Default)]
struct FakeLauncher {
    specs: Mutex<Vec<LaunchSpec>>,
    events: Mutex<Vec<RunEvents>>,
    controls: Mutex<Vec<Arc<FakeControl>>>,
    fail_with: Mutex<Option<String>>,
    finish_during_launch: Mutex<Option<RunOutcome>>,
}

impl RoutineLaunching for FakeLauncher {
    fn launch(&self, spec: LaunchSpec, events: RunEvents) -> Result<Arc<dyn RunControl>, LaunchError> {
        let attach = matches!(spec.mode, LaunchMode::Terminal(_)).then(|| {
            vec![
                "/usr/bin/screen".to_string(),
                "-x".to_string(),
                "fake".to_string(),
            ]
        });
        self.specs.lock().unwrap().push(spec);
        if let Some(msg) = self.fail_with.lock().unwrap().clone() {
            return Err(LaunchError::Message(msg));
        }
        if let Some(outcome) = self.finish_during_launch.lock().unwrap().clone() {
            (events.finished)(outcome);
        }
        self.events.lock().unwrap().push(events);
        let ctrl = Arc::new(FakeControl {
            attach,
            ..FakeControl::default()
        });
        self.controls.lock().unwrap().push(Arc::clone(&ctrl));
        Ok(ctrl)
    }
}

#[derive(Default)]
struct RecordingNotifier {
    payloads: Mutex<Vec<NotificationPayload>>,
    paused: Mutex<Vec<(String, usize)>>,
}

impl SchedulerNotifier for RecordingNotifier {
    fn notify(&self, payload: NotificationPayload) {
        self.payloads.lock().unwrap().push(payload);
    }

    fn routine_paused(&self, routine: &Routine, failures: usize) {
        self.paused.lock().unwrap().push((routine.id.clone(), failures));
    }
}

type TestHarness = (
    TempDir,
    Arc<Scheduler>,
    Arc<FakeLauncher>,
    Arc<RecordingNotifier>,
    Arc<Mutex<Timestamp>>,
);

fn setup() -> TestHarness {
    let tmp = TempDir::new();
    let proj = tmp.0.join("project");
    std::fs::create_dir_all(&proj).unwrap();
    let launcher = Arc::new(FakeLauncher::default());
    let notifier = Arc::new(RecordingNotifier::default());
    let clock = Arc::new(Mutex::new("2026-10-09T09:00:00Z".parse::<Timestamp>().unwrap()));
    let sched = Scheduler::new(tmp.location(), launcher.clone(), Some(notifier.clone())).unwrap();
    sched.set_time_zone(TimeZone::UTC);
    let clock_ref = Arc::clone(&clock);
    sched.set_clock(Arc::new(move || *clock_ref.lock().unwrap()));
    sched.set_service_probe_sync(|_| true);
    sched.set_session_alive(Arc::new(|_| false));
    (tmp, sched, launcher, notifier, clock)
}

#[test]
fn tick_runs_scheduled_catches_up_skips_expired_and_pauses_after_five_failures() {
    let (tmp, sched, launcher, notifier, clock) = setup();
    let proj = tmp.0.join("project").to_string_lossy().into_owned();
    let r = sched
        .create_routine(Routine::new(
            "hourly",
            "Hourly",
            &proj,
            "0 * * * *",
            Harness::Codex,
            true,
            "Check",
        ))
        .unwrap();
    assert_eq!(
        r.next_fire,
        Some("2026-10-09T10:00:00Z".parse::<Timestamp>().unwrap())
    );

    // Advance 3 hours -> late within grace -> CatchUp trigger.
    *clock.lock().unwrap() = "2026-10-09T13:00:00Z".parse().unwrap();
    let rev_before = sched.revision();
    sched.tick();
    assert!(sched.revision() > rev_before);
    assert_eq!(launcher.specs.lock().unwrap().len(), 1);
    assert_eq!(
        sched.active_record("hourly").unwrap().trigger,
        RunTrigger::CatchUp
    );

    // Next hour while previous run is still active -> Skipped without launching a second run.
    *clock.lock().unwrap() = "2026-10-09T14:00:00Z".parse().unwrap();
    sched.tick();
    assert_eq!(launcher.specs.lock().unwrap().len(), 1);
    assert!(sched.records_for("hourly").iter().any(RunRecord::is_skip));

    // Finish first failure, then fail 4 more scheduled runs -> auto-pauses at 5 consecutive failures!
    (launcher.events.lock().unwrap()[0].finished)(RunOutcome::Failed { exit_code: 1 });
    for hour in 15..19 {
        *clock.lock().unwrap() = format!("2026-10-09T{hour:02}:00:00Z").parse().unwrap();
        sched.tick();
        let idx = launcher.events.lock().unwrap().len() - 1;
        (launcher.events.lock().unwrap()[idx].finished)(RunOutcome::Failed { exit_code: 1 });
    }
    assert!(!sched.routine("hourly").unwrap().enabled);
    assert_eq!(*notifier.paused.lock().unwrap(), vec![("hourly".to_string(), 5)]);

    // Re-enable and jump > 7 days -> missed slot is Skipped, not CatchUp.
    sched.set_enabled("hourly", true).unwrap();
    *clock.lock().unwrap() = "2026-10-20T00:00:00Z".parse().unwrap();
    let count_before = launcher.specs.lock().unwrap().len();
    sched.tick();
    assert_eq!(launcher.specs.lock().unwrap().len(), count_before);
}

#[test]
fn questions_parallel_sessions_unread_counts_and_synchronous_completion() {
    let (tmp, sched, launcher, _notifier, clock) = setup();
    let proj = tmp.0.join("project").to_string_lossy().into_owned();
    sched
        .create_routine(Routine::new(
            "agent",
            "Agent",
            &proj,
            "0 9 * * *",
            Harness::Codex,
            false,
            "Work",
        ))
        .unwrap();

    // Start older session, attach native session id, ask a blocking question, validate and answer.
    let older = sched.run_now("agent").unwrap();
    (launcher.events.lock().unwrap()[0].session)("native-1".to_string());

    let mut field = QuestionField::new("env", "Environment");
    field.kind = QuestionFieldKind::Choice;
    field.options = vec![QuestionOption::new("staging", "Staging")];
    field.allows_other = false;
    let mut q = AgentQuestion::new("Deploy target");
    q.id = "q-deploy".to_string();
    q.fields = vec![field];

    let answered = Arc::new(Mutex::new(Vec::new()));
    let ans_clone = Arc::clone(&answered);
    (launcher.events.lock().unwrap()[0].question)(
        q,
        Arc::new(move |ans| ans_clone.lock().unwrap().push(ans)),
    );
    assert_eq!(sched.unread_and_attention_counts(), (0, 1));
    assert!(sched.dismiss_attention(older.id).is_err());
    assert!(sched.send_message(older.id, "hi", &[]).is_err());

    let mut bad_vals = HashMap::new();
    bad_vals.insert("env".into(), vec!["prod".into()]);
    assert!(
        sched
            .answer_question(older.id, "q-deploy", QuestionAnswer::new("accept", bad_vals))
            .is_err()
    );

    let mut ok_vals = HashMap::new();
    ok_vals.insert("env".into(), vec!["staging".into()]);
    sched
        .answer_question(older.id, "q-deploy", QuestionAnswer::new("accept", ok_vals))
        .unwrap();
    assert_eq!(answered.lock().unwrap().len(), 1);
    assert_eq!(sched.unread_and_attention_counts(), (0, 0));

    (launcher.events.lock().unwrap()[0].finished)(RunOutcome::Succeeded);
    assert_eq!(sched.unread_and_attention_counts(), (1, 0));
    sched.mark_read(older.id).unwrap();
    assert_eq!(sched.unread_and_attention_counts(), (0, 0));
    sched.mark_unread(older.id).unwrap();
    assert_eq!(sched.unread_and_attention_counts(), (1, 0));

    // Start newer session while continuing older session in parallel!
    *clock.lock().unwrap() = "2026-10-09T10:00:00Z".parse().unwrap();
    let newer = sched.run_now("agent").unwrap();
    (launcher.events.lock().unwrap()[1].session)("native-2".to_string());
    sched.send_message(older.id, "Continue older", &[]).unwrap();
    assert!(sched.is_session_active(older.id));
    assert!(sched.is_session_active(newer.id));
    (launcher.events.lock().unwrap()[1].configuration)(SessionConfiguration::new(
        Some("model-new".into()),
        None,
        None,
        None,
    ));
    (launcher.events.lock().unwrap()[2].configuration)(SessionConfiguration::new(
        Some("model-old".into()),
        None,
        None,
        None,
    ));
    assert_eq!(
        sched.current_record(newer.id).unwrap().reported_model.as_deref(),
        Some("model-new")
    );
    assert_eq!(
        sched.current_record(older.id).unwrap().reported_model.as_deref(),
        Some("model-old")
    );
    (launcher.events.lock().unwrap()[1].finished)(RunOutcome::Succeeded);
    (launcher.events.lock().unwrap()[2].finished)(RunOutcome::Succeeded);

    // Synchronous completion inside `launch` leaves nothing active.
    *launcher.finish_during_launch.lock().unwrap() = Some(RunOutcome::Succeeded);
    let sync_rec = sched.run_now("agent").unwrap();
    assert_eq!(sync_rec.outcome, RunOutcome::Succeeded);
    assert!(!sched.is_running("agent"));
}

#[test]
fn sleep_and_network_resilience_and_handoff_sessions() {
    let (tmp, sched, launcher, _notifier, _clock) = setup();
    let proj = tmp.0.join("project").to_string_lossy().into_owned();
    sched
        .create_routine(Routine::new(
            "resilient",
            "Resilient",
            &proj,
            "0 9 * * *",
            Harness::Claude,
            false,
            "Analyze",
        ))
        .unwrap();

    let rec = sched.run_now("resilient").unwrap();
    (launcher.events.lock().unwrap()[0].session)("claude-sess-1".to_string());
    let log_path = PathBuf::from(sched.current_record(rec.id).unwrap().log_path.unwrap());
    std::fs::create_dir_all(log_path.parent().unwrap()).unwrap();
    std::fs::write(&log_path, "[you] Analyze\nWorking...\n").unwrap();

    // Sleep cuts off the run -> auto-resumes up to RESUME_LIMIT (2), then stops.
    for expected_resumes in 1..=Scheduler::RESUME_LIMIT {
        sched.system_will_sleep();
        let finished = {
            let events = launcher.events.lock().unwrap();
            Arc::clone(&events.last().unwrap().finished)
        };
        finished(RunOutcome::Interrupted);
        assert_eq!(
            sched.current_record(rec.id).unwrap().resumes,
            Some(expected_resumes)
        );
    }
    sched.system_will_sleep();
    let finished = {
        let events = launcher.events.lock().unwrap();
        Arc::clone(&events.last().unwrap().finished)
    };
    finished(RunOutcome::Interrupted);
    assert!(!sched.is_running("resilient"), "stops at resume limit");

    // Restart finished Claude session onto Codex!
    let restarted = sched
        .restart_session(rec.id, Harness::Codex, Some("gpt-5".into()), None)
        .unwrap();
    assert_eq!(restarted.harness, Harness::Codex);
    assert_eq!(restarted.original_request.as_deref(), Some("Analyze"));
    let finished = {
        let events = launcher.events.lock().unwrap();
        Arc::clone(&events.last().unwrap().finished)
    };
    finished(RunOutcome::Succeeded);

    // Discuss a finished Shell session and open an agent session in Terminal via seam!
    sched
        .create_routine(Routine::new(
            "backup",
            "Backup",
            &proj,
            "0 9 * * *",
            Harness::Shell,
            false,
            "echo backup ok",
        ))
        .unwrap();
    let sh = sched.run_now("backup").unwrap();
    let sh_log = PathBuf::from(sched.current_record(sh.id).unwrap().log_path.unwrap());
    std::fs::create_dir_all(sh_log.parent().unwrap()).unwrap();
    std::fs::write(&sh_log, "[you] echo backup ok\nbackup ok\n").unwrap();
    let sh_finished = {
        let events = launcher.events.lock().unwrap();
        Arc::clone(&events.last().unwrap().finished)
    };
    sh_finished(RunOutcome::Succeeded);

    let disc = sched
        .discuss_shell_session(sh.id, Harness::Codex, "Why did it say ok?", None, None)
        .unwrap();
    assert_eq!(disc.discussed_session_id, Some(sh.id));
    assert_eq!(sched.discussions_of(sh.id).len(), 1);
    let (disc_sess, disc_fin) = {
        let events = launcher.events.lock().unwrap();
        let ev = events.last().unwrap();
        (Arc::clone(&ev.session), Arc::clone(&ev.finished))
    };
    disc_sess("codex-disc-1".to_string());
    disc_fin(RunOutcome::Succeeded);

    let fake_transcript = tmp.0.join("native.jsonl");
    std::fs::write(&fake_transcript, "").unwrap();
    sched.set_terminal_transcript(Arc::new(move |_, _| Some(fake_transcript.clone())));
    let opened_scripts = Arc::new(Mutex::new(Vec::new()));
    let opened_ref = Arc::clone(&opened_scripts);
    sched.set_terminal_opener(Arc::new(move |script, _| {
        opened_ref.lock().unwrap().push(script.to_path_buf());
        Ok(())
    }));
    sched.open_in_terminal(disc.id, None).unwrap();
    assert_eq!(opened_scripts.lock().unwrap().len(), 1);
    assert_eq!(
        sched.current_record(disc.id).unwrap().terminal_state,
        Some(TerminalState::Waiting)
    );
    assert_eq!(
        launcher.specs.lock().unwrap().last().unwrap().mode,
        LaunchMode::Terminal(Harness::Codex)
    );
}
