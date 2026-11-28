use serde_json::Value;

use crate::model::{Harness, SessionConfiguration, TerminalState};
use crate::runners::{
    AntigravityTranscript, ClaudeTranscript, GrokAcpRun, GrokToolOutput, NativeTranscript,
    NativeTranscriptEvent, StreamJsonFormatter, SubagentStatus,
};
use crate::transcript::{ToolOutput, TranscriptItemKind};

impl NativeTranscript {
    pub fn events(data: &[u8], harness: Harness) -> Result<Vec<NativeTranscriptEvent>, String> {
        let entry: Value = serde_json::from_slice(data).map_err(|e| e.to_string())?;
        Ok(match harness {
            Harness::Claude => Self::claude(data, &entry),
            Harness::Codex => Self::codex(&entry),
            Harness::Grok => Self::grok(&entry),
            Harness::Antigravity => AntigravityTranscript::events(&entry),
            Harness::Shell => Vec::new(),
        })
    }

    fn claude(data: &[u8], entry: &Value) -> Vec<NativeTranscriptEvent> {
        match ClaudeTranscript::read(data) {
            ClaudeTranscript::User(text) | ClaudeTranscript::Queued(text) => vec![
                NativeTranscriptEvent::Item(TranscriptItemKind::User, text),
                NativeTranscriptEvent::State(TerminalState::Working),
            ],
            ClaudeTranscript::Assistant { model, items } => {
                let mut out = vec![NativeTranscriptEvent::Configuration(SessionConfiguration::new(
                    model, None, None, None,
                ))];
                out.extend(
                    items
                        .into_iter()
                        .map(|i| NativeTranscriptEvent::Item(i.kind, i.text)),
                );
                if entry
                    .get("message")
                    .and_then(|m| m.get("stop_reason"))
                    .and_then(Value::as_str)
                    == Some("end_turn")
                {
                    out.push(NativeTranscriptEvent::State(TerminalState::Waiting));
                }
                if let Some(eff) = entry.get("perTurnEffort").and_then(Value::as_str) {
                    out.push(NativeTranscriptEvent::Configuration(SessionConfiguration::new(
                        None,
                        Some(eff.to_string()),
                        None,
                        None,
                    )));
                }
                out
            }
            ClaudeTranscript::Service(text) => {
                vec![NativeTranscriptEvent::Item(TranscriptItemKind::Status, text)]
            }
            ClaudeTranscript::ApiError(text) => vec![
                NativeTranscriptEvent::Item(TranscriptItemKind::Error, text),
                NativeTranscriptEvent::State(TerminalState::Waiting),
            ],
            ClaudeTranscript::TurnEnded => {
                vec![NativeTranscriptEvent::State(TerminalState::Waiting)]
            }
            ClaudeTranscript::Background { .. } | ClaudeTranscript::Other => StreamJsonFormatter::items(data)
                .into_iter()
                .map(|i| NativeTranscriptEvent::Item(i.kind, i.text))
                .collect(),
        }
    }

    pub(super) fn codex(entry: &Value) -> Vec<NativeTranscriptEvent> {
        let Some(payload) = entry.get("payload") else {
            return Vec::new();
        };
        match entry.get("type").and_then(Value::as_str) {
            Some("turn_context") => vec![NativeTranscriptEvent::Configuration(SessionConfiguration::new(
                payload
                    .get("model")
                    .and_then(Value::as_str)
                    .map(ToOwned::to_owned),
                payload
                    .get("effort")
                    .and_then(Value::as_str)
                    .map(ToOwned::to_owned),
                None,
                None,
            ))],
            Some("event_msg") => match payload.get("type").and_then(Value::as_str) {
                Some("task_started") => vec![NativeTranscriptEvent::State(TerminalState::Working)],
                Some("task_complete" | "turn_aborted") => {
                    vec![NativeTranscriptEvent::State(TerminalState::Waiting)]
                }
                Some("item_completed") => {
                    let Some(item) = payload.get("item") else {
                        return Vec::new();
                    };
                    if item.get("type").and_then(Value::as_str) != Some("UserMessage") {
                        return Vec::new();
                    }
                    Self::extract_text(item)
                        .map(|t| vec![NativeTranscriptEvent::Item(TranscriptItemKind::User, t)])
                        .unwrap_or_default()
                }
                _ => Vec::new(),
            },
            Some("response_item") => match payload.get("type").and_then(Value::as_str) {
                Some("reasoning") => payload
                    .get("summary")
                    .and_then(Value::as_array)
                    .map(|arr| {
                        arr.iter()
                            .filter_map(|b| {
                                b.get("text").and_then(Value::as_str).map(|t| {
                                    NativeTranscriptEvent::Item(TranscriptItemKind::Reasoning, t.to_string())
                                })
                            })
                            .collect()
                    })
                    .unwrap_or_default(),
                Some("function_call_output" | "custom_tool_call_output") => {
                    ToolOutput::content(payload.get("output"))
                        .map(|t| vec![NativeTranscriptEvent::Item(TranscriptItemKind::Output, t)])
                        .unwrap_or_default()
                }
                Some("message") if payload.get("role").and_then(Value::as_str) == Some("assistant") => {
                    Self::extract_text(payload)
                        .map(|t| vec![NativeTranscriptEvent::Item(TranscriptItemKind::Agent, t)])
                        .unwrap_or_default()
                }
                Some("function_call" | "custom_tool_call") => payload
                    .get("name")
                    .and_then(Value::as_str)
                    .map(|n| vec![NativeTranscriptEvent::Item(TranscriptItemKind::Tool, n.into())])
                    .unwrap_or_default(),
                _ => Vec::new(),
            },
            _ => Vec::new(),
        }
    }

    fn grok(entry: &Value) -> Vec<NativeTranscriptEvent> {
        let Some(method) = entry.get("method").and_then(Value::as_str) else {
            return Vec::new();
        };
        if method != "session/update" && method != "_x.ai/session/update" {
            return Vec::new();
        }
        let Some(params) = entry.get("params") else {
            return Vec::new();
        };
        let Some(update) = params.get("update") else {
            return Vec::new();
        };
        match update.get("sessionUpdate").and_then(Value::as_str) {
            Some("user_message_chunk" | "agent_message_chunk" | "agent_thought_chunk") => {
                let Some(content) = update.get("content") else {
                    return Vec::new();
                };
                if content.get("type").and_then(Value::as_str) != Some("text") {
                    return Vec::new();
                }
                let Some(text) = content.get("text").and_then(Value::as_str) else {
                    return Vec::new();
                };
                if update.get("sessionUpdate").and_then(Value::as_str) == Some("user_message_chunk") {
                    let model = update
                        .get("_meta")
                        .and_then(|m| m.get("modelId"))
                        .and_then(Value::as_str)
                        .map(ToOwned::to_owned);
                    return vec![
                        NativeTranscriptEvent::Configuration(SessionConfiguration::new(
                            model, None, None, None,
                        )),
                        NativeTranscriptEvent::Item(TranscriptItemKind::User, text.to_string()),
                        NativeTranscriptEvent::State(TerminalState::Working),
                    ];
                }
                let thought =
                    update.get("sessionUpdate").and_then(Value::as_str) == Some("agent_thought_chunk");
                let kind = if thought {
                    TranscriptItemKind::Reasoning
                } else {
                    TranscriptItemKind::Agent
                };
                let nid = GrokAcpRun::text_id(params, params.get("sessionId").and_then(Value::as_str), kind);
                vec![NativeTranscriptEvent::Chunk {
                    text: text.to_string(),
                    kind,
                    native_id: nid,
                }]
            }
            Some("subagent_spawned" | "subagent_finished") => SubagentStatus::grok(update)
                .map(|t| vec![NativeTranscriptEvent::Item(TranscriptItemKind::Status, t)])
                .unwrap_or_default(),
            Some("config_option_update") => {
                vec![NativeTranscriptEvent::Configuration(SessionConfiguration::acp(
                    update,
                ))]
            }
            Some("turn_completed") => vec![NativeTranscriptEvent::State(TerminalState::Waiting)],
            Some("tool_call" | "tool_call_update") => {
                let mut out = Vec::new();
                if update.get("sessionUpdate").and_then(Value::as_str) == Some("tool_call") {
                    let title = update.get("title").and_then(Value::as_str).unwrap_or("Tool");
                    out.push(NativeTranscriptEvent::Item(
                        TranscriptItemKind::Tool,
                        title.to_string(),
                    ));
                }
                if let Some(arr) = update.get("content").and_then(Value::as_array) {
                    for b in arr {
                        if let Some(txt) = GrokToolOutput::text(b) {
                            out.push(NativeTranscriptEvent::Item(TranscriptItemKind::Output, txt));
                        }
                    }
                }
                out
            }
            _ => Vec::new(),
        }
    }

    fn extract_text(msg: &Value) -> Option<String> {
        let parts: Vec<&str> = msg
            .get("content")?
            .as_array()?
            .iter()
            .filter_map(|b| b.get("text").and_then(Value::as_str))
            .collect();
        (!parts.is_empty()).then(|| parts.join("\n"))
    }
}
