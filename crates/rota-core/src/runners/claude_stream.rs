use std::collections::{HashMap, HashSet};
use std::path::PathBuf;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use rota_platform::Logger;
use serde_json::json;

use crate::model::{HarnessInput, LaunchMode, RunOutcome};
use crate::runners::{
    ClaudeConfiguration, ClaudeRunSettings, DurableStream, LaunchError, LaunchSpec, RunControl,
};
use crate::transcript::{RunJournal, TranscriptItemKind};

pub use super::stream_json::StreamJsonFormatter;

pub(super) struct StreamState {
    pub(super) recovered_outcome: Option<RunOutcome>,
    pub(super) stop_reason: Option<RunOutcome>,
    pub(super) questions: HashMap<String, String>,
    pub(super) background: HashSet<String>,
    pub(super) notified: bool,
    pub(super) turns: usize,
    pub(super) streamed_text: bool,
    pub(super) streamed_reasoning: bool,
}

pub struct ClaudeStreamRun {
    pub(super) spec: LaunchSpec,
    pub(super) journal: Arc<RunJournal>,
    pub(super) hook_settings: Option<PathBuf>,
    pub(super) capture: Arc<DurableStream>,
    pub(super) state: Mutex<StreamState>,
    pub settle_secs: f64,
}

impl ClaudeStreamRun {
    pub(super) const LOG: Logger = Logger::new("claude");

    pub fn user_message_bytes(text: &str) -> Vec<u8> {
        let msg = json!({
            "type": "user",
            "message": {
                "role": "user",
                "content": HarnessInput::blocks(text, LaunchMode::ClaudeStream),
            }
        });
        let mut out = serde_json::to_vec(&msg).unwrap_or_default();
        out.push(b'\n');
        out
    }

    pub fn start(spec: LaunchSpec, journal: Arc<RunJournal>) -> Result<Arc<dyn RunControl>, LaunchError> {
        let (capture, hook_settings) = if spec.adopt {
            (DurableStream::restore(&spec.log)?, None)
        } else {
            let parent = spec.log.parent().unwrap_or_else(|| std::path::Path::new("/tmp"));
            let settings = ClaudeRunSettings::hooks(parent).map_err(LaunchError::Message)?;
            let mut args = spec.arguments.clone();
            args.push("--settings".into());
            args.push(settings.to_string_lossy().into_owned());
            args.extend(spec.model_flags("--effort"));
            match DurableStream::spawn(&spec, &args) {
                Ok(cap) => (cap, Some(settings)),
                Err(err) => {
                    let _ = std::fs::remove_file(&settings);
                    return Err(err);
                }
            }
        };

        let run = Arc::new(Self {
            spec: spec.clone(),
            journal: Arc::clone(&journal),
            hook_settings,
            capture: Arc::clone(&capture),
            state: Mutex::new(StreamState {
                recovered_outcome: None,
                stop_reason: None,
                questions: HashMap::new(),
                background: HashSet::new(),
                notified: false,
                turns: 0,
                streamed_text: false,
                streamed_reasoning: false,
            }),
            settle_secs: 5.0,
        });

        if !spec.adopt {
            let init = ClaudeConfiguration::request_bytes("initialize", ClaudeConfiguration::INITIALIZE_ID);
            let get_set =
                ClaudeConfiguration::request_bytes("get_settings", ClaudeConfiguration::SETTINGS_ID);
            let prompt = Self::user_message_bytes(&spec.prompt);
            if let Err(err) = capture
                .write_input(&init)
                .and_then(|()| capture.write_input(&get_set))
                .and_then(|()| capture.write_input(&prompt))
            {
                if let Some(s) = &run.hook_settings {
                    let _ = std::fs::remove_file(s);
                }
                capture.stop(Duration::from_secs(3));
                return Err(LaunchError::Message(err.to_string()));
            }
        }
        if let Some(session) = &spec.resume {
            journal.session(session);
        }
        if let Some(secs) = spec.timeout_secs {
            let weak = Arc::downgrade(&run);
            std::thread::spawn(move || {
                std::thread::sleep(Duration::from_secs_f64(secs.max(0.0)));
                if let Some(r) = weak.upgrade() {
                    r.end(RunOutcome::TimedOut);
                }
            });
        }
        let r_line = Arc::clone(&run);
        let r_end = Arc::clone(&run);
        capture.follow(
            move |bytes, source| {
                let text = String::from_utf8_lossy(bytes).into_owned();
                r_line.journal.with_source(&source, || r_line.handle_line(&text));
            },
            move |status| r_end.exited(status),
        );
        Ok(run)
    }

    pub(super) fn close_turn(&self, failed: bool) {
        self.state.lock().unwrap().recovered_outcome = Some(if failed {
            RunOutcome::Failed { exit_code: 1 }
        } else {
            RunOutcome::Succeeded
        });
        self.capture.close_input();
    }

    pub(super) fn exited(&self, status: i32) {
        if self.capture.alive() {
            self.journal.require_reconciliation();
        }
        if let Some(settings) = &self.hook_settings {
            let _ = std::fs::remove_file(settings);
        }
        let outcome = {
            let g = self.state.lock().unwrap();
            g.stop_reason
                .clone()
                .or_else(|| g.recovered_outcome.clone())
                .unwrap_or(if status == 0 || status == -1 {
                    RunOutcome::Interrupted
                } else {
                    RunOutcome::Failed { exit_code: status }
                })
        };
        self.journal.finish(outcome);
        Self::LOG.info(&format!("claude exited with {status}"));
    }

    pub(super) fn end(&self, reason: RunOutcome) {
        if self.journal.is_finished() || !self.capture.alive() {
            return;
        }
        {
            let mut g = self.state.lock().unwrap();
            if g.stop_reason.is_some() {
                return;
            }
            g.stop_reason = Some(reason);
        }
        self.capture.stop(Duration::from_secs(10));
    }
}

impl RunControl for ClaudeStreamRun {
    fn stop(&self) {
        self.end(RunOutcome::Cancelled);
    }

    fn send(&self, message: &str) {
        if self.journal.is_finished() || !self.capture.has_input() {
            self.journal.undelivered(message);
            return;
        }
        self.journal.record(TranscriptItemKind::User, message);
        let bytes = Self::user_message_bytes(message);
        if let Err(err) = self.capture.write_input(&bytes) {
            self.journal
                .line(&format!("[rota: message not delivered: {err}]"));
        }
    }
}
