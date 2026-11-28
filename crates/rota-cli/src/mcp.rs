use std::collections::HashMap;
use std::io::{BufRead, Write};

use rota_core::{ControlError, ControlInterface};
use rota_platform::bundle_short_version;
use serde_json::{Map, Value, json};

use crate::format::format_sorted_pretty_json;

/// `rota mcp`: stdio JSON-RPC 2.0 MCP server exposing Rota's control tools.
pub struct McpServer<F> {
    caller: F,
    environment: HashMap<String, String>,
    version: String,
}

impl<F> McpServer<F>
where
    F: Fn(&str, Value) -> Result<Value, ControlError>,
{
    pub fn new(caller: F, environment: HashMap<String, String>) -> Self {
        Self {
            caller,
            environment,
            version: bundle_short_version(),
        }
    }

    pub fn serve<R: BufRead, W: Write>(&self, reader: R, mut writer: W) {
        for line_res in reader.lines() {
            let Ok(line) = line_res else {
                break;
            };
            let trimmed = line.trim_end_matches('\r');
            if trimmed.is_empty() {
                continue;
            }
            let Ok(message) = serde_json::from_str::<Value>(trimmed) else {
                continue;
            };
            let Some(obj) = message.as_object() else {
                continue;
            };
            let Some(method) = obj.get("method").and_then(Value::as_str) else {
                continue;
            };
            // JSON-RPC notifications omit `id` and must receive no output line.
            let Some(id) = obj.get("id").cloned() else {
                continue;
            };
            let params = obj
                .get("params")
                .and_then(Value::as_object)
                .cloned()
                .unwrap_or_default();

            let mut response = Map::new();
            response.insert("jsonrpc".into(), json!("2.0"));
            response.insert("id".into(), id);

            match method {
                "initialize" => {
                    let proto = params
                        .get("protocolVersion")
                        .and_then(Value::as_str)
                        .unwrap_or("2025-06-18");
                    response.insert(
                        "result".into(),
                        json!({
                            "protocolVersion": proto,
                            "capabilities": {"tools": {}},
                            "serverInfo": {"name": "rota", "version": self.version},
                            "instructions": "Rota is a Mac app that runs routines (prompts or shell commands) on a cron schedule on Claude Code, Codex, Grok Build, Antigravity or zsh. Use these tools to schedule, change, run and read them.",
                        }),
                    );
                }
                "ping" => {
                    response.insert("result".into(), json!({}));
                }
                "tools/list" => {
                    let tools: Vec<Value> = ControlInterface::tools()
                        .into_iter()
                        .map(|t| t.mcp_schema())
                        .collect();
                    response.insert("result".into(), json!({"tools": tools}));
                }
                "tools/call" => {
                    response.insert("result".into(), self.call_tool(&params));
                }
                _ => {
                    response.insert(
                        "error".into(),
                        json!({"code": -32601, "message": format!("Unknown method {method}")}),
                    );
                }
            }

            if let Ok(mut bytes) = serde_json::to_vec(&Value::Object(response)) {
                bytes.push(b'\n');
                let _ = writer.write_all(&bytes);
                let _ = writer.flush();
            }
        }
    }

    fn call_tool(&self, params: &Map<String, Value>) -> Value {
        let name = params.get("name").and_then(Value::as_str).unwrap_or("");
        let Some(tool) = ControlInterface::tools().into_iter().find(|t| t.name == name) else {
            return Self::text_content(&format!("Unknown tool {name}."), true);
        };
        let raw_args = params
            .get("arguments")
            .and_then(Value::as_object)
            .cloned()
            .unwrap_or_default();
        let bound = ControlInterface::session_arguments(raw_args, tool.method, &self.environment);
        match (self.caller)(tool.method.as_str(), Value::Object(bound)) {
            Ok(result) => {
                let text = format_sorted_pretty_json(&result);
                Self::text_content(&text, false)
            }
            Err(err) => Self::text_content(&err.message, true),
        }
    }

    fn text_content(text: &str, is_error: bool) -> Value {
        json!({
            "content": [{"type": "text", "text": text}],
            "isError": is_error,
        })
    }
}
