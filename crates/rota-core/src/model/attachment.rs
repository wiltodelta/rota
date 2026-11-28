use std::path::PathBuf;

use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::model::serde_ext::swift_uuid;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct ChatAttachment {
    pub name: String,
    pub path: String,
}

impl ChatAttachment {
    pub fn new(name: impl Into<String>, path: impl Into<String>) -> Self {
        Self {
            name: name.into(),
            path: path.into(),
        }
    }

    pub fn path_buf(&self) -> PathBuf {
        PathBuf::from(&self.path)
    }
}

/// A message remains text on every harness; Rota renders its versioned file manifest as chips.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ChatMessage {
    pub text: String,
    pub attachments: Vec<ChatAttachment>,
}

impl ChatMessage {
    pub const MARKER: &'static str = "\n\n[Rota attachments v1]\n";

    pub fn new(text: impl Into<String>, attachments: Vec<ChatAttachment>) -> Self {
        Self {
            text: text.into(),
            attachments,
        }
    }

    pub fn encoded(&self) -> Result<String, serde_json::Error> {
        if self.attachments.is_empty() {
            return Ok(self.text.clone());
        }
        let json = serde_json::to_string(&self.attachments)?;
        Ok(format!("{}{}{}", self.text, Self::MARKER, json))
    }

    pub fn decode(message: &str) -> Self {
        let Some(pos) = message.rfind(Self::MARKER) else {
            return Self::new(message, Vec::new());
        };
        let manifest = &message[pos + Self::MARKER.len()..];
        let Ok(files) = serde_json::from_str::<Vec<ChatAttachment>>(manifest) else {
            return Self::new(message, Vec::new());
        };
        if files.is_empty()
            || !files
                .iter()
                .all(|f| f.path.starts_with('/') && !f.name.is_empty())
        {
            return Self::new(message, Vec::new());
        }
        Self::new(&message[..pos], files)
    }
}

/// One-click reply preset shared with Settings > Chat.
#[derive(Debug, Clone, PartialEq, Eq, Hash, Serialize, Deserialize)]
pub struct QuickReply {
    #[serde(with = "swift_uuid")]
    pub id: Uuid,
    pub title: String,
    pub message: String,
}

impl QuickReply {
    pub fn new(title: impl Into<String>, message: impl Into<String>) -> Self {
        Self {
            id: Uuid::new_v4(),
            title: title.into(),
            message: message.into(),
        }
    }

    pub fn defaults() -> Vec<Self> {
        vec![
            Self {
                id: Uuid::parse_str("6F1C2A3B-0001-4C1A-9E1A-52A2D9A4B001").unwrap(),
                title: "Commit".into(),
                message: "Commit".into(),
            },
            Self {
                id: Uuid::parse_str("6F1C2A3B-0002-4C1A-9E1A-52A2D9A4B002").unwrap(),
                title: "Commit and Push".into(),
                message: "Commit and push".into(),
            },
            Self {
                id: Uuid::parse_str("6F1C2A3B-0003-4C1A-9E1A-52A2D9A4B003").unwrap(),
                title: "Continue".into(),
                message: "Continue".into(),
            },
        ]
    }

    pub fn text(&self) -> &str {
        self.message.trim()
    }

    pub fn label(&self) -> &str {
        let name = self.title.trim();
        if name.is_empty() {
            self.text().lines().next().unwrap_or("")
        } else {
            name
        }
    }
}
