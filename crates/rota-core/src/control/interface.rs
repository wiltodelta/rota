use std::collections::HashMap;
use std::fmt;

use serde_json::{Map, Value, json};

/// A failed control request with a user-facing sentence.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ControlError {
    pub message: String,
}

impl ControlError {
    pub const NOT_RUNNING_MESSAGE: &'static str = "Rota is not running.";

    pub fn new(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
        }
    }

    pub fn not_running() -> Self {
        Self::new(Self::NOT_RUNNING_MESSAGE)
    }

    pub fn is_not_running(&self) -> bool {
        self.message == Self::NOT_RUNNING_MESSAGE
    }
}

impl fmt::Display for ControlError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.message)
    }
}

impl std::error::Error for ControlError {}

/// Every socket operation supported by `ControlServer`.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ControlMethod {
    RoutinesList,
    RoutinesCalendar,
    RoutinesGet,
    RoutinesCreate,
    RoutinesUpdate,
    RoutinesSetEnabled,
    RoutinesRun,
    RoutinesStop,
    RoutinesDelete,
    SessionsList,
    SessionsRead,
    Notify,
    SessionsMessage,
    SessionsGet,
    SessionsDelete,
    SessionsDismiss,
    SessionsMarkRead,
    SessionsMarkUnread,
    SessionsQuestions,
    SessionsAnswer,
    QuestionsCreate,
    QuestionsPoll,
}

impl ControlMethod {
    pub const ALL: [Self; 22] = [
        Self::RoutinesList,
        Self::RoutinesCalendar,
        Self::RoutinesGet,
        Self::RoutinesCreate,
        Self::RoutinesUpdate,
        Self::RoutinesSetEnabled,
        Self::RoutinesRun,
        Self::RoutinesStop,
        Self::RoutinesDelete,
        Self::SessionsList,
        Self::SessionsRead,
        Self::Notify,
        Self::SessionsMessage,
        Self::SessionsGet,
        Self::SessionsDelete,
        Self::SessionsDismiss,
        Self::SessionsMarkRead,
        Self::SessionsMarkUnread,
        Self::SessionsQuestions,
        Self::SessionsAnswer,
        Self::QuestionsCreate,
        Self::QuestionsPoll,
    ];

    pub fn as_str(self) -> &'static str {
        match self {
            Self::RoutinesList => "routines.list",
            Self::RoutinesCalendar => "routines.calendar",
            Self::RoutinesGet => "routines.get",
            Self::RoutinesCreate => "routines.create",
            Self::RoutinesUpdate => "routines.update",
            Self::RoutinesSetEnabled => "routines.setEnabled",
            Self::RoutinesRun => "routines.run",
            Self::RoutinesStop => "routines.stop",
            Self::RoutinesDelete => "routines.delete",
            Self::SessionsList => "sessions.list",
            Self::SessionsRead => "sessions.read",
            Self::Notify => "notify",
            Self::SessionsMessage => "sessions.message",
            Self::SessionsGet => "sessions.get",
            Self::SessionsDelete => "sessions.delete",
            Self::SessionsDismiss => "sessions.dismiss",
            Self::SessionsMarkRead => "sessions.markRead",
            Self::SessionsMarkUnread => "sessions.markUnread",
            Self::SessionsQuestions => "sessions.questions",
            Self::SessionsAnswer => "sessions.answer",
            Self::QuestionsCreate => "questions.create",
            Self::QuestionsPoll => "questions.poll",
        }
    }

    pub fn parse(raw: &str) -> Option<Self> {
        Self::ALL.into_iter().find(|m| m.as_str() == raw)
    }

    pub fn is_public(self) -> bool {
        !matches!(self, Self::QuestionsCreate | Self::QuestionsPoll)
    }
}

#[derive(Debug, Clone)]
pub struct ControlTool {
    pub name: &'static str,
    pub method: ControlMethod,
    pub command: &'static str,
    pub description: String,
    pub properties: Map<String, Value>,
    pub required: Vec<&'static str>,
}

impl ControlTool {
    pub fn mcp_schema(&self) -> Value {
        json!({
            "name": self.name,
            "description": self.description,
            "inputSchema": {
                "type": "object",
                "properties": self.properties,
                "required": self.required,
            }
        })
    }
}

/// Shared catalog for the CLI and MCP stdio server.
pub struct ControlInterface;

impl ControlInterface {
    pub fn session_arguments(
        mut params: Map<String, Value>,
        method: ControlMethod,
        environment: &HashMap<String, String>,
    ) -> Map<String, Value> {
        if !params.contains_key("session")
            && let Some(session) = environment.get("ROTA_SESSION")
            && method != ControlMethod::SessionsDelete
        {
            let should_bind = if method == ControlMethod::Notify {
                !params.contains_key("routine")
            } else {
                method.as_str().starts_with("sessions.")
                    && params.get("id").and_then(Value::as_str)
                        == environment.get("ROTA_ROUTINE").map(String::as_str)
            };
            if should_bind {
                params.insert("session".to_string(), Value::String(session.clone()));
            }
        }
        params
    }

    pub(crate) fn prop(kind: Value, description: &str) -> Value {
        json!({"type": kind, "description": description})
    }

    pub(crate) fn map_of(pairs: &[(&str, Value)]) -> Map<String, Value> {
        pairs.iter().map(|(k, v)| ((*k).to_string(), v.clone())).collect()
    }
}
