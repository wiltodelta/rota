use std::path::Path;

use regex_lite::Regex;
use serde::{Deserialize, Serialize};

use crate::transcript::{TranscriptItem, TranscriptItemKind};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum PlanStepStatus {
    #[serde(rename = "todo")]
    Pending,
    #[serde(rename = "doing")]
    InProgress,
    #[serde(rename = "done")]
    Completed,
}

impl PlanStepStatus {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Pending => "todo",
            Self::InProgress => "doing",
            Self::Completed => "done",
        }
    }

    pub fn from_raw(raw: Option<&str>) -> Self {
        match raw.map(str::to_ascii_lowercase).as_deref() {
            Some("completed" | "done") => Self::Completed,
            Some("in_progress" | "inprogress" | "doing" | "active") => Self::InProgress,
            _ => Self::Pending,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct PlanStep {
    pub status: PlanStepStatus,
    pub text: String,
}

impl PlanStep {
    pub const PREFIX: &'static str = "[plan] ";
    pub const HEADER: &'static str = "plan";

    pub fn new(status: PlanStepStatus, text: impl Into<String>) -> Self {
        Self {
            status,
            text: text.into(),
        }
    }

    pub fn from_raw(status: Option<&str>, text: impl Into<String>) -> Self {
        Self::new(PlanStepStatus::from_raw(status), text)
    }

    pub fn body(steps: &[Self]) -> String {
        steps
            .iter()
            .map(|s| format!("{} {}", s.status.as_str(), s.text.replace('\n', " ")))
            .collect::<Vec<_>>()
            .join("\n")
    }

    pub fn lines(steps: &[Self]) -> String {
        let mut out = vec![format!("{}{}", Self::PREFIX, Self::HEADER)];
        for line in Self::body(steps).split('\n').filter(|l| !l.is_empty()) {
            out.push(format!("{}{line}", Self::PREFIX));
        }
        out.join("\n")
    }

    pub fn parse(text: &str) -> Vec<Self> {
        text.split('\n')
            .filter_map(|line| {
                let (st, rest) = line.split_once(' ')?;
                let status = match st {
                    "todo" => PlanStepStatus::Pending,
                    "doing" => PlanStepStatus::InProgress,
                    "done" => PlanStepStatus::Completed,
                    _ => return None,
                };
                Some(Self::new(status, rest))
            })
            .collect()
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Outgoing {
    pub text: String,
    pub seen: usize,
}

impl Outgoing {
    pub fn count(text: &str, items: &[TranscriptItem]) -> usize {
        items
            .iter()
            .filter(|i| i.kind == TranscriptItemKind::User && i.text == text)
            .count()
    }

    pub fn delivered(&self, items: &[TranscriptItem]) -> bool {
        Self::count(&self.text, items) > self.seen
    }
}

pub struct TranscriptService;

impl TranscriptService {
    pub fn title(text: &str) -> Option<&'static str> {
        let trimmed = text.trim();
        if trimmed == "[Request interrupted by user for tool use]" {
            return Some("Tool use interrupted");
        }
        if !Self::task_ids(trimmed).is_empty() {
            return Some("Background task notification");
        }
        None
    }

    pub fn waiting(tasks: usize) -> String {
        let noun = if tasks == 1 { "task" } else { "tasks" };
        format!("Waiting for {tasks} background {noun}")
    }

    pub fn task_ids(text: &str) -> Vec<String> {
        let trimmed = text.trim();
        if !trimmed.starts_with("<task-notification>") || !trimmed.ends_with("</task-notification>") {
            return Vec::new();
        }
        let Ok(re) = Regex::new(r"<task-id>([^<]+)</task-id>") else {
            return Vec::new();
        };
        re.captures_iter(trimmed)
            .filter_map(|c| c.get(1).map(|m| m.as_str().trim().to_string()))
            .filter(|s| !s.is_empty())
            .collect()
    }
}

pub struct TranscriptOrder;

impl TranscriptOrder {
    pub fn align_same_step_reasoning(items: &[TranscriptItem]) -> Vec<TranscriptItem> {
        let mut result = items.to_vec();
        let mut index = 0usize;
        while index < result.len() {
            let Some(stem) = Self::antigravity_text_stem(&result[index]) else {
                index += 1;
                continue;
            };
            let Some(match_idx) = Self::matching_thinking_index(&stem, index, &result) else {
                index += 1;
                continue;
            };
            let thinking = result.remove(match_idx);
            result.insert(index, thinking);
            index += 2;
        }
        result
    }

    fn antigravity_text_stem(item: &TranscriptItem) -> Option<String> {
        if item.kind != TranscriptItemKind::Agent || !item.is_complete {
            return None;
        }
        let id = item.native_id.as_deref()?;
        if id.starts_with("antigravity/")
            && let Some(stem) = id.strip_suffix("/text")
        {
            return Some(stem.to_string());
        }
        None
    }

    fn matching_thinking_index(stem: &str, after: usize, items: &[TranscriptItem]) -> Option<usize> {
        let target = format!("{stem}/thinking");
        for (idx, item) in items.iter().enumerate().skip(after + 1) {
            if matches!(item.kind, TranscriptItemKind::User | TranscriptItemKind::Agent) {
                return None;
            }
            if item.kind == TranscriptItemKind::Reasoning
                && item.native_id.as_deref() == Some(target.as_str())
            {
                return Some(idx);
            }
        }
        None
    }
}

/// UI grouping helpers for transcript tool and note rows.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum WorkRow {
    Note(TranscriptItem),
    Tools(Vec<TranscriptItem>),
}

impl WorkRow {
    pub fn id(&self) -> usize {
        match self {
            Self::Note(item) => item.id,
            Self::Tools(calls) => calls.first().map_or(0, |c| c.id),
        }
    }

    pub fn items(&self) -> &[TranscriptItem] {
        match self {
            Self::Note(item) => std::slice::from_ref(item),
            Self::Tools(calls) => calls.as_slice(),
        }
    }

    pub fn is_step_work(&self) -> bool {
        match self {
            Self::Tools(_) => true,
            Self::Note(item) => item.kind == TranscriptItemKind::Reasoning,
        }
    }

    pub fn group(items: &[TranscriptItem]) -> Vec<Self> {
        let mut rows = Vec::new();
        let mut calls = Vec::new();
        for raw in items {
            if raw.is_empty_reasoning() {
                continue;
            }
            let item = raw.presented();
            if item.kind.can_join_tool_group() && (item.kind == TranscriptItemKind::Tool || !calls.is_empty())
            {
                calls.push(item);
                continue;
            }
            if !calls.is_empty() {
                rows.push(Self::Tools(std::mem::take(&mut calls)));
            }
            rows.push(Self::Note(item));
        }
        if !calls.is_empty() {
            rows.push(Self::Tools(calls));
        }
        rows
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ChatRow {
    Single(WorkRow),
    WorkChain(Vec<WorkRow>),
}

impl ChatRow {
    pub fn group(items: &[TranscriptItem]) -> Vec<Self> {
        let aligned = TranscriptOrder::align_same_step_reasoning(items);
        let base = WorkRow::group(&aligned);
        let mut out = Vec::new();
        let mut run = Vec::new();
        for row in base {
            if row.is_step_work() {
                run.push(row);
            } else {
                if run.len() >= 3 {
                    out.push(Self::WorkChain(std::mem::take(&mut run)));
                } else {
                    out.extend(run.drain(..).map(Self::Single));
                }
                out.push(Self::Single(row));
            }
        }
        if run.len() >= 3 {
            out.push(Self::WorkChain(run));
        } else {
            out.extend(run.into_iter().map(Self::Single));
        }
        out
    }
}

pub struct FileChangeTitle;

impl FileChangeTitle {
    pub fn title(line: &str, live: bool) -> Option<String> {
        let (tool, path) = line.split_once(' ')?;
        if !path.starts_with('/') && !path.starts_with('~') {
            return None;
        }
        let name = Path::new(path).file_name()?.to_str()?;
        match tool {
            "Edit" | "MultiEdit" | "search_replace" => {
                Some(format!("{}{name}", if live { "Editing " } else { "Edited " }))
            }
            "Write" | "write_file" | "create_file" => {
                Some(format!("{}{name}", if live { "Writing " } else { "Wrote " }))
            }
            _ => None,
        }
    }
}
