use std::collections::HashSet;
use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};

use serde_json::Value;
use uuid::Uuid;

use crate::model::{AgentQuestion, QuestionRequest, TerminalState};
use crate::runners::NativeTranscriptEvent;
use crate::transcript::TranscriptItemKind;

#[derive(Default)]
pub struct AntigravityTranscript {
    completed: HashSet<i64>,
}

impl AntigravityTranscript {
    pub fn read(&mut self, row: &Value) -> Vec<NativeTranscriptEvent> {
        if !matches!(row.get("status").and_then(Value::as_str), Some("DONE" | "ERROR")) {
            return Vec::new();
        }
        if let Some(step) = row.get("step_index").and_then(Value::as_i64)
            && !self.completed.insert(step)
        {
            return Vec::new();
        }
        Self::events(row)
    }

    pub fn events(entry: &Value) -> Vec<NativeTranscriptEvent> {
        if !matches!(
            entry.get("status").and_then(Value::as_str),
            Some("DONE" | "ERROR")
        ) {
            return Vec::new();
        }
        let content = entry.get("content").and_then(Value::as_str);
        match entry.get("type").and_then(Value::as_str) {
            Some("USER_INPUT") => content
                .map(|c| {
                    vec![
                        NativeTranscriptEvent::Item(TranscriptItemKind::User, Self::user_text(c)),
                        NativeTranscriptEvent::State(TerminalState::Working),
                    ]
                })
                .unwrap_or_default(),
            Some("PLANNER_RESPONSE") => {
                let mut out = Vec::new();
                if let Some(thinking) = entry.get("thinking").and_then(Value::as_str)
                    && !thinking.is_empty()
                {
                    out.push(NativeTranscriptEvent::Item(
                        TranscriptItemKind::Reasoning,
                        thinking.to_string(),
                    ));
                }
                let calls = entry
                    .get("tool_calls")
                    .and_then(Value::as_array)
                    .cloned()
                    .unwrap_or_default();
                for call in &calls {
                    if let Some(name) = call.get("name").and_then(Value::as_str) {
                        out.push(NativeTranscriptEvent::Item(
                            TranscriptItemKind::Tool,
                            name.to_string(),
                        ));
                    }
                }
                if let Some(c) = content
                    && !c.is_empty()
                {
                    out.push(NativeTranscriptEvent::Item(
                        TranscriptItemKind::Agent,
                        c.to_string(),
                    ));
                }
                if calls.is_empty() {
                    out.push(NativeTranscriptEvent::State(TerminalState::Waiting));
                }
                out
            }
            Some("ERROR_MESSAGE") => Self::error_text(entry)
                .map(|e| vec![NativeTranscriptEvent::Item(TranscriptItemKind::Error, e)])
                .unwrap_or_default(),
            Some("GENERIC") => {
                if entry.get("status").and_then(Value::as_str) == Some("ERROR") {
                    Self::error_text(entry)
                        .map(|e| vec![NativeTranscriptEvent::Item(TranscriptItemKind::Error, e)])
                        .unwrap_or_default()
                } else {
                    content
                        .map(|c| {
                            vec![NativeTranscriptEvent::Item(
                                TranscriptItemKind::Output,
                                c.to_string(),
                            )]
                        })
                        .unwrap_or_default()
                }
            }
            _ => Vec::new(),
        }
    }

    pub fn error_text(row: &Value) -> Option<String> {
        let err = row.get("error").and_then(Value::as_str).unwrap_or("");
        let content = row.get("content").and_then(Value::as_str).unwrap_or("");
        if err.is_empty() {
            return (!content.is_empty()).then(|| content.to_string());
        }
        if content.is_empty() || content.contains(err) {
            return Some(if content.is_empty() {
                err.to_string()
            } else {
                content.to_string()
            });
        }
        Some(format!("{err}\n{content}"))
    }

    fn user_text(content: &str) -> String {
        let prefix = "<USER_REQUEST>\n";
        if let Some(after) = content.strip_prefix(prefix)
            && let Some(end) = after.rfind("\n</USER_REQUEST>")
        {
            return after[..end].to_string();
        }
        content.to_string()
    }
}

struct IndexedEntry {
    step: i64,
    id: String,
    text: String,
}

pub struct AntigravityQuestionArchive {
    pub session: String,
    pub file: PathBuf,
    full_file: PathBuf,
    full_offset: u64,
    reading_full: bool,
    skip_through_step: Option<i64>,
    offset: u64,
    pending: Vec<u8>,
    seen: HashSet<String>,
    reasoning: Vec<IndexedEntry>,
    errors: Vec<IndexedEntry>,
    pub last_error_step: Option<i64>,
}

impl AntigravityQuestionArchive {
    pub fn open(session: &str, home: &Path, skip_existing: bool) -> Option<Self> {
        if Uuid::parse_str(session).is_err() {
            return None;
        }
        let dir = home
            .join(".gemini/antigravity-cli/brain")
            .join(session)
            .join(".system_generated/logs");
        let file = dir.join("transcript.jsonl");
        let full_file = dir.join("transcript_full.jsonl");
        let mut offset = 0u64;
        let mut full_offset = 0u64;
        let mut skip_through_step = None;
        if skip_existing {
            offset = std::fs::metadata(&file).map(|m| m.len()).unwrap_or(0);
            full_offset = std::fs::metadata(&full_file).map(|m| m.len()).unwrap_or(0);
            if !full_file.exists()
                && let Ok(bytes) = std::fs::read(&file)
            {
                skip_through_step = bytes
                    .split(|&b| b == b'\n')
                    .filter_map(|line| {
                        serde_json::from_slice::<Value>(line)
                            .ok()?
                            .get("step_index")?
                            .as_i64()
                    })
                    .max();
            }
        }
        Some(Self {
            session: session.to_string(),
            file,
            full_file,
            full_offset,
            reading_full: false,
            skip_through_step,
            offset,
            pending: Vec::new(),
            seen: HashSet::new(),
            reasoning: Vec::new(),
            errors: Vec::new(),
            last_error_step: None,
        })
    }

    pub fn take_errors(&mut self, through: Option<i64>) -> Vec<(String, String)> {
        Self::take_entries(&mut self.errors, through)
    }

    pub fn take_reasoning(&mut self, through: Option<i64>) -> Vec<(String, String)> {
        Self::take_entries(&mut self.reasoning, through)
    }

    fn take_entries(list: &mut Vec<IndexedEntry>, through: Option<i64>) -> Vec<(String, String)> {
        let limit = through.unwrap_or(i64::MAX);
        let mut ready = Vec::new();
        list.retain(|e| {
            if e.step <= limit {
                ready.push((e.id.clone(), e.text.clone()));
                false
            } else {
                true
            }
        });
        ready
    }

    pub fn read(&mut self, is_final: bool) -> Result<Vec<AgentQuestion>, String> {
        if !self.reading_full && self.full_file.exists() {
            self.reading_full = true;
            self.offset = self.full_offset;
            self.pending.clear();
        }
        let source = if self.reading_full {
            &self.full_file
        } else {
            &self.file
        };
        if !source.exists() {
            return Ok(Vec::new());
        }
        let mut handle = File::open(source).map_err(|e| e.to_string())?;
        let end = handle.seek(SeekFrom::End(0)).map_err(|e| e.to_string())?;
        if end < self.offset {
            return Err("Corrupt Antigravity archive".into());
        }
        handle
            .seek(SeekFrom::Start(self.offset))
            .map_err(|e| e.to_string())?;
        let mut questions = Vec::new();
        while self.offset < end {
            let chunk_len = ((end - self.offset) as usize).min(65_536);
            let mut buf = vec![0u8; chunk_len];
            let n = handle.read(&mut buf).map_err(|e| e.to_string())?;
            if n == 0 {
                return Err("Truncated Antigravity archive".into());
            }
            self.offset += n as u64;
            self.pending.extend_from_slice(&buf[..n]);
            while let Some(nl) = self.pending.iter().position(|&b| b == b'\n') {
                let line: Vec<u8> = self.pending.drain(..=nl).take(nl).collect();
                questions.extend(self.parse_line(&line)?);
            }
        }
        if is_final && !self.pending.is_empty() {
            return Err("Incomplete final archive line".into());
        }
        Ok(questions)
    }

    fn parse_line(&mut self, line: &[u8]) -> Result<Vec<AgentQuestion>, String> {
        if line.is_empty() {
            return Ok(Vec::new());
        }
        let row: Value = serde_json::from_slice(line).map_err(|e| e.to_string())?;
        if !matches!(row.get("status").and_then(Value::as_str), Some("DONE" | "ERROR")) {
            return Ok(Vec::new());
        }
        let Some(step) = row.get("step_index").and_then(Value::as_i64) else {
            return Ok(Vec::new());
        };
        if self.skip_through_step.is_some_and(|s| step <= s) {
            return Ok(Vec::new());
        }
        let row_type = row.get("type").and_then(Value::as_str);
        if row_type == Some("ERROR_MESSAGE")
            || (row_type == Some("GENERIC") && row.get("status").and_then(Value::as_str) == Some("ERROR"))
        {
            self.last_error_step = Some(self.last_error_step.map_or(step, |p| p.max(step)));
            let id = format!("antigravity/{}/{step}/error", self.session);
            if let Some(text) = AntigravityTranscript::error_text(&row)
                && !text.is_empty()
                && self.seen.insert(id.clone())
            {
                self.errors.push(IndexedEntry { step, id, text });
            }
        }
        if row_type != Some("PLANNER_RESPONSE") {
            return Ok(Vec::new());
        }
        let thinking_id = format!("antigravity/{}/{step}/thinking", self.session);
        if let Some(thinking) = row.get("thinking").and_then(Value::as_str)
            && !thinking.is_empty()
            && self.seen.insert(thinking_id.clone())
        {
            self.reasoning.push(IndexedEntry {
                step,
                id: thinking_id,
                text: thinking.to_string(),
            });
        }
        let Some(calls) = row.get("tool_calls").and_then(Value::as_array) else {
            return Ok(Vec::new());
        };
        let mut out = Vec::new();
        for (idx, call) in calls.iter().enumerate() {
            let id = format!("antigravity/{}/{step}/{idx}", self.session);
            let Some(tool) = call.get("name").and_then(Value::as_str) else {
                continue;
            };
            let args = call.get("args").unwrap_or(&Value::Null);
            if let Some(q) = QuestionRequest::antigravity(tool, args, &id)
                && self.seen.insert(id)
            {
                out.push(q);
            }
        }
        Ok(out)
    }
}
