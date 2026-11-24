//! Central `AppState` holding cached scheduler snapshots, virtual scroll states, drafts, and modals.

use std::collections::{HashMap, HashSet};
use std::path::Path;
use std::sync::Arc;
use std::sync::mpsc::{Receiver, Sender, channel};

use jiff::Timestamp;
use rota_core::Scheduler;
use rota_core::import::RoutineImport;
use rota_core::model::{
    ChatAttachment, Harness, QuestionDraft, Routine, RoutineOrder, RunOutcome, RunRecord, SessionFilters,
};
use rota_core::runners::{AgentAccess, ExecutableDiscovery, ModelCatalog};
use rota_core::transcript::{MarkdownBlock, Outgoing, TranscriptSessionReader, TranscriptSnapshot};
use rota_ui::{
    ActivityClock, Appearance, ComputedUiTree, Modifiers, Point, Rect, SelectableBlock, Size, SpringSet,
    TextEditState, Theme, TranscriptSelection, UiActionId, VirtualScrollState, WindowAppearance,
};
use uuid::Uuid;

use crate::actions::{ActionRegistry, FocusTarget, MenuId, SettingsPane, ShellEvent, SidebarSelection};
pub use crate::form_state::{ImportSheetState, RoutineFormState, ScheduleViewState};
use crate::popup_macos::PopupRequest;
use crate::settings_store::SettingsStore;
use crate::shell_macos::wake_app_event_loop;

pub struct CachedSessionTranscript {
    pub reader: TranscriptSessionReader,
    pub snapshot: TranscriptSnapshot,
    pub markdown_cache: HashMap<(usize, usize), Vec<MarkdownBlock>>,
    pub scroll: VirtualScrollState,
    pub selection: TranscriptSelection,
    pub selectable_blocks: Vec<SelectableBlock>,
    pub expanded_items: HashSet<usize>,
    pub outbox: Vec<Outgoing>,
    pub question_drafts: HashMap<String, QuestionDraft>,
    pub question_editors: HashMap<(String, String), TextEditState>,
    pub question_context_expanded: bool,
    pub question_fully_visible: bool,
    pub last_read_rev: u64,
    pub last_marked_read: bool,
}

impl Default for CachedSessionTranscript {
    fn default() -> Self {
        Self::new()
    }
}

impl CachedSessionTranscript {
    pub fn new() -> Self {
        Self {
            reader: TranscriptSessionReader::new(),
            snapshot: TranscriptSnapshot {
                items: Vec::new(),
                structured: false,
                problem: None,
                has_earlier: false,
            },
            markdown_cache: HashMap::new(),
            scroll: VirtualScrollState::new(),
            selection: TranscriptSelection::new(),
            selectable_blocks: Vec::new(),
            expanded_items: HashSet::new(),
            outbox: Vec::new(),
            question_drafts: HashMap::new(),
            question_editors: HashMap::new(),
            question_context_expanded: false,
            question_fully_visible: false,
            last_read_rev: 0,
            last_marked_read: false,
        }
    }

    pub fn parsed_markdown(&mut self, item_id: usize, text: &str) -> &[MarkdownBlock] {
        let key = (item_id, text.len());
        self.markdown_cache
            .entry(key)
            .or_insert_with(|| MarkdownBlock::parse(text))
    }
}

pub struct AppState {
    pub scheduler: Arc<Scheduler>,
    pub settings: SettingsStore,
    pub session_filters: SessionFilters,
    pub selection: Option<SidebarSelection>,
    pub settings_pane: Option<SettingsPane>,
    pub selection_before_settings: Option<SidebarSelection>,
    pub selection_before_schedule: Option<SidebarSelection>,
    pub focus: Option<FocusTarget>,
    pub hovered_id: Option<String>,
    pub pressed_id: Option<String>,
    pub pressed_action: Option<UiActionId>,
    pub pointer_pos: Option<Point>,
    pub modifiers: Modifiers,
    pub dragging_splitter: bool,
    pub dragging_editor: bool,
    pub dragging_slider: bool,
    pub dragging_scrollbar: Option<(String, f32)>,
    pub hover_tooltip: Option<(String, String, Rect, f64)>,
    pub open_menu: Option<(MenuId, Rect)>,
    pub pending_popup: Option<PopupRequest>,
    pub ime_preedit: String,
    pub file_drop_hovered: bool,
    pub window_focused: bool,
    pub last_caret_reset_time: f64,
    pub last_ime_cursor_rect: Option<Rect>,
    pub springs: SpringSet,
    pub appearance_override: Option<Appearance>,
    pub window_vibrant: bool,
    pub high_contrast: bool,
    pub main_window_visible: bool,
    pub panel_visible: bool,
    pub panel_highlighted: Option<String>,
    pub panel_hovered_id: Option<String>,
    pub cached_revision: u64,
    pub routines: Vec<Routine>,
    pub sessions: Vec<RunRecord>,
    pub preview_cache: HashMap<(Uuid, Timestamp), String>,
    pub unread_count: usize,
    pub attention_count: usize,
    pub running_count: usize,
    pub transcripts: HashMap<Uuid, CachedSessionTranscript>,
    pub composer_drafts: HashMap<Uuid, TextEditState>,
    pub composer_attachments: HashMap<Uuid, Vec<ChatAttachment>>,
    pub composer_error: Option<String>,
    pub restart_popover_open: bool,
    pub filter_menu_open: bool,
    pub pending_window_drag: bool,
    pub sidebar_scroll: VirtualScrollState,
    pub routine_detail_scroll: VirtualScrollState,
    pub settings_scroll: VirtualScrollState,
    pub schedule_state: ScheduleViewState,
    pub quick_reply_edits: Vec<(Uuid, TextEditState, TextEditState)>,
    pub routine_modal: Option<RoutineFormState>,
    pub import_modal: Option<ImportSheetState>,
    pub confirm_delete_session: Option<RunRecord>,
    pub confirm_delete_routine: Option<String>,
    pub error_banner: Option<String>,
    pub copied_feedback: Option<(String, f64)>,
    pub focus_order: Vec<FocusTarget>,
    pub now_seconds: f64,
    pub actions: ActionRegistry,
    pub last_tree: Option<ComputedUiTree>,
    pub viewport_size: Size,
    pub activity_clock: ActivityClock,
    pub shell_tx: Sender<ShellEvent>,
    pub shell_rx: Receiver<ShellEvent>,
}

impl AppState {
    pub fn new(
        scheduler: Arc<Scheduler>,
        settings: SettingsStore,
        appearance_override: Option<Appearance>,
    ) -> Self {
        let session_filters = SessionFilters::load(settings.prefs());
        let (shell_tx, shell_rx) = channel();
        let qr_edits = Self::build_quick_reply_edits(&settings);
        settings.set_executable_overrides_on(&scheduler);

        let mut this = Self {
            scheduler,
            settings,
            session_filters,
            selection: None,
            settings_pane: None,
            selection_before_settings: None,
            selection_before_schedule: None,
            focus: Some(FocusTarget::Sidebar),
            hovered_id: None,
            pressed_id: None,
            pressed_action: None,
            pointer_pos: None,
            modifiers: Modifiers::default(),
            dragging_splitter: false,
            dragging_editor: false,
            dragging_slider: false,
            dragging_scrollbar: None,
            hover_tooltip: None,
            open_menu: None,
            pending_popup: None,
            ime_preedit: String::new(),
            file_drop_hovered: false,
            window_focused: true,
            last_caret_reset_time: 0.0,
            last_ime_cursor_rect: None,
            springs: SpringSet::new(),
            appearance_override,
            window_vibrant: false,
            high_contrast: false,
            main_window_visible: false,
            panel_visible: false,
            panel_highlighted: None,
            panel_hovered_id: None,
            cached_revision: u64::MAX,
            routines: Vec::new(),
            sessions: Vec::new(),
            preview_cache: HashMap::new(),
            unread_count: 0,
            attention_count: 0,
            running_count: 0,
            transcripts: HashMap::new(),
            composer_drafts: HashMap::new(),
            composer_attachments: HashMap::new(),
            composer_error: None,
            restart_popover_open: false,
            filter_menu_open: false,
            pending_window_drag: false,
            sidebar_scroll: VirtualScrollState::new_top(),
            routine_detail_scroll: VirtualScrollState::new_top(),
            settings_scroll: VirtualScrollState::new_top(),
            schedule_state: ScheduleViewState::new(Timestamp::now()),
            quick_reply_edits: qr_edits,
            routine_modal: None,
            import_modal: None,
            confirm_delete_session: None,
            confirm_delete_routine: None,
            error_banner: None,
            copied_feedback: None,
            focus_order: Vec::new(),
            now_seconds: 0.0,
            actions: ActionRegistry::new(),
            last_tree: None,
            viewport_size: Size::new(1040.0, 680.0),
            activity_clock: ActivityClock::new(),
            shell_tx,
            shell_rx,
        };
        this.sidebar_scroll.stick_to_bottom = false;
        this.routine_detail_scroll.stick_to_bottom = false;
        this.settings_scroll.stick_to_bottom = false;
        this.schedule_state.scroll.stick_to_bottom = false;
        this.sync_from_scheduler(true);
        this.select_initial_destination();
        this
    }

    pub fn sync_from_scheduler(&mut self, force: bool) -> bool {
        let rev = self.scheduler.revision();
        if !force && rev == self.cached_revision {
            return false;
        }
        self.cached_revision = rev;
        self.routines = RoutineOrder::by_next_run(&self.scheduler.routines());
        self.sessions = self.scheduler.all_sessions();
        let (unread, attention) = self.scheduler.unread_and_attention_counts();
        self.unread_count = unread;
        self.attention_count = attention;
        self.running_count = self
            .routines
            .iter()
            .filter(|r| self.scheduler.is_running(&r.id))
            .count();

        let reader = TranscriptSessionReader::new();
        for rec in &self.sessions {
            let key = (rec.id, rec.last_activity_at());
            self.preview_cache
                .entry(key)
                .or_insert_with(|| reader.preview_once(rec));
        }

        if let Some(SidebarSelection::Session(id)) = self.selection {
            self.refresh_session_transcript(id, false);
        }
        true
    }

    pub fn select_initial_destination(&mut self) {
        if let Some(newest) = self.sessions.iter().find(|r| !r.is_skip()) {
            let id = newest.id;
            self.selection = Some(SidebarSelection::Session(id));
            self.refresh_session_transcript(id, false);
        } else if let Some(first_routine) = self.routines.first() {
            self.selection = Some(SidebarSelection::Routine(first_routine.id.clone()));
        }
    }

    #[inline]
    pub fn is_hovered(&self, id: &str) -> bool {
        self.hovered_id.as_deref() == Some(id)
    }

    #[inline]
    pub fn has_focused_editor(&self) -> bool {
        !matches!(
            self.focus,
            None | Some(FocusTarget::Sidebar)
                | Some(FocusTarget::Control(_))
                | Some(FocusTarget::ChatTextScale)
        )
    }

    #[inline]
    pub fn has_open_modal(&self) -> bool {
        self.confirm_delete_session.is_some()
            || self.confirm_delete_routine.is_some()
            || self.routine_modal.is_some()
            || self.import_modal.is_some()
    }

    #[inline]
    pub fn is_control_focused(&self, id: &str) -> bool {
        match &self.focus {
            Some(FocusTarget::Control(fid)) => fid == id,
            Some(FocusTarget::ChatTextScale) => id == "chatTextScale",
            _ => false,
        }
    }

    pub fn switch_progress(&mut self, id: &str, on: bool, now_seconds: f64) -> f32 {
        let target = if on { 1.0 } else { 0.0 };
        self.springs
            .animate(format!("sw-{id}"), target, now_seconds, &mut self.activity_clock)
    }

    pub fn refresh_session_transcript(&mut self, session_id: Uuid, load_earlier: bool) {
        let Some(rec) = self
            .scheduler
            .current_record(session_id)
            .or_else(|| self.sessions.iter().find(|r| r.id == session_id).cloned())
        else {
            return;
        };
        let running = rec.outcome == RunOutcome::Running;
        let entry = self.transcripts.entry(session_id).or_default();
        if let Some(log_str) = &rec.log_path {
            let snap = entry.reader.read(
                Path::new(log_str),
                rec.harness == Harness::Shell,
                !running,
                load_earlier,
            );
            entry.snapshot = snap;
        }
        if let Some(q) = rec.next_question() {
            entry
                .question_drafts
                .entry(q.id.clone())
                .or_insert_with(|| QuestionDraft::new(q.clone()));
        }
        if !running && !entry.last_marked_read && rec.is_unread() {
            entry.last_marked_read = true;
            let _ = self.scheduler.mark_read(session_id);
        }
        entry.last_read_rev = self.cached_revision;
    }

    pub fn active_appearance(&self) -> Appearance {
        self.appearance_override.unwrap_or_else(|| {
            if crate::shell_macos::system_is_dark() {
                Appearance::Dark
            } else {
                Appearance::Light
            }
        })
    }

    pub fn window_appearance(&self) -> WindowAppearance {
        match self.appearance_override {
            Some(Appearance::Light) => WindowAppearance::Light,
            Some(Appearance::Dark) => WindowAppearance::Dark,
            None => WindowAppearance::System,
        }
    }

    pub fn theme(&self) -> Theme {
        Theme::for_appearance(self.active_appearance())
            .with_scales(self.settings.interface_scale, self.settings.chat_scale)
            .with_high_contrast(self.high_contrast)
    }

    pub fn window_title(&self) -> String {
        if let Some(pane) = self.settings_pane {
            return pane.title().to_string();
        }
        match &self.selection {
            Some(SidebarSelection::Schedule) => "Schedule".to_string(),
            Some(SidebarSelection::Routine(id)) => self
                .routines
                .iter()
                .find(|r| &r.id == id)
                .map_or_else(|| "Rota".to_string(), |r| r.name.clone()),
            Some(SidebarSelection::Session(id)) => self
                .sessions
                .iter()
                .find(|s| &s.id == id)
                .and_then(|s| self.routines.iter().find(|r| r.id == s.routine_id))
                .map_or_else(|| "Rota".to_string(), |r| r.name.clone()),
            None => "Rota".to_string(),
        }
    }

    pub fn sidebar_shown(&self) -> bool {
        self.settings.sidebar_visible || self.settings_pane.is_some()
    }

    pub fn selected_routine(&self) -> Option<&Routine> {
        match &self.selection {
            Some(SidebarSelection::Routine(id)) => self.routines.iter().find(|r| &r.id == id),
            Some(SidebarSelection::Session(id)) => self
                .sessions
                .iter()
                .find(|s| &s.id == id)
                .and_then(|s| self.routines.iter().find(|r| r.id == s.routine_id)),
            _ => None,
        }
    }

    pub fn visible_sessions(&self) -> Vec<RunRecord> {
        self.sessions
            .iter()
            .filter(|rec| !rec.is_skip() && self.session_filters.includes(rec))
            .cloned()
            .collect()
    }

    pub fn spawn_agent_discovery(&mut self) {
        let tx = self.shell_tx.clone();
        let chosen: HashMap<Harness, Option<String>> = Harness::AGENTS
            .into_iter()
            .map(|h| (h, self.settings.chosen_executable(h).map(ToOwned::to_owned)))
            .collect();
        self.settings.loading_models = Harness::AGENTS.into_iter().collect();

        std::thread::spawn(move || {
            let installed = ExecutableDiscovery::installed_agents();
            let mut mcp_added = HashMap::new();
            let mut resolved_exes = HashMap::new();
            for h in Harness::AGENTS {
                let exe = chosen
                    .get(&h)
                    .and_then(Clone::clone)
                    .or_else(|| installed.get(&h).and_then(|v| v.first()).map(|i| i.path.clone()))
                    .unwrap_or_else(|| h.default_executable());
                mcp_added.insert(h, Path::new(&exe).is_file() && AgentAccess::is_added(h, &exe));
                resolved_exes.insert(h, exe);
            }
            let command_installed = AgentAccess::helper()
                .is_some_and(|hp| AgentAccess::command_installed(&AgentAccess::command_link(), &hp));
            let _ = tx.send(ShellEvent::DiscoveryFinished {
                installed,
                mcp_added,
                command_installed,
            });
            wake_app_event_loop();

            for (harness, exe) in resolved_exes {
                let tx_m = tx.clone();
                std::thread::spawn(move || {
                    let options = ModelCatalog::models(harness, &exe);
                    let _ = tx_m.send(ShellEvent::ModelCatalogLoaded { harness, options });
                    wake_app_event_loop();
                });
            }
        });
    }

    pub fn spawn_import_scan(&self) {
        let tx = self.shell_tx.clone();
        std::thread::spawn(move || {
            let scans = RoutineImport::scan_all();
            let _ = tx.send(ShellEvent::ImportScanFinished(scans));
            wake_app_event_loop();
        });
    }

    pub fn build_quick_reply_edits(settings: &SettingsStore) -> Vec<(Uuid, TextEditState, TextEditState)> {
        settings
            .quick_replies
            .iter()
            .map(|r| {
                (
                    r.id,
                    TextEditState::single_line(&r.title),
                    TextEditState::single_line(&r.message),
                )
            })
            .collect()
    }
}
