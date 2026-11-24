use std::collections::HashSet;

use serde_json::Value;

use crate::model::RunOutcome;
use crate::runners::{GrokAcpRun, GrokRecovery, SubagentStatus};
use crate::transcript::{PlanStep, ToolOutput, TranscriptItemKind};

#[derive(Debug, Clone, Default)]
pub struct GrokActivity {
    running_prompt: Option<String>,
    queued: bool,
    tasks: HashSet<String>,
    subagents: HashSet<String>,
    wake_pending: bool,
}

impl GrokActivity {
    pub fn running(&self) -> usize {
        self.tasks.len() + self.subagents.len()
    }

    pub fn idle(&self) -> bool {
        self.running_prompt.is_none() && !self.queued && self.running() == 0 && !self.wake_pending
    }

    pub fn adopt_running(&mut self, id: impl Into<String>) {
        self.running_prompt = Some(id.into());
    }

    pub fn read(&mut self, method: &str, params: &Value, session: &str) -> bool {
        if !method.starts_with("_x.ai/") || params.get("sessionId").and_then(Value::as_str) != Some(session) {
            return false;
        }
        if method == "_x.ai/queue/changed" {
            self.running_prompt = params
                .get("runningPromptId")
                .and_then(Value::as_str)
                .map(ToOwned::to_owned);
            self.queued = params
                .get("entries")
                .and_then(Value::as_array)
                .is_some_and(|a| !a.is_empty());
            return true;
        }
        let Some(update) = params.get("update") else {
            return false;
        };
        self.apply(update)
    }

    pub fn apply(&mut self, update: &Value) -> bool {
        if update.get("will_wake").and_then(Value::as_bool) == Some(true) {
            self.wake_pending = true;
        }
        match update.get("sessionUpdate").and_then(Value::as_str) {
            Some("background_tasks") => {
                self.tasks = update
                    .get("tasks")
                    .and_then(Value::as_array)
                    .map(|arr| {
                        arr.iter()
                            .filter(|t| t.get("status").and_then(Value::as_str) == Some("running"))
                            .filter_map(|t| t.get("task_id").and_then(Value::as_str).map(ToOwned::to_owned))
                            .collect()
                    })
                    .unwrap_or_default();
            }
            Some("subagent_spawned") => {
                if let Some(id) = update.get("subagent_id").and_then(Value::as_str) {
                    self.subagents.insert(id.to_string());
                }
            }
            Some("subagent_finished") => {
                if let Some(id) = update.get("subagent_id").and_then(Value::as_str) {
                    self.subagents.remove(id);
                }
            }
            Some("turn_completed") => {
                if let Some(pid) = update.get("prompt_id").and_then(Value::as_str)
                    && self.running_prompt.as_deref() == Some(pid)
                {
                    self.running_prompt = None;
                }
                self.wake_pending = false;
            }
            Some("task_completed") => {}
            _ => return false,
        }
        true
    }
}

pub struct GrokToolOutput;

impl GrokToolOutput {
    pub fn text(block: &Value) -> Option<String> {
        match block.get("type").and_then(Value::as_str) {
            Some("content") => {
                let inner = block.get("content")?;
                let arr = Value::Array(vec![inner.clone()]);
                ToolOutput::content(Some(&arr))
            }
            Some("diff") => {
                let path = block.get("path")?.as_str()?;
                let before = block.get("oldText").and_then(Value::as_str).unwrap_or("");
                let after = block.get("newText").and_then(Value::as_str).unwrap_or("");
                Some(format!("{path}\nBefore:\n{before}\nAfter:\n{after}"))
            }
            _ => Some(ToolOutput::unsupported(block)),
        }
    }
}

impl GrokAcpRun {
    pub fn text_id(params: &Value, session: Option<&str>, kind: TranscriptItemKind) -> Option<String> {
        let meta = params.get("_meta")?;
        let prompt = meta.get("promptId")?.as_str()?;
        let start = meta.get("streamStartMs")?;
        let start_str = match start {
            Value::Number(n) => n.to_string(),
            Value::String(s) => s.clone(),
            _ => return None,
        };
        let suffix = if kind == TranscriptItemKind::Reasoning {
            "/thought"
        } else {
            "/text"
        };
        Some(format!(
            "grok/{}/{prompt}/{start_str}{suffix}",
            session.unwrap_or("")
        ))
    }

    pub(super) fn finish_if_idle(&self) {
        if self.journal.is_finished() {
            return;
        }
        let finish_outcome = {
            let g = self.state.lock().unwrap();
            if g.open_prompts > 0 {
                return;
            }
            let Some(ro) = &g.routine_outcome else {
                return;
            };
            if *ro == RunOutcome::Succeeded && g.stop_reason.is_none() && !g.activity.idle() {
                return;
            }
            g.stop_reason.clone().unwrap_or_else(|| ro.clone())
        };
        self.journal.finish(finish_outcome);
        self.disconnect();
    }

    pub(super) fn handle_notification(&self, method: &str, params: &Value) {
        if method != "session/update" {
            self.track_activity(method, params);
            return;
        }
        let (sid, loading) = {
            let g = self.state.lock().unwrap();
            (g.session_id.clone(), g.loading)
        };
        if params.get("sessionId").and_then(Value::as_str) != sid.as_deref() {
            return;
        }
        let Some(update) = params.get("update") else {
            return;
        };
        match update.get("sessionUpdate").and_then(Value::as_str) {
            Some("config_option_update") => {
                self.configure(update);
            }
            Some("agent_message_chunk" | "agent_thought_chunk") => {
                let thought =
                    update.get("sessionUpdate").and_then(Value::as_str) == Some("agent_thought_chunk");
                let kind = if thought {
                    TranscriptItemKind::Reasoning
                } else {
                    TranscriptItemKind::Agent
                };
                if let Some(text) = update
                    .get("content")
                    .and_then(|c| c.get("text"))
                    .and_then(Value::as_str)
                {
                    let nid = Self::text_id(params, sid.as_deref(), kind);
                    if loading && let Some(nid) = &nid {
                        self.journal.reconcile_text(text, kind, nid);
                    } else {
                        self.journal.text(text, kind, nid.as_deref());
                    }
                }
            }
            Some("tool_call" | "tool_call_update") => {
                let tool_id = update
                    .get("toolCallId")
                    .and_then(Value::as_str)
                    .map(|id| format!("grok/{}/tool/{id}", sid.as_deref().unwrap_or("")));
                let event_id = params
                    .get("_meta")
                    .and_then(|m| m.get("eventId"))
                    .and_then(Value::as_str);
                if update.get("sessionUpdate").and_then(Value::as_str) == Some("tool_call") {
                    let title = update.get("title").and_then(Value::as_str).unwrap_or("tool");
                    self.journal
                        .record_with_native(TranscriptItemKind::Tool, title, tool_id.as_deref());
                }
                if let Some(arr) = update.get("content").and_then(Value::as_array) {
                    for (idx, block) in arr.iter().enumerate() {
                        if let Some(text) = GrokToolOutput::text(block) {
                            let out_id = tool_id.as_ref().map(|tid| match event_id {
                                Some(eid) => format!("{tid}/{idx}/event/{eid}"),
                                None => format!("{tid}/{idx}"),
                            });
                            self.journal.record_with_native(
                                TranscriptItemKind::Output,
                                &text,
                                out_id.as_deref(),
                            );
                        }
                    }
                }
            }
            Some("plan") => {
                if let Some(arr) = update.get("entries").and_then(Value::as_array) {
                    let steps: Vec<PlanStep> = arr
                        .iter()
                        .map(|e| {
                            PlanStep::from_raw(
                                e.get("status").and_then(Value::as_str),
                                e.get("content").and_then(Value::as_str).unwrap_or(""),
                            )
                        })
                        .collect();
                    if !steps.is_empty() {
                        self.journal
                            .record(TranscriptItemKind::Plan, &PlanStep::body(&steps));
                    }
                }
            }
            _ => {}
        }
    }

    fn track_activity(&self, method: &str, params: &Value) {
        let sid = self.state.lock().unwrap().session_id.clone();
        if params.get("sessionId").and_then(Value::as_str) == sid.as_deref()
            && params
                .get("update")
                .and_then(|u| u.get("sessionUpdate"))
                .and_then(Value::as_str)
                == Some("retry_state")
        {
            self.journal
                .record(TranscriptItemKind::Status, "Grok updated its request retry state");
        }
        let Some(sid) = sid else {
            return;
        };
        let (matched, loading) = {
            let mut g = self.state.lock().unwrap();
            (g.activity.read(method, params, &sid), g.loading)
        };
        if !matched {
            return;
        }
        if let Some(update) = params.get("update") {
            if let Some(text) = SubagentStatus::grok(update)
                && let (Some(sub_id), Some(kind)) = (
                    update.get("subagent_id").and_then(Value::as_str),
                    update.get("sessionUpdate").and_then(Value::as_str),
                )
            {
                let nid = format!("grok/{sid}/{sub_id}/{kind}");
                self.journal
                    .record_with_native(TranscriptItemKind::Status, &text, Some(&nid));
            }
            if update.get("sessionUpdate").and_then(Value::as_str) == Some("turn_completed") {
                self.journal.end_text();
                let out = GrokRecovery::outcome(update.get("stop_reason").and_then(Value::as_str));
                let mut g = self.state.lock().unwrap();
                if (!loading || self.spec.adopt)
                    && (g.routine_outcome.is_none() || out != RunOutcome::Succeeded)
                {
                    g.routine_outcome = Some(out);
                }
            }
        }
        if !loading {
            self.finish_if_idle();
        }
    }
}
