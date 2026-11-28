use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::sync::Arc;
use std::time::Duration;

use rota_platform::OwnedProcess;
use serde_json::Value;

use crate::model::SessionConfiguration;
use crate::runners::{ClaudeInteractiveRun, ClaudeTranscript, ScreenRun, StreamJsonFormatter};
use crate::transcript::{TranscriptItemKind, TranscriptService};

impl ClaudeInteractiveRun {
    pub(super) fn poll_loop(self: Arc<Self>) {
        loop {
            if self.journal.is_finished() {
                return;
            }
            self.read_effort();
            self.read_transcript();
            self.dialogs.poll();

            let stopping_alive = self
                .state
                .lock()
                .unwrap()
                .stopping
                .iter()
                .any(OwnedProcess::exists);
            if !stopping_alive {
                let status = self.exit_status().or_else(|| {
                    if ScreenRun::alive(&self.name) {
                        None
                    } else {
                        Some(self.exit_status().unwrap_or(-1))
                    }
                });
                if let Some(st) = status {
                    self.finish(st);
                    return;
                }
            }

            let now_up = (self.uptime)();
            let should_exit = {
                let mut g = self.state.lock().unwrap();
                let stalled = g.errored_at.is_some_and(|t| now_up - t >= Self::STALL_GRACE_SECS);
                if (g.turn_ended || stalled)
                    && g.unanswered == 0
                    && g.background.is_empty()
                    && !g.exiting
                    && g.stop_reason.is_none()
                {
                    g.exiting = true;
                    true
                } else {
                    false
                }
            };
            if should_exit {
                ScreenRun::type_keys(&self.name, "/exit");
                ScreenRun::type_keys(&self.name, "\r");
                let name = self.name.clone();
                std::thread::spawn(move || {
                    std::thread::sleep(Duration::from_secs(15));
                    ScreenRun::quit(&name);
                });
            }
            std::thread::sleep(Duration::from_secs(1));
        }
    }

    pub(super) fn read_effort(&self) {
        let Ok(raw) = std::fs::read_to_string(&self.effort_file) else {
            return;
        };
        let trimmed = raw.trim();
        if matches!(trimmed, "low" | "medium" | "high" | "xhigh" | "max") {
            self.journal.configure(SessionConfiguration::new(
                None,
                Some(trimmed.to_string()),
                None,
                None,
            ));
        }
    }

    pub(super) fn read_transcript(&self) {
        let (path, offset) = {
            let mut g = self.state.lock().unwrap();
            if g.transcript.is_none() {
                g.transcript = Self::transcript_file(&self.session);
            }
            let Some(p) = g.transcript.clone() else {
                return;
            };
            (p, g.offset)
        };
        let Ok(mut file) = File::open(&path) else {
            return;
        };
        let _ = file.seek(SeekFrom::Start(offset));
        let mut buf = Vec::new();
        let _ = file.read_to_end(&mut buf);
        if buf.is_empty() {
            return;
        }
        let mut lines = Vec::new();
        {
            let mut g = self.state.lock().unwrap();
            g.offset += buf.len() as u64;
            g.partial.extend_from_slice(&buf);
            while let Some(nl) = g.partial.iter().position(|&b| b == b'\n') {
                lines.push(g.partial.drain(..=nl).take(nl).collect::<Vec<u8>>());
            }
        }
        for line in lines {
            self.handle_entry(&line);
        }
    }

    pub(super) fn restore_state(&self, entry: &ClaudeTranscript) {
        let mut g = self.state.lock().unwrap();
        match entry {
            ClaudeTranscript::User(_) | ClaudeTranscript::Queued(_) => g.turn_ended = false,
            ClaudeTranscript::Service(text) => {
                let tasks = TranscriptService::task_ids(text);
                if !tasks.is_empty() {
                    g.turn_ended = false;
                }
                for t in tasks {
                    g.background.remove(&t);
                }
            }
            ClaudeTranscript::Background { id, running } => {
                if *running {
                    g.background.insert(id.clone());
                } else {
                    g.background.remove(id);
                }
            }
            ClaudeTranscript::TurnEnded => g.turn_ended = true,
            ClaudeTranscript::Assistant { .. } | ClaudeTranscript::ApiError(_) => {
                g.turn_ended = false;
            }
            ClaudeTranscript::Other => {}
        }
    }

    pub fn handle_entry(&self, data: &[u8]) {
        let obj = serde_json::from_slice::<Value>(data).ok();
        let entry = obj
            .as_ref()
            .map_or(ClaudeTranscript::Other, ClaudeTranscript::read_entry);
        self.restore_state(&entry);
        {
            let now_up = (self.uptime)();
            let mut g = self.state.lock().unwrap();
            match entry {
                ClaudeTranscript::ApiError(_) => g.errored_at = Some(now_up),
                // Bookkeeping and tool results show Claude still busy: the silence starts again.
                ClaudeTranscript::Other => {
                    if g.errored_at.is_some() {
                        g.errored_at = Some(now_up);
                    }
                }
                _ => g.errored_at = None,
            }
        }
        if let Some(o) = &obj {
            self.dialogs.track(o, entry.moves_on());
        }
        match entry {
            ClaudeTranscript::User(text) => {
                let skip = {
                    let mut g = self.state.lock().unwrap();
                    if g.prompt_pending && text.trim() == self.spec.prompt.trim() {
                        g.prompt_pending = false;
                        true
                    } else {
                        g.prompt_pending = false;
                        g.unanswered = g.unanswered.saturating_sub(1);
                        false
                    }
                };
                if !skip {
                    self.journal.record(TranscriptItemKind::User, &text);
                }
            }
            ClaudeTranscript::Queued(text) => {
                let mut g = self.state.lock().unwrap();
                g.unanswered = g.unanswered.saturating_sub(1);
                drop(g);
                self.journal.record(TranscriptItemKind::User, &text);
            }
            ClaudeTranscript::Assistant { model, items } => {
                let write_header = {
                    let mut g = self.state.lock().unwrap();
                    if !items.is_empty() {
                        g.failed = false;
                    }
                    if !g.header_written && model.is_some() {
                        g.header_written = true;
                        true
                    } else {
                        false
                    }
                };
                self.journal
                    .configure(SessionConfiguration::new(model.clone(), None, None, None));
                if write_header && let Some(m) = &model {
                    self.journal.line(&format!("[session started, {m}]"));
                }
                for item in items {
                    self.journal.record(item.kind, &item.text);
                }
            }
            ClaudeTranscript::Service(text) => {
                self.journal.record(TranscriptItemKind::Status, &text);
            }
            ClaudeTranscript::ApiError(text) => {
                self.state.lock().unwrap().failed = true;
                self.journal.line(&format!("[error] {text}"));
            }
            ClaudeTranscript::TurnEnded => {
                let bg = self.state.lock().unwrap().background.len();
                if bg > 0 {
                    self.journal
                        .record(TranscriptItemKind::Status, &TranscriptService::waiting(bg));
                }
            }
            ClaudeTranscript::Background { .. } | ClaudeTranscript::Other => {
                for item in StreamJsonFormatter::items(data) {
                    self.journal.record(item.kind, &item.text);
                }
            }
        }
    }
}
