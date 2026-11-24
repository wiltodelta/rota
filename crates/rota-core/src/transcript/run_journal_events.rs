use std::fs::File;
use std::io::{Seek, SeekFrom, Write};
use std::sync::{Arc, Mutex};

use crate::model::{
    AgentQuestion, QuestionAnswer, QuestionFieldKind, RunOutcome, SessionConfiguration, TerminalState,
};
use crate::transcript::run_journal::{JournalInner, RunJournal};
use crate::transcript::{
    MarkdownBlock, MarkdownImageReference, PlanStep, ToolOutput, Transcript, TranscriptItemKind,
    TranscriptRecord,
};

impl RunJournal {
    pub fn readable(kind: TranscriptItemKind, text: &str) -> String {
        match kind {
            TranscriptItemKind::User => Transcript::user_lines(text),
            TranscriptItemKind::Tool => format!("-> {text}"),
            TranscriptItemKind::Status => format!("[rota: {text}]"),
            TranscriptItemKind::Error => format!("[error] {text}"),
            TranscriptItemKind::Plan => {
                let mut lines = vec![format!("{}{}", PlanStep::PREFIX, PlanStep::HEADER)];
                for line in text.split('\n') {
                    lines.push(format!("{}{line}", PlanStep::PREFIX));
                }
                lines.join("\n")
            }
            TranscriptItemKind::Agent => text.to_string(),
            TranscriptItemKind::Reasoning | TranscriptItemKind::Output => {
                let rendered = if kind == TranscriptItemKind::Output {
                    ToolOutput::decode(text)
                        .map(|o| o.readable())
                        .unwrap_or_else(|| text.to_string())
                } else {
                    text.to_string()
                };
                rendered
                    .split('\n')
                    .map(|l| format!("[{}] {l}", kind.as_str()))
                    .collect::<Vec<_>>()
                    .join("\n")
            }
        }
    }

    pub fn session(&self, id: &str) {
        (self.events.session)(id.to_string());
    }

    pub fn undelivered(&self, message: &str) {
        (self.events.undelivered)(message.to_string());
    }

    pub fn terminal_input(&self) {
        (self.events.terminal_input)();
    }

    pub fn terminal_state(&self, state: TerminalState) {
        (self.events.terminal_state)(state);
    }

    pub fn resolve_question(&self, id: &str) {
        (self.events.question_resolved)(id.to_string());
    }

    pub fn provenance(&self, cli: Option<String>, server: Option<String>) {
        (self.events.provenance)(cli, server);
    }

    pub fn require_reconciliation(&self) {
        (self.events.reconciliation_required)();
    }

    pub fn configure(&self, configuration: SessionConfiguration) {
        let next = {
            let mut g = self.inner.lock().unwrap();
            if g.finished {
                return;
            }
            let mut next = g.reported_configuration.clone();
            if let Some(model) = configuration.model {
                if Some(&model) != next.model.as_ref() {
                    next.model_title = None;
                }
                next.model = Some(model);
            }
            if let Some(title) = configuration.model_title {
                next.model_title = Some(title);
            }
            if let Some(effort) = configuration.effort {
                next.effort = Some(effort);
            }
            if next == g.reported_configuration {
                return;
            }
            g.reported_configuration = next.clone();
            next
        };
        (self.events.configuration)(next);
    }

    pub fn ask<F>(self: &Arc<Self>, question: AgentQuestion, record_text: bool, reply: F)
    where
        F: FnOnce(QuestionAnswer) + Send + Sync + 'static,
    {
        if self.is_finished() {
            reply(QuestionAnswer::cancel());
            return;
        }
        if record_text {
            let mut parts = vec![question.title.clone(), question.detail.clone()];
            for field in &question.fields {
                parts.push(field.title.clone());
                for opt in &field.options {
                    parts.push(if opt.detail.is_empty() {
                        opt.label.clone()
                    } else {
                        format!("{}: {}", opt.label, opt.detail)
                    });
                }
            }
            let body = parts
                .into_iter()
                .filter(|s| !s.is_empty())
                .collect::<Vec<_>>()
                .join("\n");
            self.record(TranscriptItemKind::Agent, &body);
        }
        let me = Arc::clone(self);
        let q_copy = question.clone();
        let once = Mutex::new(Some(reply));
        (self.events.question)(
            question,
            Arc::new(move |answer: QuestionAnswer| {
                let mut visible = vec![answer.action.clone()];
                for field in &q_copy.fields {
                    let rendered = if field.kind == QuestionFieldKind::Secret {
                        "[private answer]".to_string()
                    } else {
                        answer
                            .values
                            .get(&field.id)
                            .cloned()
                            .unwrap_or_default()
                            .join(", ")
                    };
                    visible.push(format!("{}: {rendered}", field.title));
                }
                me.record(TranscriptItemKind::User, &visible.join("\n"));
                if let Some(cb) = once.lock().unwrap().take() {
                    cb(answer);
                }
            }),
        );
    }

    pub fn finish(&self, outcome: RunOutcome) {
        {
            let mut g = self.inner.lock().unwrap();
            if g.finished {
                return;
            }
            g.finished = true;
            Self::flush_text(&mut g);
            let elapsed = self.started_at.elapsed().as_secs();
            let note = format!("{} after {elapsed} s", outcome.title());
            Self::write_raw(&mut g, &Self::readable(TranscriptItemKind::Status, &note));
            let sz = Self::file_offset(&mut g.output);
            let readable_note = Transcript::readable_durations(&note);
            Self::append_item(&mut g, TranscriptItemKind::Status, &readable_note, None, None, sz);
            g.closed = true;
        }
        (self.events.finished)(outcome);
    }

    pub(crate) fn flush_text(g: &mut JournalInner) {
        if g.pending_text.is_empty() {
            return;
        }
        let text = std::mem::take(&mut g.pending_text);
        let item_id = g.pending_id.take();
        let kind = g.pending_kind;
        let trimmed = text.trim_matches(['\r', '\n']);
        Self::write_raw(g, &Self::readable(kind, trimmed));
        let sz = Self::file_offset(&mut g.output);
        if let Some(id) = item_id {
            Self::persist(
                g,
                TranscriptRecord {
                    version: 1,
                    record_type: "complete".into(),
                    required: None,
                    id: Some(id as isize),
                    kind: None,
                    text: None,
                    complete: None,
                    log_size: sz,
                    source_id: None,
                    native_id: None,
                },
            );
        }
        if let Some(nid) = g.pending_native_id.take() {
            g.native_items.insert(nid, text.clone());
        }
        if kind == TranscriptItemKind::Agent {
            let mut warn = None;
            Self::capture_images_warning(g, &text, item_id, &mut warn);
            if let Some(w) = warn {
                Self::write_raw(g, &Self::readable(TranscriptItemKind::Status, &w));
                let wsz = Self::file_offset(&mut g.output);
                Self::append_item(g, TranscriptItemKind::Status, &w, None, None, wsz);
            }
        }
    }

    pub(crate) fn capture_images_warning(
        g: &mut JournalInner,
        text: &str,
        item_id: Option<usize>,
        warn: &mut Option<String>,
    ) {
        let Some(images) = &g.images else {
            return;
        };
        let refs = MarkdownImageReference::references_in_blocks(&MarkdownBlock::parse(text));
        if let Err(err) = images.capture(&refs, item_id) {
            *warn = Some(format!("Couldn't preserve an image: {err}"));
        }
    }

    pub(crate) fn append_item(
        g: &mut JournalInner,
        kind: TranscriptItemKind,
        text: &str,
        source_id: Option<String>,
        native_id: Option<String>,
        log_size: u64,
    ) {
        let Some(tj) = &mut g.transcript else {
            return;
        };
        let id = tj.allocate_id();
        Self::persist(
            g,
            TranscriptRecord {
                version: 1,
                record_type: "item".into(),
                required: None,
                id: Some(id as isize),
                kind: Some(kind.as_str().into()),
                text: Some(text.to_string()),
                complete: None,
                log_size,
                source_id,
                native_id,
            },
        );
    }

    pub(crate) fn persist(g: &mut JournalInner, record: TranscriptRecord) {
        if let Some(tj) = &mut g.transcript
            && tj.append(&record).is_err()
        {
            g.transcript = None;
            Self::write_raw(
                g,
                "[error] Couldn't save chat history. The readable log is still available.",
            );
            Self::LOG.error("Couldn't save normalized chat history");
        }
    }

    pub(crate) fn write_raw(g: &mut JournalInner, text: &str) {
        if g.closed {
            return;
        }
        let _ = g.output.seek(SeekFrom::End(0));
        let _ = g.output.write_all(text.as_bytes());
        let _ = g.output.write_all(b"\n");
    }

    pub(crate) fn file_offset(file: &mut File) -> u64 {
        file.stream_position().unwrap_or(0)
    }
}

/// Single-quotes `text` safely for `zsh`.
pub fn shell_quote(text: &str) -> String {
    format!("'{}'", text.replace('\'', r"'\''"))
}
