use std::sync::{Arc, Mutex};

use serde_json::Value;
use uuid::Uuid;

use crate::model::{AgentQuestion, QuestionRequest, RunOutcome};
use crate::rpc::AsyncRequestReply;
use crate::runners::{CodexDaemonRun, CodexItemOutput};
use crate::transcript::{PlanStep, TranscriptItemKind};

impl CodexDaemonRun {
    pub fn handle_request(
        self: &Arc<Self>,
        id: &str,
        method: &str,
        params: &Value,
        reply: AsyncRequestReply,
    ) {
        if !self.owns(params) || self.journal.is_finished() {
            if let Some(peer) = self.state.lock().unwrap().peer.clone() {
                peer.dismiss_request(id);
            }
            return;
        }
        let mut details = params.clone();
        if let Some(item_id) = params.get("itemId").and_then(Value::as_str)
            && let Some(item) = self.state.lock().unwrap().approval_items.get(item_id)
            && let Some(changes) = item.get("changes")
            && let Some(obj) = details.as_object_mut()
        {
            obj.insert("fileChanges".into(), changes.clone());
        }
        let Some(mut req) = QuestionRequest::codex(method, &details) else {
            reply(None);
            return;
        };
        req.question.id = id.to_string();
        let resp_fn = req.response;
        let once = Mutex::new(Some(reply));
        self.journal.ask(req.question, true, move |ans| {
            if let Some(cb) = once.lock().unwrap().take() {
                cb(Some(resp_fn(&ans)));
            }
        });
    }

    pub fn handle_notification(self: &Arc<Self>, method: &str, params: &Value) {
        if !self.owns(params) || self.journal.is_finished() {
            return;
        }
        {
            let mut g = self.state.lock().unwrap();
            if g.loading_history {
                g.deferred_events.push((method.to_string(), params.clone()));
                return;
            }
        }
        if method.starts_with("item/") {
            self.handle_item(method, params);
            return;
        }
        match method {
            "serverRequest/resolved" => {
                if let Some(req_id) = params.get("requestId") {
                    let key = match req_id {
                        Value::String(s) => s.clone(),
                        other => other.to_string(),
                    };
                    if let Some(peer) = self.state.lock().unwrap().peer.clone() {
                        peer.dismiss_request(&key);
                    }
                    self.journal.resolve_question(&key);
                }
            }
            "error" => {
                let msg = params
                    .get("error")
                    .and_then(|e| e.get("message"))
                    .and_then(Value::as_str)
                    .unwrap_or("Codex request error");
                let kind = if params.get("willRetry").and_then(Value::as_bool) == Some(true) {
                    TranscriptItemKind::Status
                } else {
                    TranscriptItemKind::Error
                };
                self.journal.record(kind, msg);
            }
            "turn/started" => {
                if let Some(id) = params
                    .get("turn")
                    .and_then(|t| t.get("id"))
                    .and_then(Value::as_str)
                    && !id.is_empty()
                {
                    let reason = {
                        let mut g = self.state.lock().unwrap();
                        g.turn_id = Some(id.to_string());
                        g.stop_reason.clone()
                    };
                    if let Some(r) = reason {
                        self.interrupt(r);
                    }
                }
            }
            "turn/plan/updated" => {
                if let Some(arr) = params.get("plan").and_then(Value::as_array) {
                    let steps: Vec<PlanStep> = arr
                        .iter()
                        .map(|s| {
                            PlanStep::from_raw(
                                s.get("status").and_then(Value::as_str),
                                s.get("step").and_then(Value::as_str).unwrap_or(""),
                            )
                        })
                        .collect();
                    if !steps.is_empty() {
                        self.journal
                            .record(TranscriptItemKind::Plan, &PlanStep::body(&steps));
                    }
                }
            }
            "model/verification" => {
                let (tid, uid) = {
                    let g = self.state.lock().unwrap();
                    (g.thread_id.clone(), g.turn_id.clone())
                };
                if let (Some(tid), Some(uid)) = (tid, uid)
                    && !uid.is_empty()
                    && params.get("turnId").and_then(Value::as_str) == Some(uid.as_str())
                {
                    for entry in CodexItemOutput::verifications(params.get("verifications")) {
                        let nid = format!("codex/{tid}/{uid}{}", entry.suffix);
                        self.journal
                            .record_with_native(entry.kind, &entry.text, Some(&nid));
                    }
                }
            }
            "turn/completed" => self.turn_completed(params.get("turn")),
            _ => {}
        }
    }

    fn handle_item(self: &Arc<Self>, method: &str, params: &Value) {
        match method {
            "item/agentMessage/delta" | "item/reasoning/summaryTextDelta" | "item/reasoning/textDelta" => {
                let (Some(delta), Some(id)) = (
                    params.get("delta").and_then(Value::as_str),
                    params.get("itemId").and_then(Value::as_str),
                ) else {
                    return;
                };
                let agent = method == "item/agentMessage/delta";
                let summary = method == "item/reasoning/summaryTextDelta";
                let idx = params
                    .get(if summary { "summaryIndex" } else { "contentIndex" })
                    .and_then(Value::as_i64)
                    .unwrap_or(0);
                let suffix = if agent {
                    String::new()
                } else if summary {
                    format!("/summary/{idx}")
                } else {
                    format!("/content/{idx}")
                };
                let nid = format!("codex/{id}{suffix}");
                self.journal.text(
                    delta,
                    if agent {
                        TranscriptItemKind::Agent
                    } else {
                        TranscriptItemKind::Reasoning
                    },
                    Some(&nid),
                );
            }
            "item/started" => self.item_started(params.get("item")),
            "item/completed" => self.item_completed(params.get("item")),
            _ => {}
        }
    }

    pub(super) fn item_started(&self, item: Option<&Value>) {
        if let Some(it) = item {
            if it.get("type").and_then(Value::as_str) == Some("subAgentActivity")
                && let Some(text) = CodexItemOutput::activity(it)
                && let Some(id) = it.get("id").and_then(Value::as_str)
            {
                let nid = format!("codex/{id}/activity");
                self.journal
                    .record_with_native(TranscriptItemKind::Status, &text, Some(&nid));
            }
            if it.get("type").and_then(Value::as_str) == Some("fileChange")
                && let Some(id) = it.get("id").and_then(Value::as_str)
            {
                self.state
                    .lock()
                    .unwrap()
                    .approval_items
                    .insert(id.to_string(), it.clone());
            }
        }
        if let Some(title) = Self::describe_started(item) {
            let nid = item
                .and_then(|i| i.get("id"))
                .and_then(Value::as_str)
                .map(|id| format!("codex/{id}/tool"));
            self.journal
                .record_with_native(TranscriptItemKind::Tool, &title, nid.as_deref());
        }
    }

    pub(super) fn item_completed(self: &Arc<Self>, item: Option<&Value>) {
        let Some(item) = item else {
            return;
        };
        if let Some(id) = item.get("id").and_then(Value::as_str) {
            self.state.lock().unwrap().approval_items.remove(id);
        }
        let native_id = format!(
            "codex/{}",
            item.get("id")
                .and_then(Value::as_str)
                .map(ToOwned::to_owned)
                .unwrap_or_else(|| Uuid::new_v4().to_string())
        );
        if item.get("type").and_then(Value::as_str) == Some("agentMessage")
            && let Some(text) = item.get("text").and_then(Value::as_str)
        {
            self.journal
                .reconcile_text(text, TranscriptItemKind::Agent, &native_id);
        }
        if item.get("type").and_then(Value::as_str) == Some("reasoning") {
            for field in ["summary", "content"] {
                if let Some(arr) = item.get(field).and_then(Value::as_array) {
                    for (idx, val) in arr.iter().enumerate() {
                        if let Some(text) = val.as_str() {
                            self.journal.reconcile_text(
                                text,
                                TranscriptItemKind::Reasoning,
                                &format!("{native_id}/{field}/{idx}"),
                            );
                        }
                    }
                }
            }
        }
        for entry in CodexItemOutput::entries(item) {
            let nid = format!("{native_id}{}", entry.suffix);
            self.journal
                .record_with_native(entry.kind, &entry.text, Some(&nid));
        }
        let (answered, open_q) = {
            let mut g = self.state.lock().unwrap();
            let ans = g.async_questions.note_answers_in_item(item);
            let oq = QuestionRequest::codex_message(item).and_then(|q| g.async_questions.offer(q));
            (ans, oq)
        };
        for id in answered {
            self.journal.resolve_question(&id);
        }
        if let Some(q) = open_q {
            self.ask_async(q);
        }
    }

    pub(super) fn ask_async(self: &Arc<Self>, question: AgentQuestion) {
        self.journal.ask(question, false, |_| {});
    }

    pub(super) fn turn_completed(&self, turn: Option<&Value>) {
        let (expected_turn, stop_reason) = {
            let g = self.state.lock().unwrap();
            (g.turn_id.clone(), g.stop_reason.clone())
        };
        let turn_id = turn.and_then(|t| t.get("id")).and_then(Value::as_str);
        if expected_turn.is_some() && turn_id != expected_turn.as_deref() {
            return;
        }
        let outcome = match turn.and_then(|t| t.get("status")).and_then(Value::as_str) {
            Some("completed") => RunOutcome::Succeeded,
            Some("interrupted") => stop_reason.unwrap_or(RunOutcome::Cancelled),
            _ => RunOutcome::Failed { exit_code: 1 },
        };
        if let Some(err) = turn
            .and_then(|t| t.get("error"))
            .and_then(|e| e.get("message"))
            .and_then(Value::as_str)
        {
            self.journal.line(&format!("[error] {err}"));
        }
        self.finish(outcome, true);
        self.disconnect();
    }
}
