pub mod antigravity;
pub mod antigravity_archive;
pub mod antigravity_stream;
pub mod catalog;
pub mod catalog_providers;
pub mod claude_dialog;
pub mod claude_dialog_bridge;
pub mod claude_interactive;
mod claude_interactive_poll;
pub mod claude_stream;
mod claude_stream_exec;
pub mod claude_transcript;
pub mod codex;
mod codex_rpc;
mod codex_session;
pub mod codex_support;
pub mod discovery;
pub mod grok;
pub mod grok_activity;
pub mod grok_recovery;
pub mod launcher;
pub mod native_transcript;
mod native_transcript_events;
pub mod screen;
pub mod stream_json;
pub mod streams;
pub mod terminal;
mod terminal_attach;

use std::collections::HashMap;
use std::fmt;
use std::path::PathBuf;
use std::sync::Arc;

use crate::model::{
    AgentQuestion, LaunchMode, QuestionAnswer, RunOutcome, SessionConfiguration, TerminalState,
};

pub use antigravity::{
    AntigravityEvent, AntigravityQuestionArchive, AntigravityRun, AntigravityStream, AntigravityTranscript,
};
pub use catalog::{
    AntigravityCatalog, AntigravityConfiguration, AntigravityRow, ClaudeConfiguration, GrokCatalog,
    ModelCatalog, ModelOption,
};
pub use claude_dialog::{ClaudeDialog, ClaudeDialogBridge, ClaudeDialogEvent, QuestionHook};
pub use claude_interactive::{ClaudeInteractiveRun, ClaudeToolCall, ClaudeTranscript};
pub use claude_stream::{ClaudeStreamRun, StreamJsonFormatter};
pub use codex::CodexDaemonRun;
pub use codex_support::{CodexAsyncQuestions, CodexItemOutput};
pub use discovery::{
    AgentAccess, ClaudeRunSettings, ClaudeUserSettings, ExecutableDiscovery, InstalledExecutable,
};
pub use grok::{GrokAcpRun, GrokActivity, GrokRecovery, GrokToolOutput};
pub(crate) use launcher::is_executable_file;
pub use launcher::{AgentLauncher, ProcessLauncher};
pub use screen::ScreenRun;
pub use streams::{CommandCapture, DurableStream, SessionBridge, SubagentStatus};
pub use terminal::{NativeTranscript, NativeTranscriptEvent, TerminalRun};

#[derive(Debug, Clone, PartialEq)]
pub struct LaunchSpec {
    pub executable: String,
    pub prompt: String,
    pub arguments: Vec<String>,
    pub working_directory: String,
    pub environment: HashMap<String, String>,
    pub mode: LaunchMode,
    pub timeout_secs: Option<f64>,
    pub log: PathBuf,
    pub resume: Option<String>,
    pub model: Option<String>,
    pub effort: Option<String>,
    pub notice: Option<String>,
    pub terminal_transcript: Option<PathBuf>,
    pub adopt: bool,
}

impl LaunchSpec {
    pub fn model_flags(&self, effort_flag: &str) -> Vec<String> {
        let mut flags = Vec::new();
        if let Some(m) = &self.model {
            flags.push("--model".to_string());
            flags.push(m.clone());
        }
        if let Some(e) = &self.effort {
            flags.push(effort_flag.to_string());
            flags.push(e.clone());
        }
        flags
    }
}

pub trait RunControl: Send + Sync {
    fn stop(&self);
    fn send(&self, _message: &str) {}
    fn attach_command(&self) -> Option<Vec<String>> {
        None
    }
}

pub type QuestionReplyFn = Arc<dyn Fn(QuestionAnswer) + Send + Sync + 'static>;

#[derive(Clone)]
pub struct RunEvents {
    pub session: Arc<dyn Fn(String) + Send + Sync>,
    pub finished: Arc<dyn Fn(RunOutcome) + Send + Sync>,
    pub configuration: Arc<dyn Fn(SessionConfiguration) + Send + Sync>,
    pub question: Arc<dyn Fn(AgentQuestion, QuestionReplyFn) + Send + Sync>,
    pub question_resolved: Arc<dyn Fn(String) + Send + Sync>,
    pub terminal_state: Arc<dyn Fn(TerminalState) + Send + Sync>,
    pub terminal_input: Arc<dyn Fn() + Send + Sync>,
    pub undelivered: Arc<dyn Fn(String) + Send + Sync>,
    pub provenance: Arc<dyn Fn(Option<String>, Option<String>) + Send + Sync>,
    pub reconciliation_required: Arc<dyn Fn() + Send + Sync>,
}

impl RunEvents {
    pub fn new<S, F>(session: S, finished: F) -> Self
    where
        S: Fn(String) + Send + Sync + 'static,
        F: Fn(RunOutcome) + Send + Sync + 'static,
    {
        Self {
            session: Arc::new(session),
            finished: Arc::new(finished),
            configuration: Arc::new(|_| {}),
            question: Arc::new(|_, reply| reply(QuestionAnswer::cancel())),
            question_resolved: Arc::new(|_| {}),
            terminal_state: Arc::new(|_| {}),
            terminal_input: Arc::new(|| {}),
            undelivered: Arc::new(|_| {}),
            provenance: Arc::new(|_, _| {}),
            reconciliation_required: Arc::new(|| {}),
        }
    }
}

pub trait RoutineLaunching: Send + Sync {
    fn launch(&self, spec: LaunchSpec, events: RunEvents) -> Result<Arc<dyn RunControl>, LaunchError>;
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum LaunchError {
    MissingExecutable(String),
    MissingDirectory(String),
    ScreenFailed(i32),
    Message(String),
}

impl fmt::Display for LaunchError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::MissingExecutable(p) => write!(f, "no executable at {p}"),
            Self::MissingDirectory(p) => write!(f, "no folder at {p}"),
            Self::ScreenFailed(s) => write!(f, "screen exited with {s}"),
            Self::Message(m) => f.write_str(m),
        }
    }
}

impl std::error::Error for LaunchError {}
