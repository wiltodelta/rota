use std::collections::HashSet;
use std::sync::Arc;
use std::time::Duration;

use serde_json::{Value, json};

use crate::model::{AgentQuestion, QuestionOption, QuestionRequest, RunOutcome, SessionConfiguration};
use crate::runners::{ClaudeConfiguration, ClaudeStreamRun, StreamJsonFormatter};
use crate::transcript::{TranscriptItemKind, TranscriptService};

impl ClaudeStreamRun {
    pub fn handle_line(self: &Arc<Self>, line: &str) {
        let Ok(event) = serde_json::from_str::<Value>(line) else {
            if !line.trim().is_empty() {
                self.journal.line(&format!("[error] {line}"));
            }
            return;
        };
        let Some(kind) = event.get("type").and_then(Value::as_str) else {
            if !line.trim().is_empty() {
                self.journal.line(&format!("[error] {line}"));
            }
            return;
        };
        if let Some(cfg) = ClaudeConfiguration::applied(&event) {
            self.journal.configure(cfg);
        }
        if self.spec.adopt && kind.starts_with("control_") {
            return;
        }
        if self.handle_control(&event) {
            return;
        }
        match kind {
            "stream_event" => self.partial(&event),
            "system" => self.system(&event, line),
            "result" => self.turn_ended(&event),
            _ => self.message(line.as_bytes(), kind),
        }
    }

    fn partial(&self, outer: &Value) {
        let Some(ev) = outer.get("event") else {
            return;
        };
        if matches!(
            ev.get("type").and_then(Value::as_str),
            Some("content_block_stop" | "message_stop")
        ) {
            self.journal.end_text();
        }
        if let Some(delta) = ev.get("delta") {
            if let Some(text) = delta.get("text").and_then(Value::as_str)
                && !text.is_empty()
            {
                self.state.lock().unwrap().streamed_text = true;
                self.journal.text(text, TranscriptItemKind::Agent, None);
            } else if let Some(thinking) = delta.get("thinking").and_then(Value::as_str)
                && !thinking.is_empty()
            {
                self.state.lock().unwrap().streamed_reasoning = true;
                self.journal.text(thinking, TranscriptItemKind::Reasoning, None);
            }
        }
    }

    fn message(&self, data: &[u8], kind: &str) {
        if kind == "user" {
            self.state.lock().unwrap().notified = false;
        }
        let (streamed_text, streamed_reasoning) = {
            let g = self.state.lock().unwrap();
            (g.streamed_text, g.streamed_reasoning)
        };
        for item in StreamJsonFormatter::items(data) {
            let already = kind == "assistant"
                && ((item.kind == TranscriptItemKind::Agent && streamed_text)
                    || (item.kind == TranscriptItemKind::Reasoning && streamed_reasoning));
            if !already {
                self.journal.record(item.kind, &item.text);
            }
        }
        if kind == "assistant" {
            self.journal.end_text();
            let mut g = self.state.lock().unwrap();
            g.streamed_text = false;
            g.streamed_reasoning = false;
        }
    }

    fn system(&self, event: &Value, raw_line: &str) {
        match event.get("subtype").and_then(Value::as_str) {
            Some("api_retry") => {
                self.journal
                    .record(TranscriptItemKind::Status, "Claude is retrying its request");
            }
            Some("background_tasks_changed") => {
                let ids: HashSet<String> = event
                    .get("tasks")
                    .and_then(Value::as_array)
                    .map(|arr| {
                        arr.iter()
                            .filter(|t| t.get("ambient").and_then(Value::as_bool) != Some(true))
                            .filter_map(|t| t.get("task_id").and_then(Value::as_str).map(ToOwned::to_owned))
                            .collect()
                    })
                    .unwrap_or_default();
                self.state.lock().unwrap().background = ids;
            }
            Some("task_notification") => {
                if let Some(id) = event.get("task_id").and_then(Value::as_str) {
                    let mut g = self.state.lock().unwrap();
                    if g.background.contains(id) {
                        g.notified = true;
                    }
                }
            }
            Some("init") => {
                if let Some(session) = event.get("session_id").and_then(Value::as_str) {
                    {
                        let mut g = self.state.lock().unwrap();
                        g.turns += 1;
                        g.notified = false;
                    }
                    if let Some(header) = StreamJsonFormatter::format(raw_line) {
                        self.journal.line(&header);
                    }
                    self.journal.configure(SessionConfiguration::new(
                        event.get("model").and_then(Value::as_str).map(ToOwned::to_owned),
                        None,
                        None,
                        None,
                    ));
                    self.journal.session(session);
                    let req =
                        ClaudeConfiguration::request_bytes("get_settings", ClaudeConfiguration::SETTINGS_ID);
                    let _ = self.capture.write_input(&req);
                }
            }
            _ => {}
        }
    }

    fn handle_control(self: &Arc<Self>, event: &Value) -> bool {
        match event.get("type").and_then(Value::as_str) {
            Some("control_request") => {
                let (Some(id), Some(req)) = (
                    event.get("request_id").and_then(Value::as_str),
                    event.get("request"),
                ) else {
                    return true;
                };
                let subtype = req
                    .get("subtype")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .to_string();
                let tool = req.get("tool_name").and_then(Value::as_str).unwrap_or("Tool");
                let input = req.get("input").cloned().unwrap_or_else(|| json!({}));
                let translated = QuestionRequest::claude(&json!({
                    "hook_event_name": "PreToolUse",
                    "tool_name": tool,
                    "tool_input": input,
                }));
                let question = translated
                    .as_ref()
                    .map(|t| t.question.clone())
                    .unwrap_or_else(|| {
                        let mut q = AgentQuestion::new(format!("Claude requests approval for {tool}"));
                        q.detail = QuestionRequest::json(&input);
                        q.actions = vec![QuestionOption::new("accept", "Allow Once")];
                        q
                    });
                let req_id = id.to_string();
                self.state
                    .lock()
                    .unwrap()
                    .questions
                    .insert(req_id.clone(), question.id.clone());
                let me = Arc::clone(self);
                self.journal.ask(question, true, move |answer| {
                    if me.journal.is_finished()
                        || me.state.lock().unwrap().questions.remove(&req_id).is_none()
                    {
                        return;
                    }
                    let resp = if subtype == "can_use_tool" && answer.action == "accept" {
                        let updated = translated
                            .as_ref()
                            .and_then(|t| (t.response)(&answer).get("hookSpecificOutput").cloned())
                            .and_then(|h| h.get("updatedInput").cloned())
                            .unwrap_or(input);
                        json!({"behavior": "allow", "updatedInput": updated})
                    } else {
                        json!({"behavior": "deny", "message": "The user declined this request."})
                    };
                    let envelope = json!({
                        "type": "control_response",
                        "response": {
                            "subtype": "success",
                            "request_id": req_id,
                            "response": resp,
                        }
                    });
                    if let Ok(mut bytes) = serde_json::to_vec(&envelope) {
                        bytes.push(b'\n');
                        let _ = me.capture.write_input(&bytes);
                    }
                });
                true
            }
            Some("control_cancel_request") => {
                if let Some(id) = event.get("request_id").and_then(Value::as_str)
                    && let Some(qid) = self.state.lock().unwrap().questions.remove(id)
                {
                    self.journal.resolve_question(&qid);
                }
                true
            }
            _ => false,
        }
    }

    fn turn_ended(self: &Arc<Self>, event: &Value) {
        let failed = event.get("is_error").and_then(Value::as_bool) == Some(true)
            || event
                .get("subtype")
                .and_then(Value::as_str)
                .is_some_and(|s| s.starts_with("error"));
        if self.spec.adopt {
            self.state.lock().unwrap().recovered_outcome = Some(if failed {
                RunOutcome::Failed { exit_code: 1 }
            } else {
                RunOutcome::Succeeded
            });
            return;
        }
        let (stop_set, bg_count, notified, turn_snapshot) = {
            let g = self.state.lock().unwrap();
            (g.stop_reason.is_some(), g.background.len(), g.notified, g.turns)
        };
        if !failed && !stop_set {
            if bg_count > 0 {
                self.journal
                    .record(TranscriptItemKind::Status, &TranscriptService::waiting(bg_count));
                return;
            }
            if notified {
                let settle = self.settle_secs;
                let weak = Arc::downgrade(self);
                std::thread::spawn(move || {
                    std::thread::sleep(Duration::from_secs_f64(settle.max(0.0)));
                    if let Some(me) = weak.upgrade()
                        && me.state.lock().unwrap().turns == turn_snapshot
                    {
                        me.close_turn(false);
                    }
                });
                return;
            }
        }
        if failed
            && let Some(reason) = event
                .get("result")
                .or_else(|| event.get("subtype"))
                .and_then(Value::as_str)
        {
            self.journal.line(&format!("[error] {reason}"));
        }
        self.close_turn(failed);
    }
}
