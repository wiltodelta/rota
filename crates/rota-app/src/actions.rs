//! Typed UI actions, focus targets, and cross-thread shell events for Rota.

use std::collections::HashMap;

use rota_core::import::ImportScan;
use rota_core::model::{Harness, SessionFilter};
use rota_core::runners::{InstalledExecutable, ModelOption};
use rota_platform::NotificationUserEvent;
use rota_ui::UiActionId;
use uuid::Uuid;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum SettingsPane {
    General,
    Chat,
    Agents,
}

impl SettingsPane {
    pub const ALL: [Self; 3] = [Self::General, Self::Chat, Self::Agents];

    pub const fn as_str(self) -> &'static str {
        match self {
            Self::General => "general",
            Self::Chat => "chat",
            Self::Agents => "agents",
        }
    }

    pub const fn title(self) -> &'static str {
        match self {
            Self::General => "General",
            Self::Chat => "Chat",
            Self::Agents => "Agents",
        }
    }

    pub fn parse(raw: &str) -> Option<Self> {
        match raw.trim().to_ascii_lowercase().as_str() {
            "general" => Some(Self::General),
            "chat" => Some(Self::Chat),
            "agents" => Some(Self::Agents),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum SidebarSelection {
    Session(Uuid),
    Routine(String),
    Schedule,
}

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum FocusTarget {
    Sidebar,
    Composer,
    ChatTextScale,
    Control(String),
    QuestionField(String),
    RoutineSkill,
    RoutineName,
    RoutineFolder,
    RoutineSchedule,
    RoutineRunLimit,
    RoutineTimeLimit,
    RoutinePrompt,
    ImportSearch,
    QuickReplyTitle(usize),
    QuickReplyMessage(usize),
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SchedulePreset {
    Once,
    Daily,
    Weekdays,
    Weekly,
    Monthly,
    Hourly,
    Custom,
}

impl SchedulePreset {
    pub const ALL: [Self; 6] = [
        Self::Once,
        Self::Daily,
        Self::Weekdays,
        Self::Weekly,
        Self::Monthly,
        Self::Custom,
    ];

    pub const fn title(self) -> &'static str {
        match self {
            Self::Once => "Does Not Repeat",
            Self::Daily => "Daily",
            Self::Weekdays => "Weekdays",
            Self::Weekly => "Weekly",
            Self::Monthly => "Monthly",
            Self::Hourly => "Hourly",
            Self::Custom => "Custom",
        }
    }

    pub const fn default_cron(self) -> Option<&'static str> {
        match self {
            Self::Weekdays => Some("0 9 * * 1-5"),
            Self::Daily => Some("0 9 * * *"),
            Self::Weekly => Some("0 9 * * 1"),
            Self::Monthly => Some("0 9 1 * *"),
            Self::Hourly => Some("0 * * * *"),
            Self::Once | Self::Custom => None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MenuId {
    SessionFilter,
    RestartSession { sid: Uuid, after_limit: bool },
    SessionModel(Uuid),
    SessionEffort(Uuid),
    DiscussionAgent,
    DiscussionModel,
    DiscussionEffort,
    FormHarness,
    FormModel,
    FormEffort,
    FormRepeat,
    FormCronPresets,
    FormEnds,
    ImportAgent,
    ScheduleOptions,
    InterfaceScale,
    PreferredTerminal,
    ChatFont,
    AgentCli(Harness),
}

impl MenuId {
    pub fn anchor_element_id(&self) -> String {
        match self {
            Self::SessionFilter => "sessionFilter".to_string(),
            Self::RestartSession {
                after_limit: true, ..
            } => "restartSessionAfterLimit".to_string(),
            Self::RestartSession {
                after_limit: false, ..
            } => "restartSession".to_string(),
            Self::SessionModel(_) => "composerModel".to_string(),
            Self::SessionEffort(_) => "composerEffort".to_string(),
            Self::DiscussionAgent => "discussionAgent".to_string(),
            Self::DiscussionModel => "discussionModel".to_string(),
            Self::DiscussionEffort => "discussionEffort".to_string(),
            Self::FormHarness => "routineHarness".to_string(),
            Self::FormModel => "routineModel".to_string(),
            Self::FormEffort => "routineEffort".to_string(),
            Self::FormRepeat => "routineRepeat".to_string(),
            Self::FormCronPresets => "schedulePresets".to_string(),
            Self::FormEnds => "routineEnds".to_string(),
            Self::ImportAgent => "importAgent".to_string(),
            Self::ScheduleOptions => "scheduleOptions".to_string(),
            Self::InterfaceScale => "interfaceScale".to_string(),
            Self::PreferredTerminal => "terminalApp".to_string(),
            Self::ChatFont => "chatFont".to_string(),
            Self::AgentCli(h) => format!("agentCli-{}", h.as_str()),
        }
    }
}

/// Strongly-typed UI action registered per frame into `ActionRegistry`.
#[derive(Debug, Clone)]
pub enum AppAction {
    Noop,
    ToggleSidebar,
    ToggleSchedule,
    OpenNewRoutine,
    OpenImportSheet,
    OpenSettings(Option<SettingsPane>),
    CloseSettings,
    SelectRoutine(String),
    SelectSession(Uuid),
    ToggleFilterMenu,
    OpenMenu(MenuId),
    CloseMenu,
    ToggleSessionFilter(SessionFilter),
    ResetSessionFilters,
    FocusField(FocusTarget),
    // Session actions
    ShowSessionRoutine(String),
    OpenInTerminal(Uuid),
    RevealSessionLog(Uuid),
    ToggleRestartPopover,
    RestartSessionWith {
        session_id: Uuid,
        harness: Harness,
    },
    SetSessionModel {
        session_id: Uuid,
        model: Option<String>,
    },
    SetSessionEffort {
        session_id: Uuid,
        effort: Option<String>,
    },
    ToggleMarkUnread(Uuid),
    PromptDeleteSession(Uuid),
    ConfirmDeleteSession,
    CancelDeleteModal,
    StopSession(Uuid),
    DismissAttention(Uuid),
    LoadEarlierMessages(Uuid),
    ScrollToLatest(Uuid),
    ToggleTranscriptDisclosure {
        session_id: Uuid,
        item_id: usize,
    },
    CopyText(String),
    CopyTextWithId {
        id: String,
        text: String,
    },
    DismissErrorBanner,
    OpenUrlOrPath(String),
    RevealQuestion(Uuid),
    // Question card
    ToggleQuestionContext(Uuid),
    SelectQuestionOption {
        field_id: String,
        option_id: String,
    },
    SelectQuestionOther {
        field_id: String,
    },
    QuestionPrev,
    QuestionNext,
    QuestionSubmit(String),
    // Composer & Shell Discussion
    AttachFiles(Uuid),
    RemoveAttachment {
        session_id: Uuid,
        index: usize,
    },
    SendQuickReply {
        session_id: Uuid,
        index: usize,
    },
    SendComposer(Uuid),
    CycleSessionModel(Uuid),
    CycleSessionEffort(Uuid),
    SelectDiscussionAgent(Harness),
    SetDiscussionModel(Option<String>),
    SetDiscussionEffort(Option<String>),
    CycleDiscussionModel,
    CycleDiscussionEffort,
    // Routine detail
    ToggleRoutineEnabled(String),
    RunRoutineNow(String),
    StopRoutine(String),
    EditRoutine(String),
    PromptDeleteRoutine(String),
    ConfirmDeleteRoutine,
    // Schedule view
    ScheduleStepWeeks(i32),
    ScheduleToday,
    ScheduleSelectDay(i64),
    ToggleShowPausedInSchedule,
    // Routine form modal
    CloseModal,
    FormSetHarness(Harness),
    FormChooseFolder,
    FormSetModel(Option<String>),
    FormSetEffort(Option<String>),
    FormSetPreset(SchedulePreset),
    FormApplyCron(String),
    FormSetRunLimitEnabled(bool),
    FormToggleTimeLimit,
    FormAdjustTimeLimit(i64),
    FormToggleRunLimit,
    FormAdjustRunLimit(i64),
    SaveRoutineForm,
    // Import modal
    ImportToggleShowImported,
    ImportToggleCandidate(String),
    ImportSelectAllSource(usize),
    ImportSetTargetHarness(Option<Harness>),
    ImportCycleTargetHarness,
    ConfirmImportSelected,
    // Settings actions
    SetInterfaceScale(u8),
    ToggleCompletionNotifications,
    SetPreferredTerminal(Option<String>),
    CyclePreferredTerminal,
    ChooseCustomTerminal,
    ToggleLaunchAtLogin,
    ToggleAutoCheckUpdates,
    CheckForUpdatesNow,
    SetChatFontMono(bool),
    SetChatScaleDirect(u16),
    AdjustChatScale(i32),
    ResetChatScale,
    AddQuickReply,
    RemoveQuickReply(usize),
    RestoreDefaultQuickReplies,
    SetAgentExecutable {
        harness: Harness,
        path: Option<String>,
    },
    ChooseAgentExecutable(Harness),
    ResetAgentExecutable(Harness),
    ToggleClaudeInteractive,
    RequestAccessibilityPermission,
    RequestScreenRecordingPermission,
    InstallCliCommand,
    ToggleAgentMcp(Harness),
    // Menu bar panel actions
    PanelOpenMain,
    PanelSelectRoutine(String),
    PanelToggleRunRoutine(String),
    PanelOpenSettings,
    PanelQuit,
}

#[derive(Default)]
pub struct ActionRegistry {
    actions: Vec<AppAction>,
    by_element_id: HashMap<String, UiActionId>,
}

impl ActionRegistry {
    pub fn new() -> Self {
        Self {
            actions: vec![AppAction::Noop],
            by_element_id: HashMap::new(),
        }
    }

    pub fn clear(&mut self) {
        self.actions.clear();
        self.actions.push(AppAction::Noop);
        self.by_element_id.clear();
    }

    pub fn register(&mut self, action: AppAction) -> UiActionId {
        let idx = self.actions.len();
        self.actions.push(action);
        UiActionId(idx as u64)
    }

    pub fn register_named(&mut self, element_id: impl Into<String>, action: AppAction) -> UiActionId {
        let id = self.register(action);
        self.by_element_id.insert(element_id.into(), id);
        id
    }

    pub fn resolve(&self, id: UiActionId) -> Option<&AppAction> {
        self.actions.get(id.0 as usize)
    }

    pub fn action_for_element(&self, element_id: &str) -> Option<UiActionId> {
        self.by_element_id.get(element_id).copied()
    }
}

/// Asynchronous or OS-shell events delivered to `AppState` on `on_idle_poll`.
#[derive(Debug, Clone)]
pub enum ShellEvent {
    ReopenMainWindow,
    HideMainWindow,
    OpenSettings(Option<SettingsPane>),
    OpenNewRoutine,
    OpenImportRoutines,
    ShowSchedule,
    ScheduleStep(i32),
    ScheduleToday,
    ToggleShowPaused,
    ToggleSidebar,
    EditCommand(rota_ui::EditKey),
    ZoomInterface(i32),
    ResetInterfaceZoom,
    ZoomChat(i32),
    ResetChatZoom,
    RunSelectedRoutine,
    StopSelected,
    EditSelectedRoutine,
    ShowSelectedRoutine,
    OpenSelectedInTerminal,
    RevealSelectedLog,
    RevealSelectedQuestion,
    DismissSelectedAttention,
    ToggleSelectedRead,
    LoadSelectedEarlier,
    DeleteSelectedSession,
    OpenHelp,
    CheckForUpdates,
    QuitRequested,
    TogglePanel,
    PanelAction(PanelInput),
    Notification(NotificationUserEvent),
    DiscoveryFinished {
        installed: HashMap<Harness, Vec<InstalledExecutable>>,
        mcp_added: HashMap<Harness, bool>,
        command_installed: bool,
    },
    ModelCatalogLoaded {
        harness: Harness,
        options: Vec<ModelOption>,
    },
    ImportScanFinished(Vec<ImportScan>),
    McpToggleFinished {
        harness: Harness,
        added: bool,
        error: Option<String>,
    },
}

#[derive(Debug, Clone)]
pub enum PanelInput {
    Hover(Option<String>),
    MoveHighlight(i32),
    ActivateHighlighted,
    RunHighlighted,
    StopHighlighted,
    ClosePanel,
    OpenMain,
    OpenNew,
    OpenSchedule,
    OpenRoutine(String),
    OpenSession(Uuid),
    ToggleRun(String),
    OpenSettings,
    Quit,
}
