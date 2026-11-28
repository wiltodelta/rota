use std::collections::HashMap;
use std::process::{Child, Stdio};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde_json::{Map, Value, json};

use crate::model::{AgentQuestion, HarnessInput, LaunchMode, RunOutcome};
use crate::rpc::{JsonRpcError, JsonRpcPeer, WebSocketTransport};
use crate::runners::{CodexAsyncQuestions, LaunchSpec, ProcessLauncher, RunControl};
use crate::transcript::{RunJournal, TranscriptItemKind};

pub(super) struct CodexState {
    pub(super) proxy: Option<Child>,
    pub(super) peer: Option<Arc<JsonRpcPeer>>,
    pub(super) thread_id: Option<String>,
    pub(super) turn_id: Option<String>,
    pub(super) pending_messages: Vec<String>,
    pub(super) approval_items: HashMap<String, Value>,
    pub(super) stop_reason: Option<RunOutcome>,
    pub(super) turn_starting: bool,
    pub(super) loading_history: bool,
    pub(super) deferred_events: Vec<(String, Value)>,
    pub(super) latest_restored_turn: Option<Value>,
    pub(super) native_active: bool,
    pub(super) native_state_known: bool,
    pub(super) async_questions: CodexAsyncQuestions,
}

pub struct CodexDaemonRun {
    pub(super) spec: LaunchSpec,
    pub(super) journal: Arc<RunJournal>,
    pub(super) state: Mutex<CodexState>,
}

impl CodexDaemonRun {
    pub fn new(spec: LaunchSpec, journal: Arc<RunJournal>, peer: Option<Arc<JsonRpcPeer>>) -> Arc<Self> {
        let mut async_questions = CodexAsyncQuestions::new();
        if spec.resume.is_some() && !spec.adopt {
            async_questions.sending(&spec.prompt);
        }
        Arc::new(Self {
            state: Mutex::new(CodexState {
                proxy: None,
                peer,
                thread_id: spec.resume.clone(),
                turn_id: None,
                pending_messages: Vec::new(),
                approval_items: HashMap::new(),
                stop_reason: None,
                turn_starting: false,
                loading_history: false,
                deferred_events: Vec::new(),
                latest_restored_turn: None,
                native_active: false,
                native_state_known: spec.resume.is_none(),
                async_questions,
            }),
            spec,
            journal,
        })
    }

    pub fn start(spec: LaunchSpec, journal: Arc<RunJournal>) -> Arc<dyn RunControl> {
        let run = Self::new(spec, journal, None);
        let worker = Arc::clone(&run);
        std::thread::spawn(move || worker.connect());
        run
    }

    pub fn config_overrides(environment: &HashMap<String, String>) -> Map<String, Value> {
        let mut config = Map::new();
        for (k, v) in ProcessLauncher::session_variables(environment) {
            config.insert(format!("shell_environment_policy.set.{k}"), json!(v));
        }
        config.insert("features.default_mode_request_user_input".into(), json!(true));
        config
    }

    pub fn describe_started(item: Option<&Value>) -> Option<String> {
        let item = item?;
        match item.get("type").and_then(Value::as_str) {
            Some("commandExecution") => item
                .get("command")
                .and_then(Value::as_str)
                .map(|c| format!("$ {c}")),
            Some("mcpToolCall" | "dynamicToolCall") => {
                item.get("tool").and_then(Value::as_str).map(ToOwned::to_owned)
            }
            Some("collabAgentToolCall") => Some(format!(
                "agent {}",
                item.get("tool")
                    .and_then(Value::as_str)
                    .unwrap_or("collaboration")
            )),
            Some("fileChange") => Some("edit files".into()),
            Some("imageView") => Some("view image".into()),
            Some("imageGeneration") => Some("generate image".into()),
            Some("webSearch") => item
                .get("query")
                .and_then(Value::as_str)
                .map(|q| format!("search {q}")),
            _ => None,
        }
    }

    fn connect(self: Arc<Self>) {
        let (st, out) = ProcessLauncher::capture(
            &self.spec.executable,
            &["app-server".into(), "daemon".into(), "start".into()],
            &ProcessLauncher::helper_directory(),
            Some(Duration::from_secs(15)),
            true,
            true,
            &HashMap::new(),
        );
        if st != 0 {
            let prefix: String = out.chars().take(200).collect();
            self.finish(
                RunOutcome::LaunchFailed(format!("codex app-server daemon start: {prefix}")),
                false,
            );
            return;
        }
        let mut cmd = ProcessLauncher::login_shell_command(
            &self.spec.executable,
            &["app-server".into(), "proxy".into()],
            &ProcessLauncher::helper_directory(),
            &HashMap::new(),
        );
        cmd.stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null());
        let mut child = match cmd.spawn() {
            Ok(c) => c,
            Err(err) => {
                self.finish(RunOutcome::LaunchFailed(err.to_string()), false);
                return;
            }
        };
        let (Some(stdin), Some(stdout)) = (child.stdin.take(), child.stdout.take()) else {
            let _ = child.kill();
            self.finish(RunOutcome::LaunchFailed("Missing proxy pipes".into()), false);
            return;
        };
        let transport = WebSocketTransport::spawn(stdin, stdout);
        let peer = JsonRpcPeer::new(transport, true);
        {
            let mut g = self.state.lock().unwrap();
            g.proxy = Some(child);
            g.peer = Some(Arc::clone(&peer));
        }

        let weak_notif = Arc::downgrade(&self);
        peer.set_on_notification(Arc::new(move |method, params| {
            if let Some(me) = weak_notif.upgrade() {
                me.handle_notification(&method, &params);
            }
        }));
        let weak_req = Arc::downgrade(&self);
        peer.set_on_request_async(Arc::new(move |id, method, params, reply| {
            if let Some(me) = weak_req.upgrade() {
                me.handle_request(&id, &method, &params, reply);
            } else {
                reply(None);
            }
        }));
        let weak_close = Arc::downgrade(&self);
        peer.set_on_close(Arc::new(move || {
            if let Some(me) = weak_close.upgrade() {
                me.finish(RunOutcome::Interrupted, false);
            }
        }));

        let weak_init = Arc::downgrade(&self);
        peer.request(
            "initialize",
            json!({
                "clientInfo": {"name": "rota", "version": "1"},
                "capabilities": {"experimentalApi": true},
            }),
            move |res| {
                if let Some(me) = weak_init.upgrade() {
                    me.initialized(res);
                }
            },
        );

        if let Some(secs) = self.spec.timeout_secs {
            let weak_to = Arc::downgrade(&self);
            std::thread::spawn(move || {
                std::thread::sleep(Duration::from_secs_f64(secs.max(0.0)));
                if let Some(me) = weak_to.upgrade() {
                    me.interrupt(RunOutcome::TimedOut);
                }
            });
        }
    }

    pub(super) fn interrupt(self: &Arc<Self>, reason: RunOutcome) {
        if self.journal.is_finished() {
            return;
        }
        let (thread_id, turn_id, peer, wait_for_turn) = {
            let mut g = self.state.lock().unwrap();
            g.stop_reason = Some(reason.clone());
            (
                g.thread_id.clone(),
                g.turn_id.clone(),
                g.peer.clone(),
                g.turn_starting || !g.native_state_known,
            )
        };
        let (Some(tid), Some(uid)) = (thread_id, turn_id) else {
            if wait_for_turn {
                self.schedule_cancel_recheck();
                return;
            }
            self.finish(reason, true);
            self.disconnect();
            return;
        };
        if let Some(p) = peer {
            p.request("turn/interrupt", json!({"threadId": tid, "turnId": uid}), |_| {});
        }
        self.schedule_cancel_recheck();
    }

    fn schedule_cancel_recheck(self: &Arc<Self>) {
        let weak = Arc::downgrade(self);
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_secs(15));
            if let Some(me) = weak.upgrade()
                && !me.journal.is_finished()
            {
                me.journal.record(
                    TranscriptItemKind::Status,
                    "Codex has not confirmed cancellation; waiting for the native turn",
                );
                let reason = me.state.lock().unwrap().stop_reason.clone();
                if let Some(r) = reason {
                    me.interrupt(r);
                }
            }
        });
    }

    pub(super) fn fail(&self, result: Result<Value, JsonRpcError>, step: &str) {
        let reason = match result {
            Err(err) => err.message,
            Ok(_) => "Malformed reply".to_string(),
        };
        let absent = step == "thread/resume" && reason.starts_with("no rollout found for thread id ");
        self.finish(RunOutcome::LaunchFailed(format!("{step}: {reason}")), absent);
        self.disconnect();
    }

    pub(super) fn finish(&self, outcome: RunOutcome, native_final: bool) {
        if self.journal.is_finished() {
            return;
        }
        let (has_thread, pending, reopened) = {
            let mut g = self.state.lock().unwrap();
            let pending = std::mem::take(&mut g.pending_messages);
            let reopened: Vec<AgentQuestion> = pending
                .iter()
                .filter_map(|m| g.async_questions.undelivered(m))
                .collect();
            (g.thread_id.is_some(), pending, reopened)
        };
        if has_thread && !native_final {
            self.journal.require_reconciliation();
        }
        for msg in pending {
            self.journal.record(TranscriptItemKind::User, &msg);
            self.journal
                .line("[rota: message not delivered: the turn did not become ready]");
        }
        let _ = reopened;
        self.journal.finish(outcome);
    }

    pub(super) fn disconnect(&self) {
        let (peer, proxy) = {
            let mut g = self.state.lock().unwrap();
            (g.peer.take(), g.proxy.take())
        };
        if let Some(p) = peer {
            p.close();
        }
        if let Some(mut c) = proxy {
            let _ = c.kill();
            let _ = c.wait();
        }
    }

    pub(super) fn owns(&self, params: &Value) -> bool {
        let tid = self.state.lock().unwrap().thread_id.clone();
        match (tid.as_deref(), params.get("threadId").and_then(Value::as_str)) {
            (Some(t), Some(src)) => t == src,
            _ => false,
        }
    }
}

impl RunControl for CodexDaemonRun {
    fn stop(&self) {
        if self.journal.is_finished() {
            return;
        }
        let (tid, uid, peer, wait_for_turn) = {
            let mut g = self.state.lock().unwrap();
            g.stop_reason = Some(RunOutcome::Cancelled);
            (
                g.thread_id.clone(),
                g.turn_id.clone(),
                g.peer.clone(),
                g.turn_starting || !g.native_state_known,
            )
        };
        if let (Some(tid), Some(uid)) = (tid, uid) {
            if let Some(p) = peer {
                p.request("turn/interrupt", json!({"threadId": tid, "turnId": uid}), |_| {});
            }
        } else if !wait_for_turn {
            self.finish(RunOutcome::Cancelled, true);
            self.disconnect();
        }
    }

    fn send(&self, message: &str) {
        if self.journal.is_finished() {
            self.journal.undelivered(message);
            return;
        }
        let (tid, uid, peer) = {
            let mut g = self.state.lock().unwrap();
            g.async_questions.sending(message);
            if let (Some(t), Some(u), Some(p)) = (g.thread_id.clone(), g.turn_id.clone(), g.peer.clone()) {
                (Some(t), Some(u), Some(p))
            } else {
                g.pending_messages.push(message.to_string());
                (None, None, None)
            }
        };
        if let (Some(tid), Some(uid), Some(peer)) = (tid, uid, peer) {
            self.journal.record(TranscriptItemKind::User, message);
            let j = Arc::clone(&self.journal);
            peer.request(
                "turn/steer",
                json!({
                    "threadId": tid,
                    "expectedTurnId": uid,
                    "input": HarnessInput::blocks(message, LaunchMode::CodexDaemon),
                }),
                move |res| {
                    if let Err(err) = res {
                        j.line(&format!("[rota: message not delivered: {}]", err.message));
                    }
                },
            );
        }
    }
}
