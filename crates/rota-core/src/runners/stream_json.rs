use serde_json::Value;

use crate::runners::ClaudeTranscript;
use crate::transcript::{
    PlanStep, RunJournal, ToolOutput, ToolStep, TranscriptItem, TranscriptItemKind, TranscriptService,
};

pub struct StreamJsonFormatter;

impl StreamJsonFormatter {
    pub fn format(line: &str) -> Option<String> {
        let trimmed = line.trim();
        if trimmed.is_empty() {
            return None;
        }
        let Ok(event) = serde_json::from_str::<Value>(trimmed) else {
            return Some(trimmed.to_string());
        };
        let Some(kind) = event.get("type").and_then(Value::as_str) else {
            return Some(trimmed.to_string());
        };
        match kind {
            "system" => {
                if event.get("subtype").and_then(Value::as_str) != Some("init") {
                    return None;
                }
                let model = event
                    .get("model")
                    .and_then(Value::as_str)
                    .unwrap_or("unknown model");
                Some(format!("[session started, {model}]"))
            }
            "assistant" => {
                let parts: Vec<String> = Self::assistant_items(&event)
                    .into_iter()
                    .map(|i| RunJournal::readable(i.kind, &i.text))
                    .collect();
                (!parts.is_empty()).then(|| parts.join("\n"))
            }
            "result" => Some(Self::result_text(&event)),
            _ => None,
        }
    }

    pub fn items(data: &[u8]) -> Vec<TranscriptItem> {
        let Ok(event) = serde_json::from_slice::<Value>(data) else {
            return Vec::new();
        };
        let Some(kind) = event.get("type").and_then(Value::as_str) else {
            return Vec::new();
        };
        if kind == "user" {
            if let Some(text) = ClaudeTranscript::user_text(&event)
                && TranscriptService::title(&text).is_some()
            {
                return vec![TranscriptItem::new(0, TranscriptItemKind::Status, text)];
            }
            let Some(blocks) = event
                .get("message")
                .and_then(|m| m.get("content"))
                .and_then(Value::as_array)
            else {
                return Vec::new();
            };
            return blocks
                .iter()
                .enumerate()
                .filter_map(|(idx, b)| {
                    if b.get("type").and_then(Value::as_str) != Some("tool_result") {
                        return None;
                    }
                    ToolOutput::content(b.get("content"))
                        .map(|t| TranscriptItem::new(idx, TranscriptItemKind::Output, t))
                })
                .collect();
        }
        if kind == "assistant" {
            Self::assistant_items(&event)
        } else {
            Vec::new()
        }
    }

    pub fn assistant_items(event: &Value) -> Vec<TranscriptItem> {
        let Some(content) = event
            .get("message")
            .and_then(|m| m.get("content"))
            .and_then(Value::as_array)
        else {
            return Vec::new();
        };
        content
            .iter()
            .enumerate()
            .filter_map(|(idx, item)| match item.get("type").and_then(Value::as_str) {
                Some("thinking") => item
                    .get("thinking")
                    .and_then(Value::as_str)
                    .map(|t| TranscriptItem::new(idx, TranscriptItemKind::Reasoning, t)),
                Some("text") => item
                    .get("text")
                    .and_then(Value::as_str)
                    .map(|t| TranscriptItem::new(idx, TranscriptItemKind::Agent, t)),
                Some("tool_use") => {
                    let name = item.get("name").and_then(Value::as_str).unwrap_or("tool");
                    if name == "TodoWrite"
                        && let Some(todos) = item
                            .get("input")
                            .and_then(|i| i.get("todos"))
                            .and_then(Value::as_array)
                    {
                        let steps: Vec<PlanStep> = todos
                            .iter()
                            .map(|t| {
                                PlanStep::from_raw(
                                    t.get("status").and_then(Value::as_str),
                                    t.get("content").and_then(Value::as_str).unwrap_or(""),
                                )
                            })
                            .collect();
                        return Some(TranscriptItem::new(
                            idx,
                            TranscriptItemKind::Plan,
                            PlanStep::body(&steps),
                        ));
                    }
                    Some(TranscriptItem::new(
                        idx,
                        TranscriptItemKind::Tool,
                        ToolStep::format_call(name, item.get("input")),
                    ))
                }
                _ => None,
            })
            .collect()
    }

    fn result_text(event: &Value) -> String {
        let subtype = event.get("subtype").and_then(Value::as_str).unwrap_or("done");
        let mut line = format!("[result: {subtype}");
        if let Some(ms) = event.get("duration_ms").and_then(Value::as_f64) {
            line.push_str(&format!(", {:.0} s", ms / 1000.0));
        }
        if let Some(turns) = event.get("num_turns").and_then(Value::as_i64) {
            line.push_str(&format!(", {turns} turns"));
        }
        line.push(']');
        if let Some(res) = event.get("result").and_then(Value::as_str)
            && !res.is_empty()
        {
            line.push('\n');
            line.push_str(res);
        }
        line
    }
}
