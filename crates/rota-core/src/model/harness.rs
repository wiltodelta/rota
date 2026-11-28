use std::path::Path;

use base64::Engine;
use rota_platform::{home_dir, inspect_image_bytes};
use serde::{Deserialize, Deserializer, Serialize, Serializer};
use serde_json::{Value, json};

use crate::model::ChatMessage;

/// What a routine runs on: an agent CLI, or a plain shell command.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Harness {
    Claude,
    Codex,
    Grok,
    Antigravity,
    Shell,
}

impl Harness {
    pub const ALL: [Self; 5] = [
        Self::Claude,
        Self::Codex,
        Self::Grok,
        Self::Antigravity,
        Self::Shell,
    ];

    pub const AGENTS: [Self; 4] = [Self::Claude, Self::Codex, Self::Grok, Self::Antigravity];

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Claude => "claude",
            Self::Codex => "codex",
            Self::Grok => "grok",
            Self::Antigravity => "antigravity",
            Self::Shell => "shell",
        }
    }

    pub fn parse(raw: &str) -> Option<Self> {
        match raw {
            "claude" => Some(Self::Claude),
            "codex" => Some(Self::Codex),
            "grok" => Some(Self::Grok),
            "antigravity" => Some(Self::Antigravity),
            "shell" => Some(Self::Shell),
            _ => None,
        }
    }

    pub fn command_name(self) -> &'static str {
        match self {
            Self::Shell => "zsh",
            Self::Antigravity => "agy",
            _ => self.as_str(),
        }
    }

    pub fn title(self) -> &'static str {
        match self {
            Self::Claude => "Claude Code",
            Self::Codex => "Codex",
            Self::Grok => "Grok Build",
            Self::Antigravity => "Antigravity",
            Self::Shell => "Shell",
        }
    }

    pub fn is_agent(self) -> bool {
        self != Self::Shell
    }

    pub fn default_executable(self) -> String {
        self.default_executable_in(&home_dir())
    }

    pub fn default_executable_in(self, home: &Path) -> String {
        match self {
            Self::Claude | Self::Grok | Self::Antigravity => home
                .join(".local/bin")
                .join(self.command_name())
                .to_string_lossy()
                .into_owned(),
            Self::Codex => format!("/opt/homebrew/bin/{}", self.command_name()),
            Self::Shell => format!("/bin/{}", self.command_name()),
        }
    }

    pub fn launch_mode(self) -> LaunchMode {
        match self {
            Self::Claude => LaunchMode::ClaudeStream,
            Self::Codex => LaunchMode::CodexDaemon,
            Self::Grok => LaunchMode::GrokAcp,
            Self::Antigravity => LaunchMode::AntigravityStream,
            Self::Shell => LaunchMode::Screen,
        }
    }

    pub fn claude_arguments(self, chrome_by_default: bool, resume: Option<&str>) -> Vec<String> {
        if self != Self::Claude {
            return Vec::new();
        }
        let mut args = vec![
            "-p".to_string(),
            "--input-format".to_string(),
            "stream-json".to_string(),
            "--output-format".to_string(),
            "stream-json".to_string(),
            "--verbose".to_string(),
            "--permission-mode".to_string(),
            "bypassPermissions".to_string(),
            "--permission-prompt-tool".to_string(),
            "stdio".to_string(),
            "--include-partial-messages".to_string(),
        ];
        if chrome_by_default {
            args.push("--chrome".to_string());
        }
        if let Some(session) = resume {
            args.push("--resume".to_string());
            args.push(session.to_string());
        }
        args
    }

    /// Terminal command (`(executable_override, arguments)`) for `session` when `running` or idle.
    pub fn terminal(self, session: &str, running: bool) -> Option<(Option<&'static str>, Vec<String>)> {
        match (self, running) {
            (Self::Claude, false) => Some((None, vec!["--resume".into(), session.into()])),
            (Self::Codex, false) => Some((None, vec!["resume".into(), session.into()])),
            (Self::Grok, false) => Some((None, vec!["--resume".into(), session.into()])),
            (Self::Antigravity, false) => Some((None, vec!["--conversation".into(), session.into()])),
            (Self::Shell, true) => Some((Some("/usr/bin/screen"), vec!["-r".into(), session.into()])),
            _ => None,
        }
    }

    pub fn takes_messages(self) -> bool {
        self.launch_mode().capabilities().messages != HarnessMessages::Terminal
    }
}

/// How a run is started and watched. Serializes identically to Swift's synthesized `Codable` enum.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum LaunchMode {
    ClaudeStream,
    ClaudeInteractive,
    CodexDaemon,
    GrokAcp,
    AntigravityStream,
    Screen,
    Terminal(Harness),
}

impl LaunchMode {
    pub const CODEX_APP_SERVER: Self = Self::CodexDaemon;
    pub const SHELL_SCREEN: Self = Self::Screen;

    pub fn records_initial_prompt(self) -> bool {
        !matches!(self, Self::Terminal(_))
    }

    pub fn name(self) -> String {
        match self {
            Self::ClaudeStream => "claudeStream".to_string(),
            Self::ClaudeInteractive => "claudeInteractive".to_string(),
            Self::CodexDaemon => "codexDaemon".to_string(),
            Self::GrokAcp => "grokACP".to_string(),
            Self::AntigravityStream => "antigravityStream".to_string(),
            Self::Screen => "screen".to_string(),
            Self::Terminal(h) => format!("terminal/{}", h.as_str()),
        }
    }

    pub fn capabilities(self) -> HarnessCapabilities {
        match self {
            Self::ClaudeStream => HarnessCapabilities {
                messages: HarnessMessages::Steer,
                questions: HarnessQuestions::Hooks,
                images: HarnessImages::Blocks,
                streams_text: true,
                exposes_reasoning: true,
                waits_for_background_work: true,
            },
            Self::ClaudeInteractive => HarnessCapabilities {
                messages: HarnessMessages::Steer,
                questions: HarnessQuestions::Hooks,
                images: HarnessImages::FileReferences,
                streams_text: false,
                exposes_reasoning: true,
                waits_for_background_work: true,
            },
            Self::CodexDaemon => HarnessCapabilities {
                messages: HarnessMessages::Steer,
                questions: HarnessQuestions::Hosted,
                images: HarnessImages::LocalPath,
                streams_text: true,
                exposes_reasoning: true,
                waits_for_background_work: false,
            },
            Self::GrokAcp => HarnessCapabilities {
                messages: HarnessMessages::Queued,
                questions: HarnessQuestions::Hosted,
                images: HarnessImages::Blocks,
                streams_text: true,
                exposes_reasoning: true,
                waits_for_background_work: true,
            },
            Self::AntigravityStream => HarnessCapabilities {
                messages: HarnessMessages::Queued,
                questions: HarnessQuestions::LaterMessage,
                images: HarnessImages::FileReferences,
                streams_text: true,
                exposes_reasoning: true,
                waits_for_background_work: false,
            },
            Self::Terminal(_) => HarnessCapabilities {
                messages: HarnessMessages::Terminal,
                questions: HarnessQuestions::Unavailable,
                images: HarnessImages::FileReferences,
                streams_text: false,
                exposes_reasoning: true,
                waits_for_background_work: false,
            },
            Self::Screen => HarnessCapabilities {
                messages: HarnessMessages::Terminal,
                questions: HarnessQuestions::Unavailable,
                images: HarnessImages::FileReferences,
                streams_text: false,
                exposes_reasoning: false,
                waits_for_background_work: false,
            },
        }
    }
}

impl Serialize for LaunchMode {
    fn serialize<S: Serializer>(&self, serializer: S) -> Result<S::Ok, S::Error> {
        let value = match self {
            Self::ClaudeStream => json!({"claudeStream": {}}),
            Self::ClaudeInteractive => json!({"claudeInteractive": {}}),
            Self::CodexDaemon => json!({"codexDaemon": {}}),
            Self::GrokAcp => json!({"grokACP": {}}),
            Self::AntigravityStream => json!({"antigravityStream": {}}),
            Self::Screen => json!({"screen": {}}),
            Self::Terminal(harness) => json!({"terminal": {"_0": harness.as_str()}}),
        };
        value.serialize(serializer)
    }
}

impl<'de> Deserialize<'de> for LaunchMode {
    fn deserialize<D: Deserializer<'de>>(deserializer: D) -> Result<Self, D::Error> {
        let val = Value::deserialize(deserializer)?;
        if let Some(s) = val.as_str() {
            return match s {
                "claudeStream" => Ok(Self::ClaudeStream),
                "claudeInteractive" => Ok(Self::ClaudeInteractive),
                "codexDaemon" | "codexAppServer" => Ok(Self::CodexDaemon),
                "grokACP" => Ok(Self::GrokAcp),
                "antigravityStream" => Ok(Self::AntigravityStream),
                "screen" | "shellScreen" => Ok(Self::Screen),
                other if other.starts_with("terminal/") => Harness::parse(&other[9..])
                    .map(Self::Terminal)
                    .ok_or_else(|| serde::de::Error::custom("Invalid terminal harness")),
                _ => Err(serde::de::Error::custom(format!("Unknown LaunchMode: {s}"))),
            };
        }
        let obj = val
            .as_object()
            .ok_or_else(|| serde::de::Error::custom("Expected LaunchMode object"))?;
        if obj.contains_key("claudeStream") {
            Ok(Self::ClaudeStream)
        } else if obj.contains_key("claudeInteractive") {
            Ok(Self::ClaudeInteractive)
        } else if obj.contains_key("codexDaemon") || obj.contains_key("codexAppServer") {
            Ok(Self::CodexDaemon)
        } else if obj.contains_key("grokACP") {
            Ok(Self::GrokAcp)
        } else if obj.contains_key("antigravityStream") {
            Ok(Self::AntigravityStream)
        } else if obj.contains_key("screen") || obj.contains_key("shellScreen") {
            Ok(Self::Screen)
        } else if let Some(term) = obj.get("terminal") {
            let h_str = term
                .get("_0")
                .and_then(Value::as_str)
                .or_else(|| term.as_str())
                .ok_or_else(|| serde::de::Error::custom("Missing terminal._0 harness"))?;
            Harness::parse(h_str)
                .map(Self::Terminal)
                .ok_or_else(|| serde::de::Error::custom("Unknown terminal harness"))
        } else {
            Err(serde::de::Error::custom("Unknown LaunchMode variant"))
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum HarnessMessages {
    Steer,
    Queued,
    Terminal,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum HarnessQuestions {
    Hosted,
    Hooks,
    LaterMessage,
    Unavailable,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum HarnessImages {
    Blocks,
    LocalPath,
    FileReferences,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct HarnessCapabilities {
    pub messages: HarnessMessages,
    pub questions: HarnessQuestions,
    pub images: HarnessImages,
    pub streams_text: bool,
    pub exposes_reasoning: bool,
    pub waits_for_background_work: bool,
}

pub struct HarnessInput;

impl HarnessInput {
    const INLINE_BUDGET: usize = 3_500_000;

    pub fn blocks(message: &str, mode: LaunchMode) -> Vec<Value> {
        let mut out = vec![json!({"type": "text", "text": message})];
        let caps = mode.capabilities();
        if caps.images == HarnessImages::FileReferences {
            return out;
        }
        let mut inline_bytes = 0usize;
        let grok_only = mode == LaunchMode::GrokAcp;
        for file in ChatMessage::decode(message).attachments {
            let Ok(meta) = std::fs::metadata(&file.path) else {
                continue;
            };
            if !meta.is_file() || meta.len() > 20 * 1024 * 1024 {
                continue;
            }
            let Ok(bytes) = std::fs::read(&file.path) else {
                continue;
            };
            let Some(info) = inspect_image_bytes(&bytes) else {
                continue;
            };
            if grok_only && info.mime != "image/png" && info.mime != "image/jpeg" {
                continue;
            }
            if mode == LaunchMode::CodexDaemon && info.mime == "image/gif" && info.animated {
                continue;
            }
            if caps.images == HarnessImages::LocalPath {
                out.push(json!({"type": "localImage", "path": file.path}));
            } else if bytes.len() <= Self::INLINE_BUDGET.saturating_sub(inline_bytes) {
                inline_bytes += bytes.len();
                let encoded = base64::engine::general_purpose::STANDARD.encode(&bytes);
                if mode == LaunchMode::ClaudeStream {
                    out.push(json!({
                        "type": "image",
                        "source": {
                            "type": "base64",
                            "media_type": info.mime,
                            "data": encoded
                        }
                    }));
                } else {
                    out.push(json!({
                        "type": "image",
                        "mimeType": info.mime,
                        "data": encoded
                    }));
                }
            }
        }
        out
    }
}
