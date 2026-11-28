use std::collections::{HashMap, HashSet};

use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::model::QuestionRequest;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ToolOutputKind {
    Text,
    Image,
    Diff,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ToolOutputPart {
    pub kind: ToolOutputKind,
    pub text: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
}

impl ToolOutputPart {
    pub fn text(text: impl Into<String>) -> Self {
        Self {
            kind: ToolOutputKind::Text,
            text: text.into(),
            path: None,
        }
    }

    pub fn image(url: impl Into<String>, label: impl Into<String>) -> Self {
        Self {
            kind: ToolOutputKind::Image,
            text: url.into(),
            path: Some(label.into()),
        }
    }

    pub fn diff(path: impl Into<String>, diff: impl Into<String>) -> Self {
        Self {
            kind: ToolOutputKind::Diff,
            text: diff.into(),
            path: Some(path.into()),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ToolOutput {
    pub parts: Vec<ToolOutputPart>,
}

impl ToolOutput {
    pub const MARKER: &'static str = "[Rota tool output v1]\n";

    pub fn encoded(&self) -> String {
        if self.parts.iter().any(|p| p.kind != ToolOutputKind::Text)
            && let Ok(json) = serde_json::to_string(self)
        {
            return format!("{}{json}", Self::MARKER);
        }
        self.parts
            .iter()
            .map(|p| p.text.as_str())
            .collect::<Vec<_>>()
            .join("\n")
    }

    pub fn decode(text: &str) -> Option<Self> {
        let rest = text.strip_prefix(Self::MARKER)?;
        serde_json::from_str(rest).ok()
    }

    pub fn readable(&self) -> String {
        self.parts
            .iter()
            .map(|part| match part.kind {
                ToolOutputKind::Text => part.text.clone(),
                ToolOutputKind::Image => {
                    format!("[image: {}]", part.path.as_deref().unwrap_or("Tool image"))
                }
                ToolOutputKind::Diff => {
                    format!("{}\n{}", part.path.as_deref().unwrap_or("Changes"), part.text)
                }
            })
            .collect::<Vec<_>>()
            .join("\n")
    }

    pub fn image_encoded(url: &str, label: &str) -> String {
        Self {
            parts: vec![ToolOutputPart::image(url, label)],
        }
        .encoded()
    }

    pub fn content(value: Option<&Value>) -> Option<String> {
        let val = value?;
        if let Some(s) = val.as_str() {
            return Some(s.to_string());
        }
        let arr = val.as_array()?;
        let parts: Vec<ToolOutputPart> = arr.iter().flat_map(Self::block).collect();
        (!parts.is_empty()).then(|| Self { parts }.encoded())
    }

    fn block(block: &Value) -> Vec<ToolOutputPart> {
        match block.get("type").and_then(Value::as_str) {
            Some("text" | "input_text" | "inputText") => block
                .get("text")
                .and_then(Value::as_str)
                .map(|t| vec![ToolOutputPart::text(t)])
                .unwrap_or_default(),
            Some("image" | "input_image" | "inputImage") => {
                let source = block.get("source").unwrap_or(block);
                if let Some(data) = source.get("data").and_then(Value::as_str)
                    && let Some(mime) = source
                        .get("media_type")
                        .or_else(|| source.get("mimeType"))
                        .and_then(Value::as_str)
                {
                    return vec![ToolOutputPart::image(
                        format!("data:{mime};base64,{data}"),
                        "Tool image",
                    )];
                }
                let url = source
                    .get("url")
                    .or_else(|| block.get("imageUrl"))
                    .or_else(|| block.get("image_url"))
                    .and_then(Value::as_str)
                    .or_else(|| {
                        block
                            .get("image_url")
                            .and_then(|u| u.get("url"))
                            .and_then(Value::as_str)
                    })
                    .or_else(|| block.get("uri").and_then(Value::as_str));
                if let Some(url) = url {
                    vec![ToolOutputPart::image(url, "Tool image")]
                } else {
                    vec![ToolOutputPart::text(Self::unsupported(block))]
                }
            }
            Some("resource") => block
                .get("resource")
                .and_then(|r| r.get("text"))
                .and_then(Value::as_str)
                .map(|t| vec![ToolOutputPart::text(t)])
                .unwrap_or_else(|| vec![ToolOutputPart::text(Self::unsupported(block))]),
            Some("resource_link") => {
                let meta = Self::details(block);
                if meta.is_empty() {
                    vec![ToolOutputPart::text(Self::unsupported(block))]
                } else {
                    vec![ToolOutputPart::text(meta.join("\n"))]
                }
            }
            _ => vec![ToolOutputPart::text(Self::unsupported(block))],
        }
    }

    pub fn unsupported(block: &Value) -> String {
        let kind = block.get("type").and_then(Value::as_str).unwrap_or("unknown");
        let resource = block.get("resource").unwrap_or(block);
        let mut lines = vec![format!("Couldn't display tool content ({kind}).")];
        lines.extend(Self::details(resource));
        lines.join("\n")
    }

    fn details(block: &Value) -> Vec<String> {
        let mut seen = HashSet::new();
        let mut out = Vec::new();
        for key in ["title", "name", "mimeType", "uri", "text"] {
            let Some(val) = block.get(key).and_then(Value::as_str) else {
                continue;
            };
            if val.is_empty() {
                continue;
            }
            if key == "uri" && val.to_ascii_lowercase().starts_with("data:") {
                continue;
            }
            if seen.insert(val.to_string()) {
                out.push(val.to_string());
            }
        }
        out
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ToolStep {
    Read,
    Edit,
    Search,
    Execute,
    Fetch,
    Other,
}

impl ToolStep {
    pub fn kind_of(line: &str) -> Self {
        if line.starts_with("$ ") {
            return Self::Execute;
        }
        let first = line.split(' ').next().unwrap_or(line).to_ascii_lowercase();
        match first.as_str() {
            "bash"
            | "run_command"
            | "run_terminal_command"
            | "shell"
            | "exec_command"
            | "bashoutput"
            | "killshell" => Self::Execute,
            "read" | "read_file" | "read_resource" | "view" | "notebookread" => Self::Read,
            "edit" | "edit_file" | "multiedit" | "write" | "notebookedit" | "search_replace"
            | "write_file" | "create_file" => Self::Edit,
            "grep" | "glob" | "ls" | "list_dir" | "list_resources" | "find_by_name" | "toolsearch"
            | "search" | "grep_search" | "file_search" => Self::Search,
            "webfetch" | "web_fetch" | "websearch" | "web_search" | "search_web" | "read_url_content" => {
                Self::Fetch
            }
            _ => {
                if line.to_ascii_lowercase().starts_with("edit files") {
                    Self::Edit
                } else {
                    Self::Other
                }
            }
        }
    }

    pub fn dominant(lines: &[String]) -> Self {
        let mut counts: HashMap<Self, usize> = HashMap::new();
        for line in lines {
            *counts.entry(Self::kind_of(line)).or_default() += 1;
        }
        let mut best = Self::Other;
        let mut best_count = 0usize;
        for kind in [
            Self::Edit,
            Self::Execute,
            Self::Read,
            Self::Search,
            Self::Fetch,
            Self::Other,
        ] {
            let c = counts.get(&kind).copied().unwrap_or(0);
            if c > best_count {
                best = kind;
                best_count = c;
            }
        }
        best
    }

    pub fn summary(lines: &[String]) -> String {
        let mut counts: HashMap<Self, usize> = HashMap::new();
        for line in lines {
            *counts.entry(Self::kind_of(line)).or_default() += 1;
        }
        [
            Self::Read,
            Self::Search,
            Self::Execute,
            Self::Edit,
            Self::Fetch,
            Self::Other,
        ]
        .into_iter()
        .filter_map(|k| counts.get(&k).map(|&c| k.phrase(c)))
        .collect::<Vec<_>>()
        .join(", ")
    }

    fn phrase(self, count: usize) -> String {
        let many = count != 1;
        match self {
            Self::Read => format!("read {count} {}", if many { "files" } else { "file" }),
            Self::Search => format!("{count} {}", if many { "searches" } else { "search" }),
            Self::Execute => format!("ran {count} {}", if many { "commands" } else { "command" }),
            Self::Edit => format!("edited {count} {}", if many { "files" } else { "file" }),
            Self::Fetch => format!("fetched {count} {}", if many { "pages" } else { "page" }),
            Self::Other => format!("used {count} {}", if many { "tools" } else { "tool" }),
        }
    }

    pub fn symbol(self) -> &'static str {
        match self {
            Self::Read => "doc.text",
            Self::Edit => "pencil.line",
            Self::Search => "magnifyingglass",
            Self::Execute => "apple.terminal",
            Self::Fetch => "globe",
            Self::Other => "wrench.and.screwdriver",
        }
    }

    pub fn format_call(name: &str, parameters: Option<&Value>) -> String {
        let Some(input) = parameters.and_then(Value::as_object) else {
            return name.to_string();
        };
        if let Some(server) = input.get("ServerName").and_then(Value::as_str)
            && !server.is_empty()
            && let Some(tool) = input.get("ToolName").and_then(Value::as_str)
            && !tool.is_empty()
        {
            return format!("{name} {server}/{tool}");
        }
        for key in [
            "CommandLine",
            "command",
            "Path",
            "file_path",
            "url",
            "query",
            "pattern",
            "skill",
            "description",
            "Action",
            "Role",
            "TypeName",
            "Recipient",
        ] {
            let Some(raw) = input.get(key).and_then(Value::as_str) else {
                continue;
            };
            let flat = raw.replace('\n', " ");
            let flat = flat.trim();
            if flat.is_empty() {
                continue;
            }
            let clipped = if flat.chars().count() > 160 {
                let prefix: String = flat.chars().take(160).collect();
                format!("{prefix}...")
            } else {
                flat.to_string()
            };
            return format!("{name} {clipped}");
        }
        name.to_string()
    }

    pub fn call_title(raw: &str) -> String {
        match Self::split_json_call(raw) {
            Some((name, val)) => Self::format_call(name, Some(&val)),
            None => raw.to_string(),
        }
    }

    pub fn present_call(raw: &str) -> (String, Option<String>) {
        let Some((name, val)) = Self::split_json_call(raw) else {
            return (raw.to_string(), None);
        };
        let pretty = QuestionRequest::json(&val);
        (
            Self::format_call(name, Some(&val)),
            (!pretty.is_empty()).then_some(pretty),
        )
    }

    fn split_json_call(raw: &str) -> Option<(&str, Value)> {
        if raw.starts_with("$ ") {
            return None;
        }
        let split = raw.find(" {")?;
        let name = &raw[..split];
        if name.is_empty() || name.chars().any(char::is_whitespace) {
            return None;
        }
        let json_part = &raw[split + 1..];
        let val: Value = serde_json::from_str(json_part).ok()?;
        val.is_object().then_some((name, val))
    }
}
