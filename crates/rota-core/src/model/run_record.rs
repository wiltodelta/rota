use jiff::Timestamp;
use regex_lite::Regex;
use serde::{Deserialize, Deserializer, Serialize, Serializer};
use serde_json::{Value, json};
use uuid::Uuid;

use crate::model::serde_ext::{iso_timestamp, opt_iso_timestamp, opt_swift_uuid, swift_uuid, uppercase_uuid};
use crate::model::{AgentQuestion, ConfigurationMark, Harness, LaunchMode};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum RunTrigger {
    Scheduled,
    CatchUp,
    Manual,
}

impl RunTrigger {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Scheduled => "scheduled",
            Self::CatchUp => "catchUp",
            Self::Manual => "manual",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RunOutcome {
    Running,
    Succeeded,
    Failed { exit_code: i32 },
    TimedOut,
    Cancelled,
    Interrupted,
    LaunchFailed(String),
    Skipped(String),
}

impl RunOutcome {
    pub fn title(&self) -> String {
        match self {
            Self::Running => "Running".to_string(),
            Self::Succeeded => "Completed".to_string(),
            Self::Failed { exit_code } => format!("Failed (exit {exit_code})"),
            Self::TimedOut => "Timed out".to_string(),
            Self::Cancelled => "Stopped".to_string(),
            Self::Interrupted => "Interrupted".to_string(),
            Self::LaunchFailed(reason) => format!("Could not start: {reason}"),
            Self::Skipped(reason) => format!("Skipped: {reason}"),
        }
    }

    pub fn is_failure(&self) -> bool {
        matches!(
            self,
            Self::Failed { .. }
                | Self::TimedOut
                | Self::Interrupted
                | Self::LaunchFailed(_)
                | Self::Skipped(_)
        )
    }
}

impl Serialize for RunOutcome {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        let value = match self {
            Self::Running => json!({"running": {}}),
            Self::Succeeded => json!({"succeeded": {}}),
            Self::Failed { exit_code } => json!({"failed": {"exitCode": exit_code}}),
            Self::TimedOut => json!({"timedOut": {}}),
            Self::Cancelled => json!({"cancelled": {}}),
            Self::Interrupted => json!({"interrupted": {}}),
            Self::LaunchFailed(msg) => json!({"launchFailed": {"_0": msg}}),
            Self::Skipped(msg) => json!({"skipped": {"_0": msg}}),
        };
        value.serialize(serializer)
    }
}

impl<'de> Deserialize<'de> for RunOutcome {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let val = Value::deserialize(deserializer)?;
        let obj = val
            .as_object()
            .ok_or_else(|| serde::de::Error::custom("Expected RunOutcome object"))?;
        if obj.contains_key("running") {
            Ok(Self::Running)
        } else if obj.contains_key("succeeded") {
            Ok(Self::Succeeded)
        } else if let Some(failed) = obj.get("failed") {
            let code = failed
                .get("exitCode")
                .and_then(Value::as_i64)
                .ok_or_else(|| serde::de::Error::custom("Missing failed.exitCode"))?;
            Ok(Self::Failed {
                exit_code: code as i32,
            })
        } else if obj.contains_key("timedOut") {
            Ok(Self::TimedOut)
        } else if obj.contains_key("cancelled") {
            Ok(Self::Cancelled)
        } else if obj.contains_key("interrupted") {
            Ok(Self::Interrupted)
        } else if let Some(inner) = obj.get("launchFailed") {
            let msg = inner
                .get("_0")
                .and_then(Value::as_str)
                .ok_or_else(|| serde::de::Error::custom("Missing launchFailed._0"))?;
            Ok(Self::LaunchFailed(msg.to_string()))
        } else if let Some(inner) = obj.get("skipped") {
            let msg = inner
                .get("_0")
                .and_then(Value::as_str)
                .ok_or_else(|| serde::de::Error::custom("Missing skipped._0"))?;
            Ok(Self::Skipped(msg.to_string()))
        } else {
            Err(serde::de::Error::custom("Unknown RunOutcome variant"))
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum TerminalState {
    Waiting,
    Working,
}

impl TerminalState {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::Waiting => "waiting",
            Self::Working => "working",
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RunRecord {
    #[serde(with = "swift_uuid")]
    pub id: Uuid,
    #[serde(rename = "routineID", alias = "routineId")]
    pub routine_id: String,
    pub trigger: RunTrigger,
    pub harness: Harness,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub launch_mode: Option<LaunchMode>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub executable_path: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cli_version: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub server_version: Option<String>,
    #[serde(
        default,
        rename = "executionID",
        alias = "executionId",
        skip_serializing_if = "Option::is_none",
        with = "opt_swift_uuid"
    )]
    pub execution_id: Option<Uuid>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub needs_reconciliation: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub model: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub effort: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reported_model: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reported_model_title: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reported_effort: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub configurations: Option<Vec<ConfigurationMark>>,
    #[serde(with = "iso_timestamp")]
    pub started_at: Timestamp,
    #[serde(default, skip_serializing_if = "Option::is_none", with = "opt_iso_timestamp")]
    pub ended_at: Option<Timestamp>,
    #[serde(default, skip_serializing_if = "Option::is_none", with = "opt_iso_timestamp")]
    pub updated_at: Option<Timestamp>,
    pub outcome: RunOutcome,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub log_path: Option<String>,
    #[serde(
        default,
        rename = "sessionID",
        alias = "sessionId",
        skip_serializing_if = "Option::is_none"
    )]
    pub session_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub original_request: Option<String>,
    #[serde(
        default,
        rename = "discussedSessionID",
        alias = "discussedSessionId",
        skip_serializing_if = "Option::is_none",
        with = "opt_swift_uuid"
    )]
    pub discussed_session_id: Option<Uuid>,
    #[serde(default, skip_serializing_if = "Option::is_none", with = "opt_iso_timestamp")]
    pub read_at: Option<Timestamp>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub attention: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub questions: Option<Vec<AgentQuestion>>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resumes: Option<usize>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub terminal_state: Option<TerminalState>,
}

impl RunRecord {
    pub fn new(
        routine_id: impl Into<String>,
        trigger: RunTrigger,
        harness: Harness,
        started_at: Timestamp,
        outcome: RunOutcome,
    ) -> Self {
        Self {
            id: Uuid::new_v4(),
            routine_id: routine_id.into(),
            trigger,
            harness,
            launch_mode: None,
            executable_path: None,
            cli_version: None,
            server_version: None,
            execution_id: None,
            needs_reconciliation: None,
            model: None,
            effort: None,
            reported_model: None,
            reported_model_title: None,
            reported_effort: None,
            configurations: None,
            started_at,
            ended_at: None,
            updated_at: None,
            outcome,
            log_path: None,
            session_id: None,
            original_request: None,
            discussed_session_id: None,
            read_at: None,
            attention: None,
            questions: None,
            resumes: None,
            terminal_state: None,
        }
    }

    pub fn last_activity_at(&self) -> Timestamp {
        let updated = self.updated_at.unwrap_or(self.started_at);
        let ended = self.ended_at.unwrap_or(self.started_at);
        updated.max(ended)
    }

    pub fn is_more_recently_active_than(&self, other: &Self) -> bool {
        let lhs = self.last_activity_at();
        let rhs = other.last_activity_at();
        if lhs != rhs {
            return lhs > rhs;
        }
        if self.started_at != other.started_at {
            return self.started_at > other.started_at;
        }
        uppercase_uuid(self.id) > uppercase_uuid(other.id)
    }

    pub fn has_blocking_question(&self) -> bool {
        self.questions
            .as_ref()
            .is_some_and(|qs| qs.iter().any(|q| q.reply_via_message != Some(true)))
    }

    pub fn next_question(&self) -> Option<&AgentQuestion> {
        let qs = self.questions.as_ref()?;
        qs.iter()
            .find(|q| q.reply_via_message != Some(true))
            .or_else(|| qs.first())
    }

    pub fn awaits_reply(&self) -> bool {
        self.outcome == RunOutcome::Succeeded && self.questions.as_ref().is_some_and(|qs| !qs.is_empty())
    }

    pub fn needs_attention(&self) -> bool {
        self.attention.is_some() || self.questions.as_ref().is_some_and(|qs| !qs.is_empty())
    }

    pub fn is_skip(&self) -> bool {
        matches!(self.outcome, RunOutcome::Skipped(_))
    }

    pub fn is_prominent(&self) -> bool {
        self.outcome == RunOutcome::Running
            || self.needs_attention()
            || (self.outcome.is_failure() && !self.is_skip())
    }

    pub fn status_title(&self) -> String {
        if self.awaits_reply() {
            return "Needs your reply".to_string();
        }
        if self.outcome == RunOutcome::Running
            && let Some(state) = self.terminal_state
        {
            return match state {
                TerminalState::Working => "Working in Terminal".to_string(),
                TerminalState::Waiting => "Waiting in Terminal".to_string(),
            };
        }
        self.outcome.title()
    }

    pub fn compact_status_title(&self, can_message: bool) -> String {
        if self.questions.as_ref().is_some_and(|qs| !qs.is_empty()) {
            return "Needs your reply".to_string();
        }
        if self.attention.is_some() {
            return if can_message {
                "Needs your reply".to_string()
            } else {
                "Needs your attention".to_string()
            };
        }
        if matches!(self.outcome, RunOutcome::LaunchFailed(_)) {
            return "Couldn't start".to_string();
        }
        if matches!(self.outcome, RunOutcome::Skipped(_)) {
            return "Skipped".to_string();
        }
        self.status_title()
    }

    pub fn is_finished_session(&self) -> bool {
        self.outcome != RunOutcome::Running && !self.is_skip() && self.ended_at.is_some()
    }

    pub fn is_unread(&self) -> bool {
        let Some(ended_at) = self.ended_at else {
            return false;
        };
        if !self.is_finished_session() {
            return false;
        }
        self.read_at.is_none_or(|read| read < ended_at)
    }

    pub fn can_mark_unread(&self) -> bool {
        self.is_finished_session() && !self.is_unread()
    }

    pub fn reported_mark(&self, from_start: usize) -> ConfigurationMark {
        ConfigurationMark {
            from_item: from_start,
            model: self.reported_model.clone().or_else(|| self.model.clone()),
            model_title: self.reported_model_title.clone(),
            effort: self.reported_effort.clone().or_else(|| self.effort.clone()),
        }
    }

    pub fn configuration_at(&self, item: usize) -> Option<&ConfigurationMark> {
        self.configurations
            .as_ref()?
            .iter()
            .rfind(|m| m.from_item <= item)
    }

    pub fn compatibility_notice(&self) -> Option<String> {
        let cli = Self::semantic_version(self.cli_version.as_deref()?)?;
        let srv = Self::semantic_version(self.server_version.as_deref()?)?;
        if cli == srv {
            return None;
        }
        Some(
            "The selected CLI and running agent service use different versions. \
Restart the agent service after its other sessions finish."
                .to_string(),
        )
    }

    fn semantic_version(text: &str) -> Option<String> {
        let re = Regex::new(r"\d+\.\d+\.\d+(?:-[A-Za-z0-9.-]+)?").ok()?;
        re.find(text).map(|m| m.as_str().to_string())
    }
}
