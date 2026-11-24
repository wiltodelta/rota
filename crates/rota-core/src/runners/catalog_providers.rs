use std::collections::HashMap;
use std::path::Path;
use std::process::Stdio;
use std::sync::{Arc, Mutex, mpsc};
use std::time::{Duration, Instant};

use serde_json::{Value, json};

use crate::model::SessionConfiguration;
use crate::rpc::{JsonRpcPeer, LineTransport};
use crate::runners::{LaunchSpec, ModelOption, ProcessLauncher};

pub struct GrokCatalog;

impl GrokCatalog {
    pub fn read(executable: &str, timeout: Duration) -> Option<Vec<ModelOption>> {
        let mut cmd = ProcessLauncher::login_shell_command(
            executable,
            &["agent".into(), "--no-leader".into(), "stdio".into()],
            &ProcessLauncher::helper_directory(),
            &HashMap::new(),
        );
        cmd.stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null());
        let mut child = cmd.spawn().ok()?;
        let (stdin, stdout) = (child.stdin.take()?, child.stdout.take()?);
        let transport = LineTransport::spawn(stdin, stdout);
        let peer = JsonRpcPeer::new(transport, false);
        let (tx, rx) = mpsc::channel::<Option<Vec<ModelOption>>>();
        let tx_close = tx.clone();
        peer.set_on_close(Arc::new(move || {
            let _ = tx_close.send(None);
        }));
        peer.request(
            "initialize",
            json!({"protocolVersion": 1, "clientCapabilities": {}}),
            move |res| {
                let parsed = res
                    .ok()
                    .and_then(|v| v.get("_meta").and_then(|m| m.get("modelState")).cloned())
                    .and_then(|ms| Self::parse(&ms));
                let _ = tx.send(parsed);
            },
        );
        let out = rx.recv_timeout(timeout).ok().flatten();
        peer.close();
        let _ = child.kill();
        let _ = child.wait();
        out
    }

    pub fn parse(state: &Value) -> Option<Vec<ModelOption>> {
        let rows = state.get("availableModels")?.as_array()?;
        if rows.is_empty() {
            return None;
        }
        let current = state.get("currentModelId").and_then(Value::as_str);
        Some(
            rows.iter()
                .filter_map(|row| {
                    let id = row.get("modelId").and_then(Value::as_str)?;
                    let title = row.get("name").and_then(Value::as_str).unwrap_or(id);
                    let meta = row.get("_meta");
                    let supports_effort = meta
                        .and_then(|m| m.get("supportsReasoningEffort"))
                        .and_then(Value::as_bool)
                        == Some(true);
                    let efforts = if supports_effort {
                        meta.and_then(|m| m.get("reasoningEfforts"))
                            .and_then(Value::as_array)
                            .map(|arr| {
                                arr.iter()
                                    .filter_map(|e| {
                                        e.get("value")
                                            .or_else(|| e.get("id"))
                                            .and_then(Value::as_str)
                                            .map(ToOwned::to_owned)
                                    })
                                    .collect()
                            })
                            .unwrap_or_default()
                    } else {
                        Vec::new()
                    };
                    Some(ModelOption::new(
                        id,
                        title,
                        efforts,
                        Some(id) == current,
                        Vec::new(),
                    ))
                })
                .collect(),
        )
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AntigravityRow {
    pub id: String,
    pub title: String,
}

impl AntigravityRow {
    pub fn candidate(&self) -> &str {
        if let Some((stem, tier)) = self.id.rsplit_once('-')
            && matches!(tier, "low" | "medium" | "high" | "xhigh" | "max")
        {
            return stem;
        }
        &self.id
    }
}

pub struct AntigravityCatalog;

impl AntigravityCatalog {
    pub fn rows(text: &str) -> Vec<AntigravityRow> {
        text.lines()
            .filter_map(|line| {
                let (id, title) = line.split_once('\t')?;
                if id.is_empty() || title.is_empty() {
                    return None;
                }
                Some(AntigravityRow {
                    id: id.to_string(),
                    title: title.to_string(),
                })
            })
            .collect()
    }

    pub fn read(executable: &str) -> Vec<ModelOption> {
        Self::read_result(executable).0
    }

    pub fn read_result(executable: &str) -> (Vec<ModelOption>, bool) {
        let deadline = Instant::now() + Duration::from_secs(75);
        let (st, out) = ProcessLauncher::capture(
            executable,
            &["models".into()],
            &std::env::temp_dir(),
            Some(Duration::from_secs(45)),
            false,
            true,
            &HashMap::new(),
        );
        if st != 0 {
            return (Vec::new(), false);
        }
        let listed = Self::rows(&out);
        let mut candidates: Vec<String> = Vec::new();
        for r in &listed {
            let c = r.candidate().to_string();
            if !candidates.contains(&c) {
                candidates.push(c);
            }
        }
        let current = Self::command("model", executable, None, deadline)
            .and_then(|m| m.get("id").and_then(Value::as_str).map(ToOwned::to_owned));
        let default_known = current
            .as_deref()
            .is_some_and(|cur| listed.iter().any(|r| r.id == cur));

        let mut probe_order = candidates.clone();
        probe_order.sort_by_key(|cand| {
            !listed
                .iter()
                .any(|r| r.candidate() == cand && Some(r.id.as_str()) == current.as_deref())
        });

        let found: Mutex<HashMap<String, ModelOption>> = Mutex::new(HashMap::new());
        let workers = candidates.len().min(4);
        std::thread::scope(|scope| {
            for worker in 0..workers {
                let listed_ref = &listed;
                let probe_ref = &probe_order;
                let cur_ref = current.as_deref();
                let found_ref = &found;
                scope.spawn(move || {
                    let mut idx = worker;
                    while idx < probe_ref.len() {
                        if Instant::now() >= deadline {
                            break;
                        }
                        let cand = &probe_ref[idx];
                        let members: Vec<AntigravityRow> = listed_ref
                            .iter()
                            .filter(|r| r.candidate() == cand)
                            .cloned()
                            .collect();
                        let model = Self::command("model", executable, Some(cand), deadline);
                        let effort = model
                            .as_ref()
                            .and_then(|_| Self::command("effort", executable, Some(cand), deadline));
                        if let Some(opt) =
                            Self::family(cand, &members, model.as_ref(), effort.as_ref(), cur_ref)
                        {
                            found_ref.lock().unwrap().insert(cand.clone(), opt);
                        }
                        idx += 4;
                    }
                });
            }
        });

        let map = found.into_inner().unwrap();
        let complete =
            !candidates.is_empty() && default_known && candidates.iter().all(|c| map.contains_key(c));
        let ordered = candidates
            .into_iter()
            .filter_map(|c| map.get(&c).cloned())
            .collect();
        (ordered, complete)
    }

    pub fn family(
        candidate: &str,
        rows: &[AntigravityRow],
        model: Option<&Value>,
        effort: Option<&Value>,
        current: Option<&str>,
    ) -> Option<ModelOption> {
        let model = model?;
        let effort = effort?;
        let resolved = model.get("id")?.as_str()?;
        if !rows.iter().any(|r| r.id == resolved) {
            return None;
        }
        let label = model.get("label")?.as_str()?;
        let tier = model.get("effort")?.as_str()?;
        let adjustable = effort.get("adjustable")?.as_bool()?;
        let available = if adjustable {
            let arr = effort.get("available")?.as_array()?;
            let mut list = Vec::with_capacity(arr.len());
            for v in arr {
                list.push(v.as_str()?.to_string());
            }
            list
        } else {
            Vec::new()
        };
        let title = ModelOption::strip_effort_suffix(label, tier);
        let is_default = rows.iter().any(|r| Some(r.id.as_str()) == current);
        let aliases = rows.iter().map(|r| r.id.clone()).collect();
        Some(ModelOption::new(candidate, title, available, is_default, aliases))
    }

    fn command(name: &str, executable: &str, model: Option<&str>, deadline: Instant) -> Option<Value> {
        let now = Instant::now();
        if now >= deadline {
            return None;
        }
        let remaining = (deadline - now).min(Duration::from_secs(30));
        let mut args = vec![
            "-p".to_string(),
            format!("/{name}"),
            "--output-format".to_string(),
            "json".to_string(),
        ];
        if let Some(m) = model {
            args.push("--model".to_string());
            args.push(m.to_string());
        }
        let (st, out) = ProcessLauncher::capture(
            executable,
            &args,
            &std::env::temp_dir(),
            Some(remaining),
            false,
            true,
            &HashMap::new(),
        );
        if st != 0 {
            return None;
        }
        Self::payload(&out, name)
    }

    pub fn payload(output: &str, command_name: &str) -> Option<Value> {
        let val: Value = serde_json::from_str(output).ok()?;
        if val.get("status").and_then(Value::as_str) != Some("SUCCESS") {
            return None;
        }
        let cmd = val.get("command")?;
        if cmd.get("name").and_then(Value::as_str) != Some(command_name) {
            return None;
        }
        cmd.get("data").cloned()
    }
}

pub struct AntigravityConfiguration;

impl AntigravityConfiguration {
    pub fn read(spec: &LaunchSpec) -> Option<SessionConfiguration> {
        let mut args = vec![
            "-p".to_string(),
            "/model".to_string(),
            "--output-format".to_string(),
            "json".to_string(),
        ];
        args.extend(spec.model_flags("--effort"));
        if let Some(resume) = &spec.resume {
            args.push("--conversation".to_string());
            args.push(resume.clone());
        }
        let (st, out) = ProcessLauncher::capture(
            &spec.executable,
            &args,
            Path::new(&spec.working_directory),
            Some(Duration::from_secs(30)),
            false,
            true,
            &spec.environment,
        );
        if st != 0 {
            return None;
        }
        let model = AntigravityCatalog::payload(&out, "model")?;
        let id = model.get("id").and_then(Value::as_str)?;
        if id.is_empty() {
            return None;
        }
        let effort = model.get("effort").and_then(Value::as_str).map(ToOwned::to_owned);
        let title = model
            .get("label")
            .and_then(Value::as_str)
            .map(|lbl| ModelOption::strip_effort_suffix(lbl, effort.as_deref().unwrap_or("")));
        Some(SessionConfiguration::new(
            Some(id.to_string()),
            effort,
            title,
            None,
        ))
    }
}
