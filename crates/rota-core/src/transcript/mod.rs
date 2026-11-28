pub mod journal;
pub mod markdown;
pub mod preview;
pub mod reader;
pub mod run_journal;
pub mod run_journal_events;
pub mod table;
pub mod tool_output;
pub mod turn_work;

use regex_lite::Regex;
use serde::{Deserialize, Serialize};

pub use journal::{JournalError, JournalPage, TranscriptJournal, TranscriptRecord, TranscriptSnapshot};
pub use markdown::{
    InlineSpan, MarkdownAlert, MarkdownBlock, MarkdownImageReference, parse_inline_spans,
    strip_inline_markdown,
};
pub use preview::SessionPreview;
pub use reader::{TranscriptReader, TranscriptSessionReader};
pub use run_journal::RunJournal;
pub use run_journal_events::shell_quote;
pub use table::{ColumnAlignment, MarkdownTable};
pub use tool_output::{ToolOutput, ToolOutputKind, ToolOutputPart, ToolStep};
pub use turn_work::{
    ChatRow, FileChangeTitle, Outgoing, PlanStep, PlanStepStatus, TranscriptOrder, TranscriptService, WorkRow,
};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum TranscriptItemKind {
    User,
    Agent,
    Reasoning,
    Tool,
    Status,
    Error,
    Output,
    Plan,
}

impl TranscriptItemKind {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::User => "user",
            Self::Agent => "agent",
            Self::Reasoning => "reasoning",
            Self::Tool => "tool",
            Self::Status => "status",
            Self::Error => "error",
            Self::Output => "output",
            Self::Plan => "plan",
        }
    }

    pub fn parse(raw: &str) -> Option<Self> {
        match raw {
            "user" => Some(Self::User),
            "agent" => Some(Self::Agent),
            "reasoning" => Some(Self::Reasoning),
            "tool" => Some(Self::Tool),
            "status" => Some(Self::Status),
            "error" => Some(Self::Error),
            "output" => Some(Self::Output),
            "plan" => Some(Self::Plan),
            _ => None,
        }
    }

    pub fn can_join_tool_group(self) -> bool {
        matches!(self, Self::Tool | Self::Output)
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TranscriptItem {
    pub id: usize,
    pub kind: TranscriptItemKind,
    pub text: String,
    #[serde(default = "default_complete")]
    pub is_complete: bool,
    #[serde(default, rename = "nativeID", skip_serializing_if = "Option::is_none")]
    pub native_id: Option<String>,
}

fn default_complete() -> bool {
    true
}

impl TranscriptItem {
    pub fn new(id: usize, kind: TranscriptItemKind, text: impl Into<String>) -> Self {
        Self {
            id,
            kind,
            text: text.into(),
            is_complete: true,
            native_id: None,
        }
    }

    pub fn is_empty_reasoning(&self) -> bool {
        self.kind == TranscriptItemKind::Reasoning && self.text.trim().is_empty()
    }

    pub fn presented(&self) -> Self {
        let mut item = self.clone();
        if item.kind == TranscriptItemKind::User && TranscriptService::title(&item.text).is_some() {
            item.kind = TranscriptItemKind::Status;
        }
        if item.kind == TranscriptItemKind::Status
            && item.text.to_ascii_lowercase().starts_with("succeeded after ")
        {
            item.text = format!("Completed{}", &item.text["Succeeded".len()..]);
        }
        item
    }
}

pub struct Transcript;

impl Transcript {
    pub const USER_PREFIX: &'static str = "[you] ";

    pub fn user_lines(text: &str) -> String {
        text.split('\n')
            .map(|line| format!("{}{line}", Self::USER_PREFIX))
            .collect::<Vec<_>>()
            .join("\n")
    }

    pub fn parse(log: &str, shell: bool) -> Vec<TranscriptItem> {
        let mut items: Vec<TranscriptItem> = Vec::new();
        let append = |items: &mut Vec<TranscriptItem>, kind: TranscriptItemKind, text: String| {
            if kind == TranscriptItemKind::Plan && text == PlanStep::HEADER {
                items.push(TranscriptItem::new(
                    items.len(),
                    TranscriptItemKind::Plan,
                    String::new(),
                ));
                return;
            }
            if let Some(last) = items.last_mut()
                && last.kind == kind
                && matches!(
                    kind,
                    TranscriptItemKind::Agent
                        | TranscriptItemKind::User
                        | TranscriptItemKind::Output
                        | TranscriptItemKind::Plan
                )
            {
                if last.kind == TranscriptItemKind::Plan && last.text.is_empty() {
                    last.text = text;
                } else {
                    last.text.push('\n');
                    last.text.push_str(&text);
                }
            } else {
                items.push(TranscriptItem::new(items.len(), kind, text));
            }
        };

        let mut in_fence = false;
        for line in log.split('\n') {
            let trimmed_ws = line.trim_matches([' ', '\t', '\r']);
            let fence = !shell && trimmed_ws.starts_with("```");
            if fence {
                in_fence = !in_fence;
            }
            if fence || in_fence {
                append(&mut items, TranscriptItemKind::Agent, line.to_string());
                continue;
            }
            if trimmed_ws.is_empty() {
                if let Some(last) = items.last()
                    && matches!(last.kind, TranscriptItemKind::Agent | TranscriptItemKind::Output)
                {
                    items.push(TranscriptItem::new(
                        items.len(),
                        TranscriptItemKind::Status,
                        String::new(),
                    ));
                }
            } else if let Some((kind, body)) = Self::classify(line, shell) {
                append(&mut items, kind, body);
            }
        }
        items
            .into_iter()
            .filter(|i| !(i.kind == TranscriptItemKind::Status && i.text.is_empty()))
            .enumerate()
            .map(|(idx, mut item)| {
                item.id = idx;
                item.presented()
            })
            .collect()
    }

    pub fn classify(line: &str, shell: bool) -> Option<(TranscriptItemKind, String)> {
        if let Some(rest) = line.strip_prefix(Self::USER_PREFIX) {
            return Some((TranscriptItemKind::User, rest.to_string()));
        }
        if let Some(rest) = line.strip_prefix("-> ") {
            return Some((TranscriptItemKind::Tool, rest.to_string()));
        }
        if line.starts_with("[rota: ") || line.starts_with("[result: ") {
            let after_space = line.split_once(' ').map(|(_, r)| r).unwrap_or(line);
            let body = after_space.strip_suffix(']').unwrap_or(after_space);
            return Some((TranscriptItemKind::Status, Self::readable_durations(body)));
        }
        if let Some(rest) = line.strip_prefix("[error] ") {
            return Some((TranscriptItemKind::Error, rest.to_string()));
        }
        if let Some(rest) = line.strip_prefix("[reasoning] ") {
            return Some((TranscriptItemKind::Reasoning, rest.to_string()));
        }
        if let Some(rest) = line.strip_prefix("[output] ") {
            return Some((TranscriptItemKind::Output, rest.to_string()));
        }
        if let Some(rest) = line.strip_prefix(PlanStep::PREFIX) {
            return Some((TranscriptItemKind::Plan, rest.to_string()));
        }
        if Self::is_header(line) {
            return None;
        }
        Some((
            if shell {
                TranscriptItemKind::Output
            } else {
                TranscriptItemKind::Agent
            },
            line.to_string(),
        ))
    }

    pub fn readable_durations(text: &str) -> String {
        let Ok(re) = Regex::new(r"\b(\d+) s\b") else {
            return text.to_string();
        };
        let Some(caps) = re.captures(text) else {
            return text.to_string();
        };
        let Some(m) = caps.get(0) else {
            return text.to_string();
        };
        let Ok(secs) = caps[1].parse::<u64>() else {
            return text.to_string();
        };
        let mut out = String::with_capacity(text.len());
        out.push_str(&text[..m.start()]);
        out.push_str(&Self::readable_seconds(secs));
        out.push_str(&text[m.end()..]);
        out
    }

    pub fn readable_seconds(seconds: u64) -> String {
        if seconds < 60 {
            format!("{seconds}s")
        } else if seconds < 3600 {
            format!("{}m {}s", seconds / 60, seconds % 60)
        } else {
            format!("{}h {}m", seconds / 3600, (seconds / 60) % 60)
        }
    }

    fn is_header(line: &str) -> bool {
        ["[codex thread ", "[grok session ", "[session started"]
            .iter()
            .any(|h| line.starts_with(h))
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct TranscriptTurn {
    pub prompt: Option<TranscriptItem>,
    pub work: Vec<TranscriptItem>,
    pub answer: Vec<TranscriptItem>,
    pub notes: Vec<TranscriptItem>,
    pub plan: Option<TranscriptItem>,
}

impl TranscriptTurn {
    pub fn answer_messages(&self) -> Vec<TranscriptItem> {
        let mut out: Vec<TranscriptItem> = Vec::new();
        for item in &self.answer {
            if item.kind != TranscriptItemKind::Output
                && let Some(last) = out.last_mut()
                && last.kind != TranscriptItemKind::Output
            {
                last.text.push_str("\n\n");
                last.text.push_str(&item.text);
            } else {
                out.push(item.clone());
            }
        }
        out
    }

    pub fn tool_count(&self) -> usize {
        self.work
            .iter()
            .filter(|i| i.kind == TranscriptItemKind::Tool)
            .count()
    }

    pub fn group(items: &[TranscriptItem]) -> Vec<Self> {
        let mut turns = Vec::new();
        let mut current = Self::default();
        let mut body: Vec<TranscriptItem> = Vec::new();

        let close = |turns: &mut Vec<Self>, current: &mut Self, body: &mut Vec<TranscriptItem>| {
            let last_tool = body.iter().rposition(|i| i.kind == TranscriptItemKind::Tool);
            for (idx, item) in body.drain(..).enumerate() {
                match item.kind {
                    TranscriptItemKind::Status | TranscriptItemKind::Error => {
                        current.notes.push(item);
                    }
                    TranscriptItemKind::Plan => current.plan = Some(item),
                    TranscriptItemKind::Reasoning => current.work.push(item),
                    TranscriptItemKind::User => {}
                    _ => {
                        if last_tool.is_some_and(|lt| idx <= lt) {
                            current.work.push(item);
                        } else {
                            current.answer.push(item);
                        }
                    }
                }
            }
            if current.prompt.is_some()
                || !current.work.is_empty()
                || !current.answer.is_empty()
                || !current.notes.is_empty()
                || current.plan.is_some()
            {
                turns.push(std::mem::take(current));
            }
        };

        for raw in items {
            if raw.is_empty_reasoning() {
                continue;
            }
            let item = raw.presented();
            if item.kind == TranscriptItemKind::User {
                close(&mut turns, &mut current, &mut body);
                current.prompt = Some(item);
            } else {
                body.push(item);
            }
        }
        close(&mut turns, &mut current, &mut body);
        turns
    }
}
