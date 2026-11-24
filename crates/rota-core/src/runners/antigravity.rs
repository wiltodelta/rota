use std::collections::HashSet;
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use rota_platform::home_dir;
use serde_json::json;

use crate::model::RunOutcome;
use crate::runners::{AntigravityConfiguration, DurableStream, LaunchError, LaunchSpec, RunControl};
use crate::transcript::{RunJournal, TranscriptItemKind};

pub use super::antigravity_archive::{AntigravityQuestionArchive, AntigravityTranscript};
pub use super::antigravity_stream::{AntigravityEvent, AntigravityStream};

struct AgyState {
    capture: Option<Arc<DurableStream>>,
    pending: Vec<String>,
    stream: AntigravityStream,
    outcome: Option<RunOutcome>,
    stop_reason: Option<RunOutcome>,
    closing: bool,
    questions: Option<AntigravityQuestionArchive>,
    question_read_failed: bool,
    saw_unknown_step: bool,
    reported_errors: HashSet<String>,
    writing_text: bool,
    text_step: Option<i64>,
    completed_text_step: Option<i64>,
}

pub struct AntigravityRun {
    spec: LaunchSpec,
    journal: Arc<RunJournal>,
    question_home: PathBuf,
    state: Mutex<AgyState>,
}

impl AntigravityRun {
    pub fn arguments(resume: Option<&str>) -> Vec<String> {
        let mut args = vec![
            "--input-format".into(),
            "stream-json".into(),
            "--output-format".into(),
            "stream-json".into(),
            "--dangerously-skip-permissions".into(),
        ];
        if let Some(r) = resume {
            args.push("--conversation".into());
            args.push(r.to_string());
        }
        args
    }

    pub fn user_message_bytes(text: &str) -> Vec<u8> {
        let mut out =
            serde_json::to_vec(&json!({"event": "user", "message": {"content": text}})).unwrap_or_default();
        out.push(b'\n');
        out
    }

    pub fn start(spec: LaunchSpec, journal: Arc<RunJournal>) -> Result<Arc<dyn RunControl>, LaunchError> {
        let q_home = spec
            .environment
            .get("HOME")
            .map(PathBuf::from)
            .unwrap_or_else(home_dir);
        let questions = spec
            .resume
            .as_deref()
            .and_then(|s| AntigravityQuestionArchive::open(s, &q_home, !spec.adopt));

        let run = Arc::new(Self {
            spec: spec.clone(),
            journal: Arc::clone(&journal),
            question_home: q_home,
            state: Mutex::new(AgyState {
                capture: None,
                pending: Vec::new(),
                stream: AntigravityStream::default(),
                outcome: None,
                stop_reason: None,
                closing: false,
                questions,
                question_read_failed: false,
                saw_unknown_step: false,
                reported_errors: HashSet::new(),
                writing_text: false,
                text_step: None,
                completed_text_step: None,
            }),
        });

        if spec.adopt {
            let cap = DurableStream::restore(&spec.log)?;
            run.state.lock().unwrap().capture = Some(Arc::clone(&cap));
            if let Some(s) = &spec.resume {
                journal.session(s);
            }
            run.start_follow_and_timeout(cap);
        } else {
            let worker = Arc::clone(&run);
            std::thread::spawn(move || {
                let mut applied = worker.spec.clone();
                if let Some(cfg) = AntigravityConfiguration::read(&worker.spec) {
                    applied.model = cfg.model.clone();
                    worker.journal.configure(cfg.clone());
                    if let Some(m) = &cfg.model {
                        worker.journal.line(&format!("[session started, {m}]"));
                    }
                }
                let mut args = Self::arguments(applied.resume.as_deref());
                args.extend(applied.model_flags("--effort"));
                match DurableStream::spawn(&applied, &args) {
                    Ok(cap) => {
                        worker.state.lock().unwrap().capture = Some(Arc::clone(&cap));
                        worker.write_turn(&worker.spec.prompt);
                        worker.start_follow_and_timeout(cap);
                    }
                    Err(err) => {
                        worker.journal.finish(RunOutcome::LaunchFailed(err.to_string()));
                    }
                }
            });
        }
        Ok(run)
    }

    fn start_follow_and_timeout(self: &Arc<Self>, cap: Arc<DurableStream>) {
        if let Some(secs) = self.spec.timeout_secs {
            let weak = Arc::downgrade(self);
            std::thread::spawn(move || {
                std::thread::sleep(Duration::from_secs_f64(secs.max(0.0)));
                if let Some(me) = weak.upgrade() {
                    me.end(RunOutcome::TimedOut);
                }
            });
        }
        let r_line = Arc::clone(self);
        let r_end = Arc::clone(self);
        cap.follow(
            move |bytes, source| {
                r_line.journal.with_source(&source, || r_line.handle_line(bytes));
            },
            move |status| r_end.exited(status),
        );
    }

    fn write_turn(&self, message: &str) {
        let cap = {
            let mut g = self.state.lock().unwrap();
            if g.outcome.as_ref().is_none_or(|o| !o.is_failure()) {
                g.outcome = None;
            }
            g.capture.clone()
        };
        if let Some(cap) = cap
            && let Err(err) = cap.write_input(&Self::user_message_bytes(message))
        {
            self.journal.record(
                TranscriptItemKind::Error,
                &format!("Couldn't send the message to Antigravity: {err}"),
            );
            self.end(RunOutcome::Failed { exit_code: 1 });
        }
    }

    pub fn handle_line(self: &Arc<Self>, line: &[u8]) {
        if self.journal.is_finished() {
            return;
        }
        let events = self.state.lock().unwrap().stream.events(line);
        for ev in events {
            self.handle_event(ev);
        }
    }

    fn handle_event(self: &Arc<Self>, ev: AntigravityEvent) {
        match ev {
            AntigravityEvent::Session(id) => {
                {
                    let mut g = self.state.lock().unwrap();
                    if g.questions.as_ref().map(|q| q.session.as_str()) != Some(id.as_str()) {
                        g.questions = AntigravityQuestionArchive::open(&id, &self.question_home, false);
                    }
                }
                self.journal.session(&id);
            }
            AntigravityEvent::UnknownStep => {
                self.state.lock().unwrap().saw_unknown_step = true;
                self.read_questions(false, None);
            }
            AntigravityEvent::Configuration(cfg) => self.journal.configure(cfg),
            AntigravityEvent::TextStarted(step) => {
                self.journal.end_text();
                {
                    let mut g = self.state.lock().unwrap();
                    g.writing_text = false;
                    g.text_step = step;
                }
                self.read_questions(false, step);
                self.state.lock().unwrap().writing_text = true;
            }
            AntigravityEvent::TextEnded(step) => {
                self.journal.end_text();
                {
                    let mut g = self.state.lock().unwrap();
                    g.writing_text = false;
                    g.completed_text_step = step;
                }
                self.read_questions(false, step);
                self.state.lock().unwrap().text_step = None;
            }
            AntigravityEvent::Text(text) => {
                self.read_questions(false, None);
                let nid = {
                    let g = self.state.lock().unwrap();
                    g.text_step.and_then(|st| {
                        g.questions
                            .as_ref()
                            .map(|q| format!("antigravity/{}/{st}/text", q.session))
                    })
                };
                self.journal
                    .text(&text, TranscriptItemKind::Agent, nid.as_deref());
            }
            AntigravityEvent::Item { kind, text, step } => {
                self.journal.end_text();
                self.state.lock().unwrap().writing_text = false;
                let prior_step = step.map(|s| s - 1);
                if kind != TranscriptItemKind::Output && kind != TranscriptItemKind::Error {
                    self.read_questions(false, prior_step);
                }
                let (nid, should_record) = {
                    let mut g = self.state.lock().unwrap();
                    let nid = if kind == TranscriptItemKind::Error {
                        step.and_then(|st| {
                            g.questions
                                .as_ref()
                                .map(|q| format!("antigravity/{}/{st}/error", q.session))
                        })
                    } else {
                        None
                    };
                    let rec = if kind != TranscriptItemKind::Error {
                        true
                    } else if nid.is_some() {
                        g.reported_errors.insert(text.clone());
                        true
                    } else {
                        g.reported_errors.insert(text.clone())
                    };
                    (nid, rec)
                };
                if should_record {
                    self.journal.record_with_native(kind, &text, nid.as_deref());
                }
                if kind == TranscriptItemKind::Output {
                    self.read_questions(false, prior_step);
                }
                if kind == TranscriptItemKind::Error {
                    self.read_questions(false, step);
                }
            }
            AntigravityEvent::Result(mut res) => {
                self.journal.end_text();
                let completed_step = {
                    let mut g = self.state.lock().unwrap();
                    g.writing_text = false;
                    g.completed_text_step.take()
                };
                self.read_questions(false, None);
                let next_msg = {
                    let mut g = self.state.lock().unwrap();
                    if g.stream.recovered_stale_error
                        && let Some(last_err) = g.questions.as_ref().and_then(|q| q.last_error_step)
                        && completed_step.is_none_or(|cs| last_err > cs)
                    {
                        res = RunOutcome::Failed { exit_code: 1 };
                    }
                    if g.outcome.is_none() || res.is_failure() {
                        g.outcome = Some(res);
                    }
                    if self.spec.adopt {
                        return;
                    }
                    if !g.pending.is_empty() && g.stop_reason.is_none() {
                        Some(g.pending.remove(0))
                    } else {
                        g.closing = true;
                        if let Some(cap) = &g.capture {
                            cap.close_input();
                        }
                        None
                    }
                };
                if let Some(msg) = next_msg {
                    self.write_turn(&msg);
                }
            }
        }
    }

    fn read_questions(self: &Arc<Self>, is_final: bool, reasoning_through: Option<i64>) {
        let step_result = {
            let mut g = self.state.lock().unwrap();
            if g.question_read_failed {
                return;
            }
            if is_final && g.saw_unknown_step && g.questions.as_ref().is_none_or(|q| !q.file.exists()) {
                Err("Missing Antigravity native transcript".to_string())
            } else if g.questions.is_some() {
                let writing = g.writing_text;
                let bound = reasoning_through.or(g.completed_text_step);
                let raw = {
                    let q_arch = g.questions.as_mut().unwrap();
                    q_arch.read(is_final).map(|qs| {
                        let (errs, reas) = if !writing {
                            (q_arch.take_errors(bound), q_arch.take_reasoning(bound))
                        } else {
                            (Vec::new(), Vec::new())
                        };
                        (qs, errs, reas)
                    })
                };
                raw.map(|(qs, errs, reas)| {
                    let filtered_errs: Vec<(String, String)> = errs
                        .into_iter()
                        .filter(|(_, txt)| g.reported_errors.insert(txt.clone()))
                        .collect();
                    (qs, filtered_errs, reas)
                })
            } else {
                Ok((Vec::new(), Vec::new(), Vec::new()))
            }
        };

        match step_result {
            Ok((qs, errs, reas)) => {
                for q in qs {
                    self.journal.ask(q, false, |_| {});
                }
                for (id, txt) in errs {
                    self.journal
                        .record_with_native(TranscriptItemKind::Error, &txt, Some(&id));
                }
                for (id, txt) in reas {
                    self.journal
                        .record_with_native(TranscriptItemKind::Reasoning, &txt, Some(&id));
                }
            }
            Err(_) => {
                self.state.lock().unwrap().question_read_failed = true;
                self.journal.record(
                    TranscriptItemKind::Error,
                    "Antigravity's native questions could not be read. \
Question sync is paused; ask the agent to repeat its question in a message.",
                );
            }
        }
    }

    fn exited(self: &Arc<Self>, status: i32) {
        let alive = {
            let mut g = self.state.lock().unwrap();
            g.closing = true;
            if let Some(cap) = &g.capture {
                cap.close_input();
            }
            g.writing_text = false;
            g.completed_text_step = None;
            g.capture.as_ref().is_some_and(|c| c.alive())
        };
        if alive {
            self.journal.require_reconciliation();
        }
        self.journal.end_text();
        self.read_questions(true, None);
        let final_outcome = {
            let g = self.state.lock().unwrap();
            if g.outcome.is_none() && g.stop_reason.is_none() {
                self.journal.record(
                    TranscriptItemKind::Error,
                    "Antigravity exited without a result. The session may be incomplete.",
                );
            }
            let native = match status {
                0 => g.outcome.clone().unwrap_or(RunOutcome::Interrupted),
                1 if g.stream.recovered_stale_error && g.outcome == Some(RunOutcome::Succeeded) => {
                    RunOutcome::Succeeded
                }
                -1 => RunOutcome::Interrupted,
                code => match &g.outcome {
                    None | Some(RunOutcome::Succeeded) | Some(RunOutcome::Failed { .. }) => {
                        RunOutcome::Failed { exit_code: code }
                    }
                    Some(early) => early.clone(),
                },
            };
            g.stop_reason.clone().unwrap_or(if g.question_read_failed {
                RunOutcome::Failed { exit_code: 1 }
            } else {
                native
            })
        };
        self.journal.finish(final_outcome);
    }

    fn end(&self, reason: RunOutcome) {
        if self.journal.is_finished() {
            return;
        }
        let cap = {
            let mut g = self.state.lock().unwrap();
            if g.stop_reason.is_some() || !g.capture.as_ref().is_some_and(|c| c.alive()) {
                return;
            }
            g.stop_reason = Some(reason);
            g.closing = true;
            g.capture.clone()
        };
        if let Some(cap) = cap {
            cap.close_input();
            cap.stop(Duration::from_secs(3));
        }
    }
}

impl RunControl for AntigravityRun {
    fn stop(&self) {
        self.end(RunOutcome::Cancelled);
    }

    fn send(&self, message: &str) {
        let accepted = {
            let mut g = self.state.lock().unwrap();
            if self.spec.adopt || g.closing || self.journal.is_finished() {
                false
            } else {
                g.pending.push(message.to_string());
                true
            }
        };
        if accepted {
            self.journal.record(TranscriptItemKind::User, message);
        } else {
            self.journal.undelivered(message);
        }
    }
}
