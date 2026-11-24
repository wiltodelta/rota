use std::collections::HashMap;
use std::path::Path;
use std::process::{Child, Stdio};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use serde_json::{Value, json};

use crate::model::{Harness, HarnessInput, LaunchMode, QuestionRequest, RunOutcome, SessionConfiguration};
use crate::rpc::{JsonRpcError, JsonRpcPeer, LineTransport, MessageTransport};
use crate::runners::{LaunchSpec, NativeTranscript, ProcessLauncher, RunControl};
use crate::transcript::{RunJournal, TranscriptItemKind, TranscriptService};

pub use super::grok_activity::{GrokActivity, GrokToolOutput};
pub use super::grok_recovery::GrokRecovery;

pub(super) struct GrokState {
    pub(super) child: Option<Child>,
    pub(super) peer: Option<Arc<JsonRpcPeer>>,
    pub(super) session_id: Option<String>,
    pub(super) stop_reason: Option<RunOutcome>,
    pub(super) open_prompts: isize,
    pub(super) routine_outcome: Option<RunOutcome>,
    pub(super) loading: bool,
    pub(super) early: Vec<String>,
    pub(super) activity: GrokActivity,
    pub(super) applied: SessionConfiguration,
    pub(super) effort_options: Vec<String>,
}

pub struct GrokAcpRun {
    pub(super) spec: LaunchSpec,
    pub(super) journal: Arc<RunJournal>,
    pub(super) state: Mutex<GrokState>,
}

impl GrokAcpRun {
    pub fn start(
        spec: LaunchSpec,
        journal: Arc<RunJournal>,
        transport: Option<Arc<dyn MessageTransport>>,
    ) -> Arc<Self> {
        let run = Arc::new(Self {
            spec,
            journal,
            state: Mutex::new(GrokState {
                child: None,
                peer: None,
                session_id: None,
                stop_reason: None,
                open_prompts: 0,
                routine_outcome: None,
                loading: false,
                early: Vec::new(),
                activity: GrokActivity::default(),
                applied: SessionConfiguration::default(),
                effort_options: Vec::new(),
            }),
        });
        let worker = Arc::clone(&run);
        std::thread::spawn(move || {
            if let Some(session) = &worker.spec.resume {
                let restored = GrokRecovery::load(session);
                let mut g = worker.state.lock().unwrap();
                g.activity = restored.activity;
                if worker.spec.adopt {
                    g.routine_outcome = restored.outcome;
                }
            }
            if let Some(t) = transport {
                worker.connect_transport(t);
            } else {
                worker.connect_process();
            }
        });
        run
    }

    pub fn session_rule(environment: &HashMap<String, String>) -> Option<String> {
        let vars = ProcessLauncher::session_variables(environment);
        let session = vars.get("ROTA_SESSION")?;
        let routine = vars.get("ROTA_ROUTINE")?;
        let mut rule = format!(
            "This session is a run of the Rota routine {routine}, Rota session {session}. \
The environment variables ROTA_SESSION, ROTA_ROUTINE and ROTA_CLI are not set in your commands"
        );
        if let Some(cli) = vars.get("ROTA_CLI") {
            rule.push_str(&format!(
                "; to show the user a Mac notification that opens this session, run \
'{cli}' notify --session {session} \"message\", adding --needs-reply when they must answer \
or confirm something"
            ));
        }
        rule.push('.');
        Some(rule)
    }

    pub fn auto_answer(method: &str, params: &Value) -> Option<Value> {
        if method != "session/request_permission" {
            return None;
        }
        let options = params.get("options")?.as_array()?;
        let allow = options.iter().find(|o| {
            o.get("kind")
                .and_then(Value::as_str)
                .is_some_and(|k| k.starts_with("allow"))
        })?;
        let option_id = allow.get("optionId")?;
        Some(json!({"outcome": {"outcome": "selected", "optionId": option_id}}))
    }

    fn connect_process(self: &Arc<Self>) {
        let mut args = vec![
            "agent".to_string(),
            "--leader".to_string(),
            "--always-approve".to_string(),
        ];
        args.extend(self.spec.model_flags("--reasoning-effort"));
        args.push("stdio".to_string());
        let mut cmd = ProcessLauncher::login_shell_command(
            &self.spec.executable,
            &args,
            &ProcessLauncher::helper_directory(),
            &HashMap::new(),
        );
        cmd.stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null());
        let mut child = match cmd.spawn() {
            Ok(c) => c,
            Err(err) => {
                self.journal.finish(RunOutcome::LaunchFailed(err.to_string()));
                return;
            }
        };
        let (Some(stdin), Some(stdout)) = (child.stdin.take(), child.stdout.take()) else {
            let _ = child.kill();
            self.journal
                .finish(RunOutcome::LaunchFailed("Missing Grok pipes".into()));
            return;
        };
        self.state.lock().unwrap().child = Some(child);
        self.connect_transport(LineTransport::spawn(stdin, stdout));
    }

    fn connect_transport(self: &Arc<Self>, transport: Arc<dyn MessageTransport>) {
        let peer = JsonRpcPeer::new(transport, true);
        self.state.lock().unwrap().peer = Some(Arc::clone(&peer));

        let weak_n = Arc::downgrade(self);
        peer.set_on_notification(Arc::new(move |method, params| {
            if let Some(me) = weak_n.upgrade() {
                me.handle_notification(&method, &params);
            }
        }));

        let weak_r = Arc::downgrade(self);
        peer.set_on_request_async(Arc::new(move |id, method, params, reply| {
            let Some(me) = weak_r.upgrade() else {
                reply(None);
                return;
            };
            let sid = me.state.lock().unwrap().session_id.clone();
            if params.get("sessionId").and_then(Value::as_str) != sid.as_deref() {
                if let Some(p) = me.state.lock().unwrap().peer.clone() {
                    p.dismiss_request(&id);
                }
                return;
            }
            if method == "session/request_permission"
                && let Some(auto) = Self::auto_answer(&method, &params)
            {
                reply(Some(auto));
                return;
            }
            let Some(mut req) = QuestionRequest::grok(&method, &params) else {
                reply(None);
                return;
            };
            req.question.id = id;
            let resp_fn = req.response;
            let once = Mutex::new(Some(reply));
            me.journal.ask(req.question, true, move |ans| {
                if let Some(cb) = once.lock().unwrap().take() {
                    cb(Some(resp_fn(&ans)));
                }
            });
        }));

        let weak_c = Arc::downgrade(self);
        peer.set_on_close(Arc::new(move || {
            if let Some(me) = weak_c.upgrade() {
                me.connection_lost();
            }
        }));

        let weak_init = Arc::downgrade(self);
        peer.request(
            "initialize",
            json!({"protocolVersion": 1, "clientCapabilities": {}}),
            move |res| {
                if let Some(me) = weak_init.upgrade() {
                    me.initialized(res);
                }
            },
        );

        if let Some(secs) = self.spec.timeout_secs {
            let weak_to = Arc::downgrade(self);
            std::thread::spawn(move || {
                std::thread::sleep(Duration::from_secs_f64(secs.max(0.0)));
                if let Some(me) = weak_to.upgrade() {
                    me.cancel(RunOutcome::TimedOut);
                }
            });
        }
    }

    pub(super) fn begin_prompt(self: &Arc<Self>, id: &str) {
        if self.journal.is_finished() {
            return;
        }
        let early = {
            let mut g = self.state.lock().unwrap();
            if g.stop_reason.is_some() {
                return;
            }
            std::mem::take(&mut g.early)
        };
        self.prompt(&self.spec.prompt, id);
        for msg in early {
            self.prompt(&msg, id);
        }
    }

    pub(super) fn prompt(self: &Arc<Self>, message: &str, session_id: &str) {
        let peer = {
            let mut g = self.state.lock().unwrap();
            g.open_prompts += 1;
            g.peer.clone()
        };
        let Some(peer) = peer else {
            return;
        };
        let me = Arc::clone(self);
        peer.request(
            "session/prompt",
            json!({
                "sessionId": session_id,
                "prompt": HarnessInput::blocks(message, LaunchMode::GrokAcp),
            }),
            move |res| me.prompt_ended(res),
        );
    }

    fn prompt_ended(&self, result: Result<Value, JsonRpcError>) {
        self.journal.end_text();
        let (open_prompts, stop_reason, running_bg, outcome) = {
            let mut g = self.state.lock().unwrap();
            g.open_prompts -= 1;
            let stop = g.stop_reason.clone();
            let outcome = match &result {
                Ok(val) => stop
                    .clone()
                    .unwrap_or_else(|| GrokRecovery::outcome(val.get("stopReason").and_then(Value::as_str))),
                Err(err) => {
                    if err.message == "connection closed" {
                        self.journal.require_reconciliation();
                    }
                    self.journal.line(&format!("[error] {}", err.message));
                    stop.clone().unwrap_or(RunOutcome::Failed { exit_code: 1 })
                }
            };
            if g.routine_outcome.is_none() || outcome != RunOutcome::Succeeded {
                g.routine_outcome = Some(outcome.clone());
            }
            (g.open_prompts, stop, g.activity.running(), outcome)
        };
        if open_prompts <= 0 && outcome == RunOutcome::Succeeded && stop_reason.is_none() && running_bg > 0 {
            self.journal.record(
                TranscriptItemKind::Status,
                &TranscriptService::waiting(running_bg),
            );
        }
        self.finish_if_idle();
    }

    pub(super) fn cancel(self: &Arc<Self>, reason: RunOutcome) {
        if self.journal.is_finished() {
            return;
        }
        let (sid, peer) = {
            let mut g = self.state.lock().unwrap();
            g.stop_reason = Some(reason.clone());
            (g.session_id.clone(), g.peer.clone())
        };
        if sid.is_none() && self.spec.resume.is_none() {
            self.journal.finish(reason);
            self.disconnect();
            return;
        }
        if let (Some(sid), Some(peer)) = (sid, peer) {
            peer.notify("session/cancel", json!({"sessionId": sid}));
        }
        let weak = Arc::downgrade(self);
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_secs(15));
            if let Some(me) = weak.upgrade()
                && !me.journal.is_finished()
            {
                me.journal.record(
                    TranscriptItemKind::Status,
                    "Grok has not confirmed cancellation; waiting for the native session",
                );
                let r = me.state.lock().unwrap().stop_reason.clone();
                if let Some(r) = r {
                    me.cancel(r);
                }
            }
        });
    }

    pub(super) fn fail(&self, result: Result<Value, JsonRpcError>, step: &str) {
        if self.journal.is_finished() {
            return;
        }
        if let Err(err) = result {
            let absent = step == "session/load"
                && err.server_code.as_deref() == Some("FS_NOT_FOUND")
                && self
                    .spec
                    .resume
                    .as_deref()
                    .and_then(|s| NativeTranscript::locate(Harness::Grok, s))
                    .is_none()
                && Path::new(&self.spec.working_directory).exists();
            if self.spec.resume.is_some() && !absent {
                self.journal.require_reconciliation();
            }
            self.journal
                .finish(RunOutcome::LaunchFailed(format!("{step}: {}", err.message)));
        }
        self.disconnect();
    }

    fn connection_lost(&self) {
        if self.journal.is_finished() {
            return;
        }
        let has_session = self.state.lock().unwrap().session_id.is_some() || self.spec.resume.is_some();
        if has_session {
            self.journal.require_reconciliation();
        }
        self.journal.finish(RunOutcome::Interrupted);
    }

    pub fn disconnect(&self) {
        let (peer, child) = {
            let mut g = self.state.lock().unwrap();
            (g.peer.take(), g.child.take())
        };
        if let Some(p) = peer {
            p.close();
        }
        if let Some(mut c) = child {
            let _ = c.kill();
            let _ = c.wait();
        }
    }
}

impl RunControl for GrokAcpRun {
    fn stop(&self) {
        if self.journal.is_finished() {
            return;
        }
        let (sid, peer) = {
            let mut g = self.state.lock().unwrap();
            g.stop_reason = Some(RunOutcome::Cancelled);
            (g.session_id.clone(), g.peer.clone())
        };
        if sid.is_none() && self.spec.resume.is_none() {
            self.journal.finish(RunOutcome::Cancelled);
            self.disconnect();
        } else if let (Some(sid), Some(peer)) = (sid, peer) {
            peer.notify("session/cancel", json!({"sessionId": sid}));
        }
    }

    fn send(&self, message: &str) {
        if self.journal.is_finished() {
            self.journal.undelivered(message);
            return;
        }
        self.journal.record(TranscriptItemKind::User, message);
        let (sid, peer) = {
            let mut g = self.state.lock().unwrap();
            if let (Some(sid), false, Some(peer)) = (g.session_id.clone(), g.loading, g.peer.clone()) {
                g.open_prompts += 1;
                (Some(sid), Some(peer))
            } else {
                g.early.push(message.to_string());
                (None, None)
            }
        };
        if let (Some(sid), Some(peer)) = (sid, peer) {
            let j = Arc::clone(&self.journal);
            peer.request(
                "session/prompt",
                json!({
                    "sessionId": sid,
                    "prompt": HarnessInput::blocks(message, LaunchMode::GrokAcp),
                }),
                move |res| {
                    j.end_text();
                    if let Err(err) = res {
                        j.line(&format!("[error] {}", err.message));
                    }
                },
            );
        }
    }
}
