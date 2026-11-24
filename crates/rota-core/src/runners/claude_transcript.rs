use jiff::Timestamp;
use serde_json::Value;

use crate::model::serde_ext::parse_iso_timestamp;
use crate::runners::StreamJsonFormatter;
use crate::transcript::{TranscriptItem, TranscriptService};

#[derive(Debug, Clone)]
pub struct ClaudeToolCall {
    pub id: String,
    pub name: String,
    pub input: Value,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ClaudeTranscript {
    User(String),
    Queued(String),
    Service(String),
    Background {
        id: String,
        running: bool,
    },
    Assistant {
        model: Option<String>,
        items: Vec<TranscriptItem>,
    },
    ApiError(String),
    TurnEnded,
    Other,
}

impl ClaudeTranscript {
    pub fn moves_on(&self) -> bool {
        matches!(
            self,
            Self::User(_) | Self::Queued(_) | Self::Assistant { .. } | Self::TurnEnded
        )
    }

    pub fn timestamp(entry: &Value) -> Option<Timestamp> {
        parse_iso_timestamp(entry.get("timestamp")?.as_str()?)
    }

    pub fn tool_calls(entry: &Value) -> (Vec<ClaudeToolCall>, Vec<String>) {
        let Some(blocks) = entry
            .get("message")
            .and_then(|m| m.get("content"))
            .and_then(Value::as_array)
        else {
            return (Vec::new(), Vec::new());
        };
        match entry.get("type").and_then(Value::as_str) {
            Some("assistant") => {
                let started = blocks
                    .iter()
                    .filter_map(|b| {
                        if b.get("type").and_then(Value::as_str) != Some("tool_use") {
                            return None;
                        }
                        Some(ClaudeToolCall {
                            id: b.get("id")?.as_str()?.to_string(),
                            name: b.get("name")?.as_str()?.to_string(),
                            input: b.get("input").cloned().unwrap_or(Value::Null),
                        })
                    })
                    .collect();
                (started, Vec::new())
            }
            Some("user") => {
                let ended = blocks
                    .iter()
                    .filter(|b| b.get("type").and_then(Value::as_str) == Some("tool_result"))
                    .filter_map(|b| {
                        b.get("tool_use_id")
                            .and_then(Value::as_str)
                            .map(ToOwned::to_owned)
                    })
                    .collect();
                (Vec::new(), ended)
            }
            _ => (Vec::new(), Vec::new()),
        }
    }

    pub fn read(data: &[u8]) -> Self {
        serde_json::from_slice::<Value>(data)
            .ok()
            .map_or(Self::Other, |v| Self::read_entry(&v))
    }

    pub fn read_entry(entry: &Value) -> Self {
        match entry.get("type").and_then(Value::as_str) {
            Some("user") => {
                Self::background_task(entry.get("toolUseResult")).unwrap_or_else(|| Self::user_entry(entry))
            }
            Some("attachment") => {
                let Some(att) = entry.get("attachment") else {
                    return Self::Other;
                };
                if att.get("type").and_then(Value::as_str) != Some("queued_command") {
                    return Self::Other;
                }
                let Some(text) = att.get("prompt").and_then(Value::as_str) else {
                    return Self::Other;
                };
                if TranscriptService::title(text).is_none() {
                    Self::Queued(text.to_string())
                } else {
                    Self::Service(text.to_string())
                }
            }
            Some("assistant") => {
                let msg = entry.get("message");
                if entry.get("isApiErrorMessage").and_then(Value::as_bool) == Some(true) {
                    let text = msg
                        .and_then(|m| m.get("content"))
                        .and_then(Value::as_array)
                        .map(|arr| {
                            arr.iter()
                                .filter_map(|b| b.get("text").and_then(Value::as_str))
                                .collect::<Vec<_>>()
                                .join(" ")
                        })
                        .filter(|s| !s.is_empty())
                        .unwrap_or_else(|| "Claude could not answer.".to_string());
                    return Self::ApiError(text);
                }
                let model = msg
                    .and_then(|m| m.get("model"))
                    .and_then(Value::as_str)
                    .filter(|&m| m != "<synthetic>")
                    .map(ToOwned::to_owned);
                Self::Assistant {
                    model,
                    items: StreamJsonFormatter::assistant_items(entry),
                }
            }
            Some("system") if entry.get("subtype").and_then(Value::as_str) == Some("turn_duration") => {
                Self::TurnEnded
            }
            _ => Self::Other,
        }
    }

    fn background_task(result: Option<&Value>) -> Option<Self> {
        let r = result?.as_object()?;
        if let Some(id) = r.get("backgroundTaskId").and_then(Value::as_str) {
            return Some(Self::Background {
                id: id.to_string(),
                running: true,
            });
        }
        if r.get("status").and_then(Value::as_str) == Some("async_launched")
            && let Some(id) = r.get("agentId").and_then(Value::as_str)
        {
            return Some(Self::Background {
                id: id.to_string(),
                running: true,
            });
        }
        if let Some(id) = r.get("task_id").and_then(Value::as_str)
            && r.get("task_type").is_some_and(Value::is_string)
        {
            return Some(Self::Background {
                id: id.to_string(),
                running: false,
            });
        }
        None
    }

    fn user_entry(entry: &Value) -> Self {
        if entry.get("isMeta").and_then(Value::as_bool) == Some(true) {
            return Self::Other;
        }
        let Some(text) = Self::user_text(entry) else {
            return Self::Other;
        };
        if TranscriptService::title(&text).is_some() {
            return Self::Service(text);
        }
        if text.starts_with("<command-name>") || Self::is_local_command_output(&text) {
            return Self::Other;
        }
        Self::User(text)
    }

    fn is_local_command_output(text: &str) -> bool {
        text.starts_with("<local-command-stdout>") && text.ends_with("</local-command-stdout>")
    }

    pub fn user_text(entry: &Value) -> Option<String> {
        let content = entry.get("message")?.get("content")?;
        if let Some(s) = content.as_str() {
            return Some(s.to_string());
        }
        let parts: Vec<&str> = content
            .as_array()?
            .iter()
            .filter(|b| b.get("type").and_then(Value::as_str) == Some("text"))
            .filter_map(|b| b.get("text").and_then(Value::as_str))
            .collect();
        (!parts.is_empty()).then(|| parts.join("\n"))
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::ClaudeTranscript;

    #[test]
    fn hides_command_echo_and_local_command_stdout_farewell_but_keeps_typed_text() {
        let echo = json!({"type": "user", "message": {"content": "<command-name>/exit</command-name>"}});
        assert_eq!(ClaudeTranscript::read_entry(&echo), ClaudeTranscript::Other);

        let bye = "<local-command-stdout>Bye!</local-command-stdout>";
        let farewell = json!({"type": "user", "message": {"content": bye}});
        assert_eq!(ClaudeTranscript::read_entry(&farewell), ClaudeTranscript::Other);

        let typed = format!("{bye} why?");
        let user_msg = json!({"type": "user", "message": {"content": typed}});
        assert_eq!(
            ClaudeTranscript::read_entry(&user_msg),
            ClaudeTranscript::User(typed)
        );
    }
}
