use std::sync::Arc;

use serde_json::{Map, Value, json};

use crate::model::{HarnessInput, LaunchMode, RunOutcome, SessionConfiguration};
use crate::rpc::JsonRpcError;
use crate::runners::{CodexDaemonRun, SessionBridge};
use crate::transcript::TranscriptItemKind;

impl CodexDaemonRun {
    pub(super) fn initialized(self: &Arc<Self>, result: Result<Value, JsonRpcError>) {
        if self.journal.is_finished() {
            return;
        }
        let Ok(val) = result else {
            self.fail(result, "initialize");
            return;
        };
        self.journal.provenance(
            None,
            val.get("userAgent")
                .and_then(Value::as_str)
                .map(ToOwned::to_owned),
        );
        let peer = self.state.lock().unwrap().peer.clone();
        if let Some(p) = &peer {
            p.notify("initialized", json!({}));
        }
        let mut cfg = Self::config_overrides(&self.spec.environment);
        for (k, v) in SessionBridge::codex(&self.spec) {
            cfg.insert(k, v);
        }
        let mut params = Map::new();
        params.insert("cwd".into(), json!(self.spec.working_directory));
        params.insert("approvalPolicy".into(), json!("never"));
        params.insert("sandbox".into(), json!("danger-full-access"));
        if let Some(m) = &self.spec.model {
            params.insert("model".into(), json!(m));
        }
        params.insert("config".into(), Value::Object(cfg));
        let method = if let Some(thread) = &self.spec.resume {
            let mut g = self.state.lock().unwrap();
            g.loading_history = true;
            g.async_questions.hold();
            params.insert("threadId".into(), json!(thread));
            "thread/resume"
        } else {
            "thread/start"
        };
        self.request_thread(method, Value::Object(params), true);
    }

    fn request_thread(self: &Arc<Self>, method: &'static str, params: Value, allow_unarchive: bool) {
        let Some(peer) = self.state.lock().unwrap().peer.clone() else {
            return;
        };
        let me = Arc::clone(self);
        let params_retry = params.clone();
        peer.request(method, params, move |res| {
            if allow_unarchive
                && !me.spec.adopt
                && let Some(id) = &me.spec.resume
                && let Err(err) = &res
                && err.message.starts_with(&format!("session {id} is archived."))
                && let Some(p) = me.state.lock().unwrap().peer.clone()
            {
                let me2 = Arc::clone(&me);
                p.request("thread/unarchive", json!({"threadId": id}), move |restored| {
                    if restored.is_err() {
                        me2.fail(restored, "thread/unarchive");
                    } else {
                        me2.journal
                            .record(TranscriptItemKind::Status, "Restored archived Codex session");
                        me2.request_thread(method, params_retry, false);
                    }
                });
                return;
            }
            me.thread_started(res);
        });
    }

    fn thread_started(self: &Arc<Self>, result: Result<Value, JsonRpcError>) {
        if self.journal.is_finished() {
            return;
        }
        let step = if self.spec.resume.is_none() {
            "thread/start"
        } else {
            "thread/resume"
        };
        let Ok(val) = &result else {
            self.fail(result, step);
            return;
        };
        let Some(thread) = val.get("thread") else {
            self.fail(result, step);
            return;
        };
        let Some(id) = thread.get("id").and_then(Value::as_str).map(ToOwned::to_owned) else {
            self.fail(result, step);
            return;
        };
        let model = val.get("model").and_then(Value::as_str).map(ToOwned::to_owned);
        let effort = self.spec.effort.clone().or_else(|| {
            val.get("reasoningEffort")
                .and_then(Value::as_str)
                .map(ToOwned::to_owned)
        });
        let native_active = thread
            .get("status")
            .and_then(|s| s.get("type"))
            .and_then(Value::as_str)
            == Some("active");
        {
            let mut g = self.state.lock().unwrap();
            g.thread_id = Some(id.clone());
            g.native_active = native_active;
        }
        self.journal
            .configure(SessionConfiguration::new(model.clone(), effort, None, None));
        if self.spec.resume.is_none() {
            let suffix = model.map_or_else(String::new, |m| format!(", {m}"));
            self.journal.line(&format!("[codex thread {id}{suffix}]"));
        }
        self.journal.session(&id);
        if self.spec.resume.is_some() {
            self.restore_turns(&id, None);
        } else {
            self.begin_turn(&id);
        }
    }

    fn begin_turn(self: &Arc<Self>, thread_id: &str) {
        if self.journal.is_finished() {
            return;
        }
        let peer = {
            let mut g = self.state.lock().unwrap();
            if g.stop_reason.is_some() {
                return;
            }
            g.turn_starting = true;
            g.peer.clone()
        };
        let Some(peer) = peer else {
            return;
        };
        let mut params = Map::new();
        params.insert("threadId".into(), json!(thread_id));
        params.insert(
            "input".into(),
            json!(HarnessInput::blocks(&self.spec.prompt, LaunchMode::CodexDaemon)),
        );
        if let Some(m) = &self.spec.model {
            params.insert("model".into(), json!(m));
        }
        if let Some(e) = &self.spec.effort {
            params.insert("effort".into(), json!(e));
        }
        let me = Arc::clone(self);
        peer.request("turn/start", Value::Object(params), move |res| {
            me.turn_started(res);
        });
    }

    pub fn turn_started(self: &Arc<Self>, result: Result<Value, JsonRpcError>) {
        if self.journal.is_finished() {
            return;
        }
        let turn_id = result
            .as_ref()
            .ok()
            .and_then(|v| v.get("turn"))
            .and_then(|t| t.get("id"))
            .and_then(Value::as_str)
            .map(ToOwned::to_owned);
        let Some(id) = turn_id else {
            let reopen = self
                .state
                .lock()
                .unwrap()
                .async_questions
                .undelivered(&self.spec.prompt);
            if let Some(q) = reopen {
                self.ask_async(q);
            }
            self.fail(result, "turn/start");
            return;
        };
        let (resolved_q, stop_reason) = {
            let mut g = self.state.lock().unwrap();
            let rq = g.async_questions.delivered(&self.spec.prompt);
            g.turn_id = Some(id);
            g.turn_starting = false;
            (rq, g.stop_reason.clone())
        };
        if let Some(qid) = resolved_q {
            self.journal.resolve_question(&qid);
        }
        if let Some(reason) = stop_reason {
            self.interrupt(reason);
        } else {
            self.deliver_pending_messages();
        }
    }

    fn restore_turns(self: &Arc<Self>, thread_id: &str, cursor: Option<String>) {
        let Some(peer) = self.state.lock().unwrap().peer.clone() else {
            return;
        };
        let mut params = json!({
            "threadId": thread_id,
            "limit": 100,
            "sortDirection": "asc",
            "itemsView": "full",
        });
        if let Some(c) = cursor
            && let Some(obj) = params.as_object_mut()
        {
            obj.insert("cursor".into(), json!(c));
        }
        let me = Arc::clone(self);
        let tid = thread_id.to_string();
        peer.request("thread/turns/list", params, move |res| {
            if me.journal.is_finished() {
                return;
            }
            let Ok(page) = &res else {
                me.fail(res, "thread/turns/list");
                return;
            };
            let Some(turns) = page.get("data").and_then(Value::as_array) else {
                me.fail(res, "thread/turns/list");
                return;
            };
            for turn in turns {
                me.state.lock().unwrap().latest_restored_turn = Some(turn.clone());
                if let Some(items) = turn.get("items").and_then(Value::as_array) {
                    for item in items {
                        me.item_started(Some(item));
                        me.item_completed(Some(item));
                    }
                }
            }
            if let Some(next) = page.get("nextCursor").and_then(Value::as_str) {
                me.restore_turns(&tid, Some(next.to_string()));
            } else {
                me.history_restored(&tid);
            }
        });
    }

    fn history_restored(self: &Arc<Self>, thread_id: &str) {
        let (active_turn_id, deferred, latest_turn, native_active) = {
            let mut g = self.state.lock().unwrap();
            g.loading_history = false;
            g.native_state_known = true;
            let active = g
                .latest_restored_turn
                .as_ref()
                .and_then(|t| t.get("status"))
                .and_then(Value::as_str)
                == Some("inProgress");
            if active {
                g.turn_id = g
                    .latest_restored_turn
                    .as_ref()
                    .and_then(|t| t.get("id"))
                    .and_then(Value::as_str)
                    .map(ToOwned::to_owned);
            }
            let atid = if active { g.turn_id.clone() } else { None };
            (
                atid,
                std::mem::take(&mut g.deferred_events),
                g.latest_restored_turn.clone(),
                g.native_active,
            )
        };
        for (m, p) in &deferred {
            if m != "turn/completed" {
                self.handle_notification(m, p);
            }
        }
        if self.journal.is_finished() {
            return;
        }
        let (closed, open) = {
            let mut g = self.state.lock().unwrap();
            (g.async_questions.closed(), g.async_questions.restored())
        };
        for id in closed {
            self.journal.resolve_question(&id);
        }
        for q in open {
            self.ask_async(q);
        }
        for (m, p) in &deferred {
            if m == "turn/completed" {
                self.handle_notification(m, p);
            }
        }
        if self.journal.is_finished() {
            return;
        }
        if let Some(tid) = active_turn_id {
            self.continue_active_turn(thread_id, &tid);
            return;
        }
        if native_active {
            self.journal.line(
                "[error] Codex reports active work without a recoverable turn. No second turn was started.",
            );
            self.finish(RunOutcome::Interrupted, false);
            self.disconnect();
            return;
        }
        if self.spec.adopt {
            self.state.lock().unwrap().turn_id = latest_turn
                .as_ref()
                .and_then(|t| t.get("id"))
                .and_then(Value::as_str)
                .map(ToOwned::to_owned);
            self.turn_completed(latest_turn.as_ref());
        } else {
            self.begin_turn(thread_id);
        }
    }

    fn continue_active_turn(self: &Arc<Self>, thread_id: &str, turn_id: &str) {
        if let Some(reason) = self.state.lock().unwrap().stop_reason.clone() {
            self.interrupt(reason);
            return;
        }
        if !self.spec.adopt
            && let Some(peer) = self.state.lock().unwrap().peer.clone()
        {
            let me = Arc::clone(self);
            peer.request(
                "turn/steer",
                json!({
                    "threadId": thread_id,
                    "expectedTurnId": turn_id,
                    "input": HarnessInput::blocks(&self.spec.prompt, LaunchMode::CodexDaemon),
                }),
                move |res| {
                    if res.is_err() {
                        let q = me
                            .state
                            .lock()
                            .unwrap()
                            .async_questions
                            .undelivered(&me.spec.prompt);
                        if let Some(q) = q {
                            me.ask_async(q);
                        }
                        me.fail(res, "turn/steer");
                    } else if let Some(qid) = me
                        .state
                        .lock()
                        .unwrap()
                        .async_questions
                        .delivered(&me.spec.prompt)
                    {
                        me.journal.resolve_question(&qid);
                    }
                },
            );
        }
        self.deliver_pending_messages();
    }

    fn deliver_pending_messages(self: &Arc<Self>) {
        let (thread_id, turn_id, peer, messages) = {
            let mut g = self.state.lock().unwrap();
            let (Some(tid), Some(uid), Some(p)) = (g.thread_id.clone(), g.turn_id.clone(), g.peer.clone())
            else {
                return;
            };
            (tid, uid, p, std::mem::take(&mut g.pending_messages))
        };
        for message in messages {
            self.journal.record(TranscriptItemKind::User, &message);
            let me = Arc::clone(self);
            let msg_copy = message.clone();
            peer.request(
                "turn/steer",
                json!({
                    "threadId": thread_id,
                    "expectedTurnId": turn_id,
                    "input": HarnessInput::blocks(&message, LaunchMode::CodexDaemon),
                }),
                move |res| match res {
                    Err(err) => {
                        me.journal
                            .line(&format!("[rota: message not delivered: {}]", err.message));
                        let reopen = me.state.lock().unwrap().async_questions.undelivered(&msg_copy);
                        if let Some(q) = reopen {
                            me.ask_async(q);
                        }
                    }
                    Ok(_) => {
                        let qid = me.state.lock().unwrap().async_questions.delivered(&msg_copy);
                        if let Some(id) = qid {
                            me.journal.resolve_question(&id);
                        }
                    }
                },
            );
        }
    }
}
