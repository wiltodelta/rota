use std::collections::{HashMap, HashSet};

use serde_json::Value;

use crate::model::{AgentQuestion, QuestionAnswer, QuestionReceipt, QuestionRequest};
use crate::transcript::{ToolOutput, ToolOutputPart, TranscriptItemKind};

#[derive(Default)]
pub struct CodexAsyncQuestions {
    known: HashMap<String, AgentQuestion>,
    answers: HashMap<String, Vec<QuestionReceipt>>,
    pending: HashMap<String, usize>,
    asked: HashSet<String>,
    held: Option<Vec<String>>,
}

impl CodexAsyncQuestions {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn hold(&mut self) {
        self.held = Some(Vec::new());
    }

    pub fn note_answer(&mut self, text: &str) -> Option<String> {
        let (id, receipt) = QuestionReceipt::answer(text)?;
        let list = self.answers.entry(id.clone()).or_default();
        if !list.contains(&receipt) {
            list.push(receipt.clone());
        }
        self.known
            .get(&id)
            .filter(|q| Self::matches(&receipt, q))
            .map(|_| id)
    }

    pub fn sending(&mut self, text: &str) {
        if QuestionReceipt::answer(text).is_some() {
            *self.pending.entry(text.to_string()).or_default() += 1;
        }
    }

    pub fn delivered(&mut self, text: &str) -> Option<String> {
        self.remove_pending(text);
        self.note_answer(text)
    }

    pub fn note_answers_in_item(&mut self, item: &Value) -> Vec<String> {
        if item.get("type").and_then(Value::as_str) != Some("userMessage") {
            return Vec::new();
        }
        let Some(arr) = item.get("content").and_then(Value::as_array) else {
            return Vec::new();
        };
        arr.iter()
            .filter_map(|b| {
                if b.get("type").and_then(Value::as_str) != Some("text") {
                    return None;
                }
                let text = b.get("text").and_then(Value::as_str)?;
                self.note_answer(text)
            })
            .collect()
    }

    pub fn closed(&self) -> Vec<String> {
        self.known
            .values()
            .filter(|q| {
                self.answers
                    .get(&q.id)
                    .is_some_and(|list| list.iter().any(|r| Self::matches(r, q)))
            })
            .map(|q| q.id.clone())
            .collect()
    }

    pub fn offer(&mut self, question: AgentQuestion) -> Option<AgentQuestion> {
        let id = question.id.clone();
        self.known.insert(id.clone(), question);
        if let Some(ids) = &mut self.held {
            if !ids.contains(&id) {
                ids.push(id);
            }
            return None;
        }
        self.take(&id)
    }

    pub fn restored(&mut self) -> Vec<AgentQuestion> {
        let ids = self.held.take().unwrap_or_default();
        ids.into_iter().filter_map(|id| self.take(&id)).collect()
    }

    pub fn undelivered(&mut self, text: &str) -> Option<AgentQuestion> {
        let (id, _) = QuestionReceipt::answer(text)?;
        self.remove_pending(text);
        self.asked.remove(&id);
        if self.held.is_none() { self.take(&id) } else { None }
    }

    fn remove_pending(&mut self, text: &str) {
        if let Some(c) = self.pending.get_mut(text) {
            if *c > 1 {
                *c -= 1;
            } else {
                self.pending.remove(text);
            }
        }
    }

    fn matches(receipt: &QuestionReceipt, question: &AgentQuestion) -> bool {
        if receipt.questions.len() != question.fields.len() {
            return false;
        }
        if !receipt
            .questions
            .iter()
            .zip(&question.fields)
            .all(|(r, f)| r.question == f.title)
        {
            return false;
        }
        let values: HashMap<String, Vec<String>> = question
            .fields
            .iter()
            .zip(&receipt.questions)
            .map(|(f, r)| (f.id.clone(), r.answers.clone()))
            .collect();
        question
            .validate(&QuestionAnswer::new(&receipt.action, values))
            .is_ok()
    }

    fn is_answered(&self, question: &AgentQuestion) -> bool {
        if self
            .answers
            .get(&question.id)
            .is_some_and(|list| list.iter().any(|r| Self::matches(r, question)))
        {
            return true;
        }
        self.pending.keys().any(|text| {
            QuestionReceipt::answer(text)
                .is_some_and(|(id, rec)| id == question.id && Self::matches(&rec, question))
        })
    }

    fn take(&mut self, id: &str) -> Option<AgentQuestion> {
        if self.asked.contains(id) {
            return None;
        }
        let q = self.known.get(id)?.clone();
        if self.is_answered(&q) {
            return None;
        }
        self.asked.insert(id.to_string());
        Some(q)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct CodexOutputEntry {
    pub kind: TranscriptItemKind,
    pub text: String,
    pub suffix: String,
}

pub struct CodexItemOutput;

impl CodexItemOutput {
    pub fn entries(item: &Value) -> Vec<CodexOutputEntry> {
        let mut out = Vec::new();
        if let Some(agg) = item.get("aggregatedOutput").and_then(Value::as_str)
            && !agg.is_empty()
        {
            out.push(CodexOutputEntry {
                kind: TranscriptItemKind::Output,
                text: agg.to_string(),
                suffix: "/output".to_string(),
            });
        }
        let content = item
            .get("result")
            .and_then(|r| r.get("content"))
            .or_else(|| item.get("contentItems"))
            .and_then(Value::as_array);
        if let Some(blocks) = content {
            for (idx, block) in blocks.iter().enumerate() {
                let single = Value::Array(vec![block.clone()]);
                if let Some(text) = ToolOutput::content(Some(&single)) {
                    out.push(CodexOutputEntry {
                        kind: TranscriptItemKind::Output,
                        text,
                        suffix: format!("/content/{idx}"),
                    });
                }
            }
        }
        out.extend(Self::specialized(item));
        out
    }

    fn specialized(item: &Value) -> Vec<CodexOutputEntry> {
        match item.get("type").and_then(Value::as_str) {
            Some("functionCallOutput") => ToolOutput::content(item.get("output"))
                .map(|text| {
                    vec![CodexOutputEntry {
                        kind: TranscriptItemKind::Output,
                        text,
                        suffix: "/output".into(),
                    }]
                })
                .unwrap_or_default(),
            Some("fileChange") => {
                let parts: Vec<ToolOutputPart> = item
                    .get("changes")
                    .and_then(Value::as_array)
                    .map(|arr| {
                        arr.iter()
                            .filter_map(|ch| {
                                Some(ToolOutputPart::diff(
                                    ch.get("path")?.as_str()?,
                                    ch.get("diff")?.as_str()?,
                                ))
                            })
                            .collect()
                    })
                    .unwrap_or_default();
                if parts.is_empty() {
                    Vec::new()
                } else {
                    vec![CodexOutputEntry {
                        kind: TranscriptItemKind::Output,
                        text: ToolOutput { parts }.encoded(),
                        suffix: "/diff".into(),
                    }]
                }
            }
            Some("imageView") => item
                .get("path")
                .and_then(Value::as_str)
                .map(|p| {
                    vec![CodexOutputEntry {
                        kind: TranscriptItemKind::Output,
                        text: ToolOutput::image_encoded(&format!("file://{p}"), "Viewed image"),
                        suffix: "/image".into(),
                    }]
                })
                .unwrap_or_default(),
            Some("imageGeneration") => {
                let mut res = Vec::new();
                if let Some(p) = item.get("savedPath").and_then(Value::as_str)
                    && !p.is_empty()
                {
                    res.push(CodexOutputEntry {
                        kind: TranscriptItemKind::Output,
                        text: ToolOutput::image_encoded(&format!("file://{p}"), "Generated image"),
                        suffix: "/image".into(),
                    });
                } else if let Some(d) = item.get("result").and_then(Value::as_str)
                    && !d.is_empty()
                {
                    let url = if d.starts_with("data:") {
                        d.to_string()
                    } else {
                        format!("data:image/png;base64,{d}")
                    };
                    res.push(CodexOutputEntry {
                        kind: TranscriptItemKind::Output,
                        text: ToolOutput::image_encoded(&url, "Generated image"),
                        suffix: "/image".into(),
                    });
                }
                if let Some(fail) = item.get("failure")
                    && fail.is_object()
                {
                    let msg = fail
                        .get("message")
                        .and_then(Value::as_str)
                        .map(ToOwned::to_owned)
                        .unwrap_or_else(|| QuestionRequest::json(fail));
                    res.push(CodexOutputEntry {
                        kind: TranscriptItemKind::Error,
                        text: msg,
                        suffix: "/error".into(),
                    });
                }
                res
            }
            Some("subAgentActivity") => Self::activity(item)
                .map(|text| {
                    vec![CodexOutputEntry {
                        kind: TranscriptItemKind::Status,
                        text,
                        suffix: "/activity".into(),
                    }]
                })
                .unwrap_or_default(),
            Some("collabAgentToolCall") => {
                let Some(states) = item.get("agentsStates").and_then(Value::as_object) else {
                    return Vec::new();
                };
                let mut keys: Vec<&String> = states.keys().collect();
                keys.sort();
                keys.into_iter()
                    .filter_map(|id| {
                        let status = states[id].get("status")?.as_str()?;
                        let mapped = match status {
                            "pendingInit" | "running" => "working",
                            "errored" => "failed",
                            other => other,
                        };
                        Some(CodexOutputEntry {
                            kind: TranscriptItemKind::Status,
                            text: format!("Agent {id}: {mapped}"),
                            suffix: format!("/agent/{id}"),
                        })
                    })
                    .collect()
            }
            _ => Vec::new(),
        }
    }

    pub fn activity(item: &Value) -> Option<String> {
        let kind = item.get("kind")?.as_str()?;
        let label = item
            .get("agentPath")
            .or_else(|| item.get("agentThreadId"))
            .and_then(Value::as_str)
            .unwrap_or("Subagent");
        let status = match kind {
            "started" => "working",
            "completed" => "completed",
            "interrupted" => "interrupted",
            _ => return None,
        };
        Some(format!("Agent {label}: {status}"))
    }

    pub fn verifications(values: Option<&Value>) -> Vec<CodexOutputEntry> {
        let Some(arr) = values.and_then(Value::as_array) else {
            return Vec::new();
        };
        let mut seen = HashSet::new();
        arr.iter()
            .filter_map(|raw| {
                let val = raw.as_str()?.trim();
                if val.is_empty() || !seen.insert(val.to_string()) {
                    return None;
                }
                let text = if val == "trustedAccessForCyber" {
                    "Codex requires Trusted Access for Cyber verification for this turn.".to_string()
                } else {
                    format!("Codex reported an unsupported model verification requirement ({val}).")
                };
                Some(CodexOutputEntry {
                    kind: TranscriptItemKind::Status,
                    text,
                    suffix: format!("/verification/{val}"),
                })
            })
            .collect()
    }
}
