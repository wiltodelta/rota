use std::fs::File;
use std::io::{BufRead, BufReader};
use std::sync::Arc;

use serde_json::{Map, Value, json};

use crate::model::{Harness, RunOutcome, SessionConfiguration};
use crate::rpc::JsonRpcError;
use crate::runners::{GrokAcpRun, GrokActivity, NativeTranscript, SessionBridge};

pub struct GrokRecovery {
    pub activity: GrokActivity,
    pub outcome: Option<RunOutcome>,
}

impl GrokRecovery {
    pub fn load(session: &str) -> Self {
        let mut recovery = Self {
            activity: GrokActivity::default(),
            outcome: None,
        };
        let Some(source) = NativeTranscript::locate(Harness::Grok, session) else {
            return recovery;
        };
        let Ok(file) = File::open(source) else {
            return recovery;
        };
        for line in BufReader::new(file).lines().map_while(Result::ok) {
            let Ok(row) = serde_json::from_str::<Value>(&line) else {
                continue;
            };
            let Some(params) = row.get("params") else {
                continue;
            };
            if params.get("sessionId").and_then(Value::as_str) != Some(session) {
                continue;
            }
            let Some(update) = params.get("update") else {
                continue;
            };
            recovery.activity.apply(update);
            if update.get("sessionUpdate").and_then(Value::as_str) == Some("turn_completed") {
                recovery.outcome = Some(Self::outcome(update.get("stop_reason").and_then(Value::as_str)));
            }
        }
        recovery
    }

    pub fn outcome(reason: Option<&str>) -> RunOutcome {
        match reason {
            Some("end_turn" | "max_tokens" | "max_turn_requests" | "refusal") => RunOutcome::Succeeded,
            Some("cancelled") => RunOutcome::Cancelled,
            _ => RunOutcome::Failed { exit_code: 1 },
        }
    }
}

impl GrokAcpRun {
    pub(super) fn initialized(self: &Arc<Self>, result: Result<Value, JsonRpcError>) {
        if self.journal.is_finished() {
            return;
        }
        let Ok(val) = result else {
            self.fail(result, "initialize");
            return;
        };
        let ver = val
            .get("agentInfo")
            .and_then(|a| a.get("version"))
            .or_else(|| val.get("_meta").and_then(|m| m.get("agentVersion")))
            .and_then(Value::as_str)
            .map(ToOwned::to_owned);
        self.journal.provenance(None, ver);

        let dir = self
            .spec
            .resume
            .as_deref()
            .and_then(|s| NativeTranscript::locate(Harness::Grok, s))
            .and_then(|p| NativeTranscript::grok_directory(&p))
            .unwrap_or_else(|| self.spec.working_directory.clone());

        let mut params = Map::new();
        params.insert("cwd".into(), json!(dir));
        params.insert("mcpServers".into(), json!(SessionBridge::grok(&self.spec)));
        if let Some(rule) = Self::session_rule(&self.spec.environment) {
            params.insert("_meta".into(), json!({"rules": rule}));
        }

        let Some(peer) = self.state.lock().unwrap().peer.clone() else {
            return;
        };
        if let Some(session) = self.spec.resume.clone() {
            params.insert("sessionId".into(), json!(session));
            {
                let mut g = self.state.lock().unwrap();
                g.session_id = Some(session.clone());
                g.loading = true;
            }
            let me = Arc::clone(self);
            peer.request("session/load", Value::Object(params), move |res| {
                me.state.lock().unwrap().loading = false;
                let Ok(val) = res else {
                    me.fail(res, "session/load");
                    return;
                };
                me.configure(&val);
                if me.spec.adopt {
                    me.restored(&val, &session);
                } else {
                    me.session_ready(&session);
                }
            });
        } else {
            let me = Arc::clone(self);
            peer.request("session/new", Value::Object(params), move |res| {
                let Ok(val) = &res else {
                    me.fail(res, "session/new");
                    return;
                };
                let Some(id) = val.get("sessionId").and_then(Value::as_str) else {
                    me.fail(res, "session/new");
                    return;
                };
                let cfg = me.configure(val);
                if let Some(req_model) = &me.spec.model
                    && cfg.model.as_ref() != Some(req_model)
                {
                    me.journal.finish(RunOutcome::LaunchFailed(
                        "Grok did not apply the requested model.".into(),
                    ));
                    me.disconnect();
                    return;
                }
                let suffix = cfg.model.map_or_else(String::new, |m| format!(", {m}"));
                me.journal.line(&format!("[grok session {id}{suffix}]"));
                me.session_ready(id);
            });
        }
    }

    fn restored(self: &Arc<Self>, value: &Value, session: &str) {
        let (early, idle, stop_reason, peer) = {
            let mut g = self.state.lock().unwrap();
            if let Some(running) = value
                .get("_meta")
                .and_then(|m| m.get("x.ai/runningPromptId"))
                .and_then(Value::as_str)
            {
                g.activity.adopt_running(running);
                g.routine_outcome = None;
            }
            (
                std::mem::take(&mut g.early),
                g.activity.idle(),
                g.stop_reason.clone(),
                g.peer.clone(),
            )
        };
        self.journal.session(session);
        if stop_reason.is_some()
            && !idle
            && let Some(p) = &peer
        {
            p.notify("session/cancel", json!({"sessionId": session}));
        }
        for msg in early {
            self.prompt(&msg, session);
        }
        let (now_idle, open_prompts, outcome) = {
            let g = self.state.lock().unwrap();
            (
                g.activity.idle(),
                g.open_prompts,
                g.stop_reason
                    .clone()
                    .or_else(|| g.routine_outcome.clone())
                    .unwrap_or(RunOutcome::Interrupted),
            )
        };
        if now_idle && open_prompts == 0 {
            self.journal.finish(outcome);
            self.disconnect();
        } else {
            self.finish_if_idle();
        }
    }

    pub(super) fn configure(&self, value: &Value) -> SessionConfiguration {
        let cfg = SessionConfiguration::acp(value);
        {
            let mut g = self.state.lock().unwrap();
            if cfg.model.is_some() {
                g.applied.model = cfg.model.clone();
            }
            if cfg.effort.is_some() {
                g.applied.effort = cfg.effort.clone();
            }
            if let Some(opts) = value.get("configOptions").and_then(Value::as_array)
                && let Some(eff) = opts
                    .iter()
                    .find(|o| o.get("id").and_then(Value::as_str) == Some("reasoning_effort"))
                && let Some(arr) = eff.get("options").and_then(Value::as_array)
            {
                g.effort_options = arr
                    .iter()
                    .filter_map(|v| v.get("value").and_then(Value::as_str).map(ToOwned::to_owned))
                    .collect();
            }
        }
        self.journal.configure(cfg.clone());
        cfg
    }

    fn session_ready(self: &Arc<Self>, id: &str) {
        self.state.lock().unwrap().session_id = Some(id.to_string());
        self.journal.session(id);
        self.apply_model(id, false);
    }

    fn apply_model(self: &Arc<Self>, id: &str, switched: bool) {
        if self.journal.is_finished() {
            return;
        }
        let (stop_set, cur_model, peer) = {
            let g = self.state.lock().unwrap();
            (g.stop_reason.is_some(), g.applied.model.clone(), g.peer.clone())
        };
        if stop_set {
            return;
        }
        let Some(req_model) = &self.spec.model else {
            self.apply_effort(id);
            return;
        };
        if cur_model.as_ref() == Some(req_model) {
            self.apply_effort(id);
            return;
        }
        if self.spec.resume.is_none() || switched {
            self.journal.finish(RunOutcome::LaunchFailed(
                "Grok did not apply the requested model.".into(),
            ));
            self.disconnect();
            return;
        }
        let Some(peer) = peer else {
            return;
        };
        let me = Arc::clone(self);
        let sid = id.to_string();
        peer.request(
            "session/set_config_option",
            json!({"sessionId": id, "configId": "model", "value": req_model}),
            move |res| match res {
                Ok(val) => {
                    me.configure(&val);
                    me.apply_model(&sid, true);
                }
                Err(_) => me.fail(res, "session/set_config_option"),
            },
        );
    }

    fn apply_effort(self: &Arc<Self>, id: &str) {
        let Some(effort) = &self.spec.effort else {
            self.begin_prompt(id);
            return;
        };
        let (supported, peer) = {
            let g = self.state.lock().unwrap();
            (g.effort_options.contains(effort), g.peer.clone())
        };
        if !supported {
            self.journal.finish(RunOutcome::LaunchFailed(
                "Grok does not advertise the requested effort for this model.".into(),
            ));
            self.disconnect();
            return;
        }
        let Some(peer) = peer else {
            return;
        };
        let me = Arc::clone(self);
        let sid = id.to_string();
        let eff_copy = effort.clone();
        peer.request(
            "session/set_config_option",
            json!({"sessionId": id, "configId": "reasoning_effort", "value": effort}),
            move |res| match res {
                Ok(val) => {
                    me.configure(&val);
                    let applied = me.state.lock().unwrap().applied.effort.clone();
                    if applied.as_deref() != Some(eff_copy.as_str()) {
                        me.journal.finish(RunOutcome::LaunchFailed(
                            "Grok did not apply the requested effort level.".into(),
                        ));
                        me.disconnect();
                    } else {
                        me.begin_prompt(&sid);
                    }
                }
                Err(_) => me.fail(res, "session/set_config_option"),
            },
        );
    }
}
