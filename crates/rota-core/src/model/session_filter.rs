use std::collections::HashSet;
use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::Path;

use rota_platform::PreferencesStore;
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::model::{RunOutcome, RunRecord, TerminalState};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ConfigurationMark {
    pub from_item: usize,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model_title: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub effort: Option<String>,
}

impl ConfigurationMark {
    pub fn labels_like(&self, other: &Self) -> bool {
        self.model == other.model && self.model_title == other.model_title && self.effort == other.effort
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SessionConfiguration {
    pub model: Option<String>,
    pub effort: Option<String>,
    pub model_title: Option<String>,
    pub from_item: Option<usize>,
}

impl SessionConfiguration {
    pub fn new(
        model: Option<String>,
        effort: Option<String>,
        model_title: Option<String>,
        from_item: Option<usize>,
    ) -> Self {
        Self {
            model: Self::clean(model),
            effort: Self::clean(effort),
            model_title: Self::clean(model_title),
            from_item,
        }
    }

    fn clean(raw: Option<String>) -> Option<String> {
        let trimmed = raw?.trim().to_string();
        if trimmed.is_empty() || trimmed == "unknown model" {
            None
        } else {
            Some(trimmed)
        }
    }

    pub fn acp(value: &Value) -> Self {
        let options = value
            .get("configOptions")
            .and_then(Value::as_array)
            .cloned()
            .unwrap_or_default();
        let flat = value.get("config").and_then(Value::as_object);
        let find_opt = |id: &str| {
            options
                .iter()
                .find(|opt| opt.get("id").and_then(Value::as_str) == Some(id))
                .and_then(|opt| opt.get("currentValue").and_then(Value::as_str))
                .map(ToOwned::to_owned)
        };
        let model = find_opt("model").or_else(|| {
            flat.and_then(|m| m.get("model"))
                .and_then(Value::as_str)
                .map(ToOwned::to_owned)
        });
        let effort = find_opt("reasoning_effort").or_else(|| {
            flat.and_then(|m| m.get("reasoning_effort"))
                .and_then(Value::as_str)
                .map(ToOwned::to_owned)
        });
        Self::new(model, effort, None, None)
    }

    pub fn recorded_model(log: &Path) -> Option<String> {
        let mut file = File::open(log).ok()?;
        let size = file.seek(SeekFrom::End(0)).ok()?;
        let offset = size.saturating_sub(262_144);
        file.seek(SeekFrom::Start(offset)).ok()?;
        let mut buf = Vec::new();
        file.read_to_end(&mut buf).ok()?;
        let text = String::from_utf8_lossy(&buf);
        for line in text.split('\n').rev() {
            if !line.ends_with(']') {
                continue;
            }
            if !(line.starts_with("[session started, ")
                || line.starts_with("[codex thread ")
                || line.starts_with("[grok session "))
            {
                continue;
            }
            if let Some(comma) = line.find(',') {
                return Self::clean(Some(line[comma + 1..line.len() - 1].to_string()));
            }
        }
        None
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SessionFilter {
    All,
    Running,
    NeedsAttention,
    Unread,
    Failed,
    Completed,
}

impl SessionFilter {
    pub const ALL_CASES: [Self; 6] = [
        Self::All,
        Self::Running,
        Self::NeedsAttention,
        Self::Unread,
        Self::Failed,
        Self::Completed,
    ];

    pub fn as_str(self) -> &'static str {
        match self {
            Self::All => "all",
            Self::Running => "running",
            Self::NeedsAttention => "needsAttention",
            Self::Unread => "unread",
            Self::Failed => "failed",
            Self::Completed => "completed",
        }
    }

    pub fn parse(raw: &str) -> Option<Self> {
        Self::ALL_CASES.into_iter().find(|f| f.as_str() == raw)
    }

    pub fn title(self) -> &'static str {
        match self {
            Self::All => "All Sessions",
            Self::Running => "Running",
            Self::NeedsAttention => "Needs Attention",
            Self::Unread => "Unread",
            Self::Failed => "Failed",
            Self::Completed => "Completed",
        }
    }

    pub fn includes(self, record: &RunRecord) -> bool {
        if record.is_skip() {
            return false;
        }
        let needs_attn = record.needs_attention()
            || (record.outcome == RunOutcome::Running
                && record.terminal_state == Some(TerminalState::Waiting));
        match self {
            Self::All => true,
            Self::Running => record.outcome == RunOutcome::Running,
            Self::NeedsAttention => needs_attn,
            Self::Unread => record.is_unread(),
            Self::Failed => record.outcome.is_failure(),
            Self::Completed => record.outcome == RunOutcome::Succeeded && !needs_attn,
        }
    }

    pub fn moved(self, offset: isize) -> Self {
        let idx = Self::ALL_CASES.iter().position(|&c| c == self).unwrap_or(0) as isize;
        let clamped = (idx + offset).clamp(0, (Self::ALL_CASES.len() - 1) as isize) as usize;
        Self::ALL_CASES[clamped]
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct SessionFilters {
    categories: HashSet<SessionFilter>,
}

impl SessionFilters {
    pub const DEFAULTS_KEY: &'static str = "sessionFilterCategories";

    pub fn load(prefs: &dyn PreferencesStore) -> Self {
        let values = prefs.get_string_list(Self::DEFAULTS_KEY).unwrap_or_default();
        let categories = values
            .iter()
            .filter_map(|v| SessionFilter::parse(v))
            .filter(|&f| f != SessionFilter::All)
            .collect();
        Self { categories }
    }

    pub fn persist(&self, prefs: &dyn PreferencesStore) {
        let list: Vec<String> = self
            .selected()
            .into_iter()
            .map(|f| f.as_str().to_string())
            .collect();
        prefs.set_string_list(Self::DEFAULTS_KEY, &list);
    }

    pub fn selected(&self) -> Vec<SessionFilter> {
        SessionFilter::ALL_CASES
            .into_iter()
            .filter(|f| self.categories.contains(f))
            .collect()
    }

    pub fn title(&self) -> String {
        let sel = self.selected();
        if sel.is_empty() {
            SessionFilter::All.title().to_string()
        } else {
            sel.into_iter()
                .map(SessionFilter::title)
                .collect::<Vec<_>>()
                .join(", ")
        }
    }

    pub fn contains(&self, filter: SessionFilter) -> bool {
        if filter == SessionFilter::All {
            self.categories.is_empty()
        } else {
            self.categories.contains(&filter)
        }
    }

    pub fn toggling(&self, filter: SessionFilter) -> Self {
        if filter == SessionFilter::All {
            return Self::default();
        }
        let mut next = self.clone();
        if !next.categories.insert(filter) {
            next.categories.remove(&filter);
        }
        next
    }

    pub fn includes(&self, record: &RunRecord) -> bool {
        !record.is_skip()
            && (self.categories.is_empty() || self.categories.iter().any(|f| f.includes(record)))
    }
}
