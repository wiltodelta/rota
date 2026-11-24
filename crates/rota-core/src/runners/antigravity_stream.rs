use std::collections::HashSet;

use serde_json::Value;

use crate::model::serde_ext::to_sorted_compact_string;
use crate::model::{RunOutcome, SessionConfiguration};
use crate::transcript::TranscriptItemKind;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AntigravityEvent {
    Session(String),
    Configuration(SessionConfiguration),
    Text(String),
    TextStarted(Option<i64>),
    TextEnded(Option<i64>),
    Item {
        kind: TranscriptItemKind,
        text: String,
        step: Option<i64>,
    },
    Result(RunOutcome),
    UnknownStep,
}

#[derive(Default)]
pub struct AntigravityStream {
    had_text: bool,
    completed_response: bool,
    pub recovered_stale_error: bool,
    tools: HashSet<i64>,
    subagents: HashSet<String>,
    text_step: Option<i64>,
    writing_text: bool,
}

impl AntigravityStream {
    pub fn events(&mut self, data: &[u8]) -> Vec<AntigravityEvent> {
        let Ok(obj) = serde_json::from_slice::<Value>(data) else {
            let text = String::from_utf8_lossy(data).trim().to_string();
            return if text.is_empty() {
                Vec::new()
            } else {
                vec![AntigravityEvent::Item {
                    kind: TranscriptItemKind::Error,
                    text,
                    step: None,
                }]
            };
        };
        let Some(ev) = obj.get("event").and_then(Value::as_str) else {
            let text = String::from_utf8_lossy(data).trim().to_string();
            return if text.is_empty() {
                Vec::new()
            } else {
                vec![AntigravityEvent::Item {
                    kind: TranscriptItemKind::Error,
                    text,
                    step: None,
                }]
            };
        };
        match ev {
            "init" => {
                let mut out = Vec::new();
                if let Some(id) = obj.get("conversation_id").and_then(Value::as_str)
                    && !id.is_empty()
                {
                    out.push(AntigravityEvent::Session(id.to_string()));
                }
                let init = obj.get("init");
                out.push(AntigravityEvent::Configuration(SessionConfiguration::new(
                    init.and_then(|i| i.get("model"))
                        .and_then(Value::as_str)
                        .map(ToOwned::to_owned),
                    init.and_then(|i| i.get("effort"))
                        .and_then(Value::as_str)
                        .map(ToOwned::to_owned),
                    None,
                    None,
                )));
                out
            }
            "step_update" => self.step(obj.get("step_update").unwrap_or(&Value::Null)),
            "result" => self.result(obj.get("result").unwrap_or(&Value::Null)),
            _ => Vec::new(),
        }
    }

    fn step(&mut self, step: &Value) -> Vec<AntigravityEvent> {
        self.completed_response = false;
        self.recovered_stale_error = false;
        match step.get("step_type").and_then(Value::as_str) {
            Some("unknown") => vec![AntigravityEvent::UnknownStep],
            Some("agent_response") => self.response(step),
            Some("subagent") => self.subagent(step),
            Some("tool") => {
                let Some(idx) = step.get("step_index").and_then(Value::as_i64) else {
                    return Vec::new();
                };
                let info = step.get("tool_info").unwrap_or(&Value::Null);
                let mut out = Vec::new();
                if self.tools.insert(idx) {
                    let name = step
                        .get("tool_name")
                        .or_else(|| info.get("name"))
                        .and_then(Value::as_str)
                        .unwrap_or("tool");
                    let params = info
                        .get("parameters")
                        .filter(|p| p.as_object().is_some_and(|m| !m.is_empty()))
                        .and_then(|p| to_sorted_compact_string(p).ok())
                        .unwrap_or_default();
                    let title = if params.is_empty() {
                        name.to_string()
                    } else {
                        format!("{name} {params}")
                    };
                    out.push(AntigravityEvent::Item {
                        kind: TranscriptItemKind::Tool,
                        text: title,
                        step: Some(idx),
                    });
                }
                if matches!(step.get("state").and_then(Value::as_str), Some("DONE" | "ERROR")) {
                    let err_msg = info
                        .get("error")
                        .and_then(|e| e.get("message"))
                        .and_then(Value::as_str);
                    if let Some(output) = info.get("output").and_then(Value::as_str)
                        && !output.is_empty()
                        && Some(output) != err_msg
                    {
                        out.push(AntigravityEvent::Item {
                            kind: TranscriptItemKind::Output,
                            text: output.to_string(),
                            step: Some(idx),
                        });
                    }
                    if let Some(msg) = err_msg
                        && !msg.is_empty()
                    {
                        out.push(AntigravityEvent::Item {
                            kind: TranscriptItemKind::Error,
                            text: msg.to_string(),
                            step: Some(idx),
                        });
                    }
                }
                out
            }
            _ => Vec::new(),
        }
    }

    fn response(&mut self, step: &Value) -> Vec<AntigravityEvent> {
        let idx = step.get("step_index").and_then(Value::as_i64);
        let mut out = Vec::new();
        if !self.writing_text || self.text_step != idx {
            out.push(AntigravityEvent::TextStarted(idx));
            self.text_step = idx;
            self.writing_text = true;
        }
        if let Some(delta) = step.get("text_delta").and_then(Value::as_str)
            && !delta.is_empty()
        {
            self.had_text = true;
            out.push(AntigravityEvent::Text(delta.to_string()));
        }
        if step.get("state").and_then(Value::as_str) == Some("DONE") {
            self.writing_text = false;
            self.completed_response = true;
            out.push(AntigravityEvent::TextEnded(idx));
        }
        out
    }

    fn subagent(&mut self, step: &Value) -> Vec<AntigravityEvent> {
        let Some(agents) = step
            .get("subagent_info")
            .and_then(|i| i.get("subagents"))
            .and_then(Value::as_array)
        else {
            return Vec::new();
        };
        let status = if step.get("state").and_then(Value::as_str) == Some("ERROR") {
            "failed to start"
        } else {
            "started"
        };
        let step_idx = step.get("step_index").and_then(Value::as_i64);
        agents
            .iter()
            .filter_map(|a| {
                let id = a.get("conversation_id").and_then(Value::as_str)?;
                if !self.subagents.insert(format!("{id}/{status}")) {
                    return None;
                }
                let role = a.get("role").and_then(Value::as_str).unwrap_or(id);
                Some(AntigravityEvent::Item {
                    kind: TranscriptItemKind::Status,
                    text: format!("Agent {role}: {status}"),
                    step: step_idx,
                })
            })
            .collect()
    }

    fn result(&mut self, res: &Value) -> Vec<AntigravityEvent> {
        let mut out = Vec::new();
        if let Some(id) = res.get("conversation_id").and_then(Value::as_str)
            && !id.is_empty()
        {
            out.push(AntigravityEvent::Session(id.to_string()));
        }
        if !self.had_text
            && let Some(resp) = res.get("response").and_then(Value::as_str)
            && !resp.is_empty()
        {
            out.push(AntigravityEvent::Text(resp.to_string()));
        }
        let status = res.get("status").and_then(Value::as_str);
        let reason = res.get("finished_reason").and_then(Value::as_str).unwrap_or("");
        let err_str = res.get("error").and_then(Value::as_str);
        self.recovered_stale_error = self.completed_response
            && status == Some("ERROR")
            && matches!(reason, "" | "error")
            && err_str.is_some_and(|s| !s.is_empty());
        self.had_text = false;
        self.completed_response = false;
        self.writing_text = false;
        let (outcome, err_note) = if self.recovered_stale_error {
            (RunOutcome::Succeeded, None)
        } else {
            Self::outcome(status, reason, err_str)
        };
        if let Some(err) = err_note {
            out.push(AntigravityEvent::Item {
                kind: TranscriptItemKind::Error,
                text: err,
                step: None,
            });
        }
        out.push(AntigravityEvent::Result(outcome));
        out
    }

    fn outcome(status: Option<&str>, reason: &str, error: Option<&str>) -> (RunOutcome, Option<String>) {
        match (reason, status) {
            ("", Some("SUCCESS")) => (RunOutcome::Succeeded, None),
            ("", Some("CANCELED")) => (RunOutcome::Cancelled, None),
            ("", Some("INTERRUPTED")) => (RunOutcome::Interrupted, None),
            ("", st) => (
                RunOutcome::Failed { exit_code: 1 },
                Some(error.map(ToOwned::to_owned).unwrap_or_else(|| {
                    format!("Antigravity ended with status {}.", st.unwrap_or("missing"))
                })),
            ),
            ("print_timeout", _) => (
                RunOutcome::TimedOut,
                Some("Antigravity's print time limit expired. The answer is partial.".into()),
            ),
            ("interrupted", _) => (
                RunOutcome::Interrupted,
                Some("Antigravity interrupted the turn. The answer is partial.".into()),
            ),
            ("error", _) => (
                RunOutcome::Failed { exit_code: 1 },
                Some(
                    error
                        .map(ToOwned::to_owned)
                        .unwrap_or_else(|| "Antigravity ended the turn with an error.".into()),
                ),
            ),
            (other, _) => (
                RunOutcome::Failed { exit_code: 1 },
                Some(format!(
                    "Antigravity ended the turn early ({other}). The answer may be incomplete."
                )),
            ),
        }
    }
}
