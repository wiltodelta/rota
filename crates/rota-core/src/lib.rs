//! Core scheduling, runner, transcript, and control-socket engine for Rota.

pub mod control;
pub mod diagnostics;
pub mod import;
pub mod model;
pub mod rpc;
pub mod runners;
pub mod schedule;
pub mod scheduler;
pub mod storage;
pub mod transcript;

pub use control::{
    CliArguments, ControlCli, ControlClient, ControlError, ControlHandler, ControlInterface, ControlMethod,
    ControlServer, ControlServerHandle, ControlTool,
};
pub use diagnostics::{
    PerformanceContext, PerformanceDiagnostics, PerformanceEvent, PerformanceEventKind, PerformanceLog,
    PerformanceProbeState, PerformanceSurface, TranscriptPerformance,
};
pub use import::{
    ClaudeDesktopImport, CodexAutomationsImport, ImportCandidate, ImportScan, ImportSource, RoutineImport,
};
pub use model::{
    AgentQuestion, ChatAttachment, ChatMessage, ConfigurationMark, Harness, HarnessCapabilities,
    HarnessImages, HarnessInput, HarnessMessages, HarnessQuestions, LaunchMode, QuestionAnswer,
    QuestionDraft, QuestionField, QuestionFieldKind, QuestionOption, QuestionReceipt, QuestionReceiptField,
    QuestionRequest, QuickReply, Routine, RoutineOrder, RunOutcome, RunRecord, RunTrigger,
    SessionConfiguration, SessionFilter, SessionFilters, TerminalState,
};
pub use rpc::{JsonRpcError, JsonRpcPeer, LineTransport, MessageTransport, WebSocketTransport};
pub use runners::{
    AgentAccess, AgentLauncher, AntigravityCatalog, AntigravityConfiguration, ClaudeConfiguration,
    ClaudeRunSettings, ClaudeUserSettings, ExecutableDiscovery, GrokCatalog, InstalledExecutable,
    LaunchError, LaunchSpec, ModelCatalog, ModelOption, NativeTranscript, NativeTranscriptEvent,
    ProcessLauncher, QuestionHook, QuestionReplyFn, RoutineLaunching, RunControl, RunEvents,
};
pub use schedule::{
    CalendarDay, CalendarEntry, CalendarEntryKind, CalendarQuery, CronError, CronSchedule, ScheduleCalendar,
    ScheduleText,
};
pub use scheduler::{NetworkFailure, Scheduler, SchedulerNotifier, ServiceProbe, SessionRestart};
pub use storage::{
    AttachmentError, ChatAttachmentStore, HistoryDeletionError, RoutineStore, RunHistory, RunLease,
    SessionImageStore, StorageLocation,
};
pub use transcript::{
    ChatRow, ColumnAlignment, InlineSpan, JournalError, JournalPage, MarkdownAlert, MarkdownBlock,
    MarkdownImageReference, MarkdownTable, Outgoing, PlanStep, PlanStepStatus, RunJournal, SessionPreview,
    ToolOutput, ToolOutputKind, ToolOutputPart, ToolStep, Transcript, TranscriptItem, TranscriptItemKind,
    TranscriptJournal, TranscriptOrder, TranscriptReader, TranscriptRecord, TranscriptService,
    TranscriptSessionReader, TranscriptSnapshot, TranscriptTurn, WorkRow,
};
