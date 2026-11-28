use std::collections::HashMap;
use std::path::Path;
use std::process::Stdio;
use std::sync::{Arc, Mutex, mpsc};
use std::time::Duration;

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::model::{Harness, SessionConfiguration};
use crate::rpc::{JsonRpcPeer, LineTransport, MessageTransport};
use crate::runners::{ProcessLauncher, is_executable_file};

pub use super::catalog_providers::{
    AntigravityCatalog, AntigravityConfiguration, AntigravityRow, GrokCatalog,
};

#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ModelOption {
    pub id: String,
    pub title: String,
    pub efforts: Vec<String>,
    pub is_default: bool,
    pub aliases: Vec<String>,
}

impl ModelOption {
    pub fn new(
        id: impl Into<String>,
        title: impl Into<String>,
        efforts: Vec<String>,
        is_default: bool,
        aliases: Vec<String>,
    ) -> Self {
        Self {
            id: id.into(),
            title: title.into(),
            efforts,
            is_default,
            aliases,
        }
    }

    pub fn strip_effort_suffix(label: &str, effort: &str) -> String {
        if effort.is_empty() {
            return label.to_string();
        }
        let mut chars = effort.chars();
        let cap = match chars.next() {
            Some(first) => format!("{}{}", first.to_uppercase(), chars.as_str().to_ascii_lowercase()),
            None => String::new(),
        };
        let suffix = format!(" ({cap})");
        label.strip_suffix(&suffix).unwrap_or(label).to_string()
    }

    pub fn matches(&self, value: Option<&str>) -> bool {
        let Some(v) = value else {
            return false;
        };
        self.id == v || self.aliases.iter().any(|a| a == v)
    }
}

pub struct ModelCatalog;

impl ModelCatalog {
    pub fn models(harness: Harness, executable: &str) -> Vec<ModelOption> {
        if !is_executable_file(Path::new(executable)) {
            return Vec::new();
        }
        match harness {
            Harness::Claude => ClaudeConfiguration::read(
                executable,
                &std::env::temp_dir(),
                None,
                None,
                None,
                Duration::from_secs(8),
            )
            .map(|c| c.models)
            .unwrap_or_default(),
            Harness::Codex => Self::codex_models(executable, Duration::from_secs(10)),
            Harness::Grok => Self::grok_models(executable),
            Harness::Antigravity => AntigravityCatalog::read(executable),
            Harness::Shell => Vec::new(),
        }
    }

    pub fn parse_claude_models(value: &Value) -> Vec<ModelOption> {
        let Some(rows) = value.get("models").and_then(Value::as_array) else {
            return Vec::new();
        };
        let default_id = rows
            .iter()
            .find(|r| r.get("value").and_then(Value::as_str) == Some("default"))
            .and_then(|r| r.get("resolvedModel").and_then(Value::as_str));
        let mut options: Vec<ModelOption> = Vec::new();
        for row in rows {
            if row.get("value").and_then(Value::as_str) == Some("default") {
                continue;
            }
            let (Some(id), Some(title)) = (
                row.get("resolvedModel").and_then(Value::as_str),
                row.get("displayName").and_then(Value::as_str),
            ) else {
                continue;
            };
            if id.is_empty() {
                continue;
            }
            let alias = row.get("value").and_then(Value::as_str);
            if let Some(existing) = options.iter_mut().find(|o| o.id == id) {
                if let Some(a) = alias
                    && a != id
                {
                    existing.aliases.push(a.to_string());
                }
                continue;
            }
            let efforts: Vec<String> = row
                .get("supportedEffortLevels")
                .and_then(Value::as_array)
                .map(|arr| {
                    arr.iter()
                        .filter_map(Value::as_str)
                        .map(ToOwned::to_owned)
                        .collect()
                })
                .unwrap_or_default();
            let aliases = match alias {
                Some(a) if a != id => vec![a.to_string()],
                _ => Vec::new(),
            };
            options.push(ModelOption::new(
                id,
                title,
                efforts,
                Some(id) == default_id,
                aliases,
            ));
        }
        options
    }

    pub fn parse_grok_models(text: &str) -> Vec<ModelOption> {
        text.lines()
            .filter_map(|line| {
                let trimmed = line.trim();
                let rest = trimmed
                    .strip_prefix("* ")
                    .or_else(|| trimmed.strip_prefix("- "))?;
                let words: Vec<&str> = rest.split_whitespace().collect();
                let id = *words.first()?;
                Some(ModelOption::new(
                    id,
                    id,
                    Vec::new(),
                    words.contains(&"(default)"),
                    Vec::new(),
                ))
            })
            .collect()
    }

    fn grok_models(executable: &str) -> Vec<ModelOption> {
        if let Some(models) = GrokCatalog::read(executable, Duration::from_secs(10)) {
            return models;
        }
        let (st, out) = ProcessLauncher::capture(
            executable,
            &["models".into()],
            &std::env::temp_dir(),
            Some(Duration::from_secs(10)),
            false,
            true,
            &HashMap::new(),
        );
        if st == 0 {
            Self::parse_grok_models(&out)
        } else {
            Vec::new()
        }
    }

    pub fn parse_codex_models(value: &Value) -> Vec<ModelOption> {
        let Some(data) = value.get("data").and_then(Value::as_array) else {
            return Vec::new();
        };
        data.iter()
            .filter_map(|model| {
                if model.get("hidden").and_then(Value::as_bool) == Some(true) {
                    return None;
                }
                let id = model.get("id").and_then(Value::as_str)?;
                let title = model.get("displayName").and_then(Value::as_str).unwrap_or(id);
                let efforts = model
                    .get("supportedReasoningEfforts")
                    .and_then(Value::as_array)
                    .map(|arr| {
                        arr.iter()
                            .filter_map(|e| {
                                e.get("reasoningEffort")
                                    .and_then(Value::as_str)
                                    .or_else(|| e.as_str())
                                    .map(ToOwned::to_owned)
                            })
                            .collect()
                    })
                    .unwrap_or_default();
                let is_default = model.get("isDefault").and_then(Value::as_bool) == Some(true);
                Some(ModelOption::new(id, title, efforts, is_default, Vec::new()))
            })
            .collect()
    }

    fn codex_models(executable: &str, timeout: Duration) -> Vec<ModelOption> {
        let mut cmd = ProcessLauncher::login_shell_command(
            executable,
            &["app-server".into()],
            &std::env::temp_dir(),
            &HashMap::new(),
        );
        cmd.stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null());
        let Ok(mut child) = cmd.spawn() else {
            return Vec::new();
        };
        let (Some(stdin), Some(stdout)) = (child.stdin.take(), child.stdout.take()) else {
            let _ = child.kill();
            return Vec::new();
        };
        let transport = LineTransport::spawn(stdin, stdout);
        let peer = JsonRpcPeer::new(transport, false);
        let (tx, rx) = mpsc::channel::<Vec<ModelOption>>();
        let tx_close = tx.clone();
        peer.set_on_close(Arc::new(move || {
            let _ = tx_close.send(Vec::new());
        }));
        let peer_inner = Arc::clone(&peer);
        peer.request(
            "initialize",
            json!({"clientInfo": {"name": "rota", "version": "1"}}),
            move |_| {
                peer_inner.notify("initialized", json!({}));
                peer_inner.request("model/list", json!({}), move |res| {
                    let parsed = res.ok().map(|v| Self::parse_codex_models(&v)).unwrap_or_default();
                    let _ = tx.send(parsed);
                });
            },
        );
        let models = rx.recv_timeout(timeout).unwrap_or_default();
        peer.close();
        let _ = child.kill();
        let _ = child.wait();
        models
    }
}

#[derive(Debug, Clone)]
pub struct ClaudeConfiguration {
    pub session: SessionConfiguration,
    pub models: Vec<ModelOption>,
}

impl ClaudeConfiguration {
    pub const SETTINGS_ID: &'static str = "rota-settings";
    pub const INITIALIZE_ID: &'static str = "rota-initialize";

    pub fn request_bytes(subtype: &str, id: &str) -> Vec<u8> {
        let mut v = serde_json::to_vec(&json!({
            "type": "control_request",
            "request_id": id,
            "request": {"subtype": subtype}
        }))
        .unwrap_or_default();
        v.push(b'\n');
        v
    }

    pub fn applied(event: &Value) -> Option<SessionConfiguration> {
        if event.get("type").and_then(Value::as_str) != Some("control_response") {
            return None;
        }
        let resp = event.get("response")?;
        if resp.get("request_id").and_then(Value::as_str) != Some(Self::SETTINGS_ID)
            || resp.get("subtype").and_then(Value::as_str) != Some("success")
        {
            return None;
        }
        let applied = resp.get("response")?.get("applied")?;
        let model = applied.get("model").and_then(Value::as_str)?;
        let effort = match applied.get("effort") {
            Some(Value::Null) => Some("none".to_string()),
            Some(Value::String(s)) => Some(s.clone()),
            _ => None,
        };
        Some(SessionConfiguration::new(
            Some(model.to_string()),
            effort,
            None,
            None,
        ))
    }

    pub fn read(
        executable: &str,
        directory: &Path,
        model: Option<&str>,
        effort: Option<&str>,
        resume: Option<&str>,
        timeout: Duration,
    ) -> Option<Self> {
        let mut args = vec![
            "-p".to_string(),
            "--input-format".to_string(),
            "stream-json".to_string(),
            "--output-format".to_string(),
            "stream-json".to_string(),
            "--verbose".to_string(),
            "--no-session-persistence".to_string(),
        ];
        for (flag, val) in [("--model", model), ("--effort", effort), ("--resume", resume)] {
            if let Some(v) = val {
                args.push(flag.to_string());
                args.push(v.to_string());
            }
        }
        let mut cmd = ProcessLauncher::login_shell_command(executable, &args, directory, &HashMap::new());
        cmd.stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null());
        let mut child = cmd.spawn().ok()?;
        let (stdin, stdout) = (child.stdin.take()?, child.stdout.take()?);
        let transport = LineTransport::spawn(stdin, stdout);

        #[derive(Default)]
        struct State {
            config: Option<SessionConfiguration>,
            models: Vec<ModelOption>,
            initialized: bool,
        }
        let state = Arc::new(Mutex::new(State::default()));
        let (tx, rx) = mpsc::channel::<()>();
        let tx_close = tx.clone();
        let st_msg = Arc::clone(&state);
        transport.set_handlers(
            Arc::new(move |data| {
                let Ok(ev) = serde_json::from_slice::<Value>(&data) else {
                    return;
                };
                let mut g = st_msg.lock().unwrap();
                if let Some(app) = Self::applied(&ev) {
                    g.config = Some(app);
                }
                if let Some(resp) = ev.get("response")
                    && resp.get("request_id").and_then(Value::as_str) == Some(Self::INITIALIZE_ID)
                {
                    g.initialized = true;
                    g.models = ModelCatalog::parse_claude_models(resp.get("response").unwrap_or(&json!({})));
                }
                if g.initialized && g.config.is_some() {
                    let _ = tx.send(());
                }
            }),
            Arc::new(move || {
                let _ = tx_close.send(());
            }),
        );

        let init_line = Self::request_bytes("initialize", Self::INITIALIZE_ID);
        let set_line = Self::request_bytes("get_settings", Self::SETTINGS_ID);
        transport.send(&init_line[..init_line.len().saturating_sub(1)]);
        transport.send(&set_line[..set_line.len().saturating_sub(1)]);
        let _ = rx.recv_timeout(timeout);
        transport.close();
        let _ = child.kill();
        let _ = child.wait();
        let g = state.lock().unwrap();
        g.config.clone().map(|session| Self {
            session,
            models: g.models.clone(),
        })
    }
}
