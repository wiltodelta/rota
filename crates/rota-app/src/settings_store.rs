//! Persistent user preferences (`PreferencesStore`) and model/effort formatting helpers.

use std::collections::{HashMap, HashSet};
use std::sync::Arc;

use rota_core::model::{Harness, QuickReply, Routine, RunOutcome, RunRecord};
use rota_core::runners::{AgentAccess, InstalledExecutable, ModelOption};
use rota_platform::{PreferencesStore, abbreviate_tilde, launch_at_login_enabled};
use rota_ui::{FontFamily, UiScales};

use crate::actions::SettingsPane;

pub const INTERFACE_SCALE_LEVELS: [f32; 6] = [0.8, 0.9, 1.0, 1.1, 1.25, 1.5];

pub struct SettingsStore {
    prefs: Arc<dyn PreferencesStore>,
    pub executables: HashMap<String, String>,
    pub interface_scale: f32,
    pub chat_font_mono: bool,
    pub chat_scale: f32,
    pub completion_notifications: bool,
    pub claude_interactive: bool,
    pub preferred_terminal: Option<String>,
    pub quick_replies: Vec<QuickReply>,
    pub sidebar_width: f32,
    pub sidebar_visible: bool,
    pub window_width: f32,
    pub window_height: f32,
    pub show_paused_in_schedule: bool,
    pub discussion_agent: Harness,
    pub discussion_models: HashMap<Harness, String>,
    pub discussion_efforts: HashMap<Harness, String>,
    pub last_settings_pane: SettingsPane,
    pub launch_at_login: bool,
    pub login_error: Option<String>,
    pub installed: HashMap<Harness, Vec<InstalledExecutable>>,
    pub models: HashMap<Harness, Vec<ModelOption>>,
    pub loading_models: HashSet<Harness>,
    pub mcp_added: HashMap<Harness, bool>,
    pub mcp_busy: Option<Harness>,
    pub mcp_error: Option<String>,
    pub command_installed: bool,
}

impl SettingsStore {
    pub fn load(prefs: Arc<dyn PreferencesStore>) -> Self {
        let executables = prefs.get_string_map("executables");
        let interface_scale = prefs
            .get_f64("interfaceScale")
            .map(|v| v as f32)
            .unwrap_or(1.0)
            .clamp(UiScales::MIN_INTERFACE, UiScales::MAX_INTERFACE);
        let chat_font_mono = prefs
            .get_string("chatFont")
            .is_some_and(|f| f.eq_ignore_ascii_case("mono") || f.contains("JetBrains"));
        let chat_scale = prefs
            .get_f64("chatScale")
            .map(|v| v as f32)
            .unwrap_or(1.0)
            .clamp(UiScales::MIN_CHAT, UiScales::MAX_CHAT);
        let completion_notifications = prefs
            .get_bool("completionNotifications")
            .or_else(|| prefs.get_bool("notifyOnSuccess"))
            .unwrap_or(false);
        let claude_interactive = prefs.get_bool("claudeInteractive").unwrap_or(true);
        let preferred_terminal = prefs
            .get_string("preferredTerminal")
            .or_else(|| prefs.get_string("terminalApp"))
            .filter(|s| !s.is_empty());
        let quick_replies = Self::load_quick_replies(&*prefs);
        let sidebar_width = prefs
            .get_f64("sidebarWidth")
            .map(|v| v as f32)
            .unwrap_or(272.0)
            .clamp(220.0, 360.0);
        let sidebar_visible = prefs.get_bool("sidebarVisible").unwrap_or(true);
        let window_width = prefs
            .get_f64("windowWidth")
            .map(|v| v as f32)
            .unwrap_or(1060.0)
            .clamp(820.0, 2560.0);
        let window_height = prefs
            .get_f64("windowHeight")
            .map(|v| v as f32)
            .unwrap_or(700.0)
            .clamp(520.0, 1600.0);
        let show_paused_in_schedule = prefs
            .get_bool("showPausedInSchedule")
            .or_else(|| prefs.get_bool("calendarShowPaused"))
            .unwrap_or(false);
        let discussion_agent = prefs
            .get_string("discussionAgent")
            .and_then(|s| Harness::parse(&s))
            .filter(|h| h.is_agent())
            .unwrap_or(Harness::Claude);
        let discussion_models = Self::by_harness(prefs.get_string_map("discussionModels"));
        let discussion_efforts = Self::by_harness(prefs.get_string_map("discussionEfforts"));
        let last_settings_pane = prefs
            .get_string("settingsPane")
            .and_then(|s| SettingsPane::parse(&s))
            .unwrap_or(SettingsPane::General);
        let command_installed = AgentAccess::helper()
            .is_some_and(|h| AgentAccess::command_installed(&AgentAccess::command_link(), &h));

        Self {
            prefs,
            executables,
            interface_scale,
            chat_font_mono,
            chat_scale,
            completion_notifications,
            claude_interactive,
            preferred_terminal,
            quick_replies,
            sidebar_width,
            sidebar_visible,
            window_width,
            window_height,
            show_paused_in_schedule,
            discussion_agent,
            discussion_models,
            discussion_efforts,
            last_settings_pane,
            launch_at_login: launch_at_login_enabled(),
            login_error: None,
            installed: HashMap::new(),
            models: HashMap::new(),
            loading_models: HashSet::new(),
            mcp_added: HashMap::new(),
            mcp_busy: None,
            mcp_error: None,
            command_installed,
        }
    }

    pub fn prefs(&self) -> &dyn PreferencesStore {
        &*self.prefs
    }

    pub fn chat_font_family(&self) -> FontFamily {
        if self.chat_font_mono {
            FontFamily::Mono
        } else {
            FontFamily::UiSans
        }
    }

    pub fn set_interface_scale(&mut self, scale: f32) {
        self.interface_scale = scale.clamp(UiScales::MIN_INTERFACE, UiScales::MAX_INTERFACE);
        self.prefs
            .set_f64("interfaceScale", f64::from(self.interface_scale));
    }

    pub fn step_interface_scale(&mut self, dir: i32) {
        let cur = INTERFACE_SCALE_LEVELS
            .iter()
            .enumerate()
            .min_by(|a, b| {
                (a.1 - self.interface_scale)
                    .abs()
                    .total_cmp(&(b.1 - self.interface_scale).abs())
            })
            .map_or(2, |(i, _)| i) as i32;
        let next = (cur + dir).clamp(0, (INTERFACE_SCALE_LEVELS.len() - 1) as i32) as usize;
        self.set_interface_scale(INTERFACE_SCALE_LEVELS[next]);
    }

    pub fn set_chat_font_mono(&mut self, mono: bool) {
        self.chat_font_mono = mono;
        self.prefs
            .set_string("chatFont", Some(if mono { "mono" } else { "sans" }));
    }

    pub fn set_chat_scale(&mut self, scale: f32) {
        let rounded = ((scale * 20.0).round() / 20.0).clamp(UiScales::MIN_CHAT, UiScales::MAX_CHAT);
        self.chat_scale = rounded;
        self.prefs.set_f64("chatScale", f64::from(rounded));
    }

    pub fn set_completion_notifications(&mut self, enabled: bool) {
        self.completion_notifications = enabled;
        self.prefs.set_bool("completionNotifications", enabled);
        self.prefs.set_bool("notifyOnSuccess", enabled);
    }

    pub fn set_claude_interactive(&mut self, interactive: bool) {
        self.claude_interactive = interactive;
        self.prefs.set_bool("claudeInteractive", interactive);
    }

    pub fn set_preferred_terminal(&mut self, term: Option<String>) {
        self.preferred_terminal = term.filter(|s| !s.is_empty());
        self.prefs
            .set_string("preferredTerminal", self.preferred_terminal.as_deref());
        self.prefs
            .set_string("terminalApp", self.preferred_terminal.as_deref());
    }

    pub fn set_sidebar_visible(&mut self, visible: bool) {
        self.sidebar_visible = visible;
        self.prefs.set_bool("sidebarVisible", visible);
    }

    pub fn set_sidebar_width(&mut self, width: f32) {
        self.sidebar_width = width.clamp(220.0, 360.0);
        self.prefs.set_f64("sidebarWidth", f64::from(self.sidebar_width));
    }

    pub fn set_window_size(&mut self, width: f32, height: f32) {
        let w = width.clamp(820.0, 2560.0);
        let h = height.clamp(520.0, 1600.0);
        if (self.window_width - w).abs() >= 1.0 || (self.window_height - h).abs() >= 1.0 {
            self.window_width = w;
            self.window_height = h;
            self.prefs.set_f64("windowWidth", f64::from(w));
            self.prefs.set_f64("windowHeight", f64::from(h));
        }
    }

    pub fn set_show_paused_in_schedule(&mut self, show: bool) {
        self.show_paused_in_schedule = show;
        self.prefs.set_bool("showPausedInSchedule", show);
        self.prefs.set_bool("calendarShowPaused", show);
    }

    pub fn set_last_settings_pane(&mut self, pane: SettingsPane) {
        self.last_settings_pane = pane;
        self.prefs.set_string("settingsPane", Some(pane.as_str()));
    }

    pub fn save_quick_replies(&mut self) {
        if let Ok(bytes) = serde_json::to_vec(&self.quick_replies) {
            self.prefs.set_bytes("quickReplies", &bytes);
        }
    }

    pub fn sendable_replies(&self) -> Vec<QuickReply> {
        self.quick_replies
            .iter()
            .filter(|r| !r.text().is_empty())
            .cloned()
            .collect()
    }

    pub fn missing_default_replies(&self) -> Vec<QuickReply> {
        QuickReply::defaults()
            .into_iter()
            .filter(|def| !self.quick_replies.iter().any(|r| r.id == def.id))
            .collect()
    }

    pub fn restore_default_replies(&mut self) {
        let present: HashSet<_> = self.quick_replies.iter().map(|r| r.id).collect();
        for (idx, reply) in QuickReply::defaults().into_iter().enumerate() {
            if !present.contains(&reply.id) {
                let pos = idx.min(self.quick_replies.len());
                self.quick_replies.insert(pos, reply);
            }
        }
        self.save_quick_replies();
    }

    pub fn chosen_executable(&self, harness: Harness) -> Option<&str> {
        self.executables
            .get(harness.as_str())
            .map(String::as_str)
            .filter(|s| !s.is_empty())
    }

    pub fn set_executable(&mut self, harness: Harness, path: Option<String>) {
        match path.filter(|s| !s.is_empty()) {
            Some(p) => {
                self.executables.insert(harness.as_str().to_string(), p);
            }
            None => {
                self.executables.remove(harness.as_str());
            }
        }
        self.prefs.set_string_map("executables", &self.executables);
    }

    pub fn effective_executable(&self, harness: Harness) -> String {
        if harness == Harness::Shell {
            return harness.default_executable();
        }
        if let Some(chosen) = self.chosen_executable(harness) {
            return chosen.to_string();
        }
        if let Some(first) = self.installed.get(&harness).and_then(|v| v.first()) {
            return first.path.clone();
        }
        harness.default_executable()
    }

    pub fn display_executable(&self, harness: Harness) -> String {
        abbreviate_tilde(&self.effective_executable(harness))
    }

    pub fn set_discussion_agent(&mut self, agent: Harness) {
        if agent.is_agent() {
            self.discussion_agent = agent;
            self.prefs.set_string("discussionAgent", Some(agent.as_str()));
        }
    }

    pub fn model_title(&self, id: &str, harness: Harness, fallback: Option<&str>) -> String {
        if let Some(opt) = self
            .models
            .get(&harness)
            .and_then(|list| list.iter().find(|o| o.matches(Some(id))))
        {
            return opt.title.clone();
        }
        if let Some(fb) = fallback
            && !fb.is_empty()
        {
            return fb.to_string();
        }
        if harness == Harness::Claude
            && let Some(rest) = id.strip_prefix("claude-")
        {
            let parts: Vec<&str> = rest.split('-').collect();
            if parts.len() >= 3
                && matches!(parts[0], "opus" | "sonnet" | "haiku" | "fable")
                && parts[1].chars().all(|c| c.is_ascii_digit())
                && parts[2].chars().all(|c| c.is_ascii_digit())
            {
                let fam = capitalize_ascii(parts[0]);
                return format!("{fam} {}.{}", parts[1], parts[2]);
            }
        }
        id.to_string()
    }

    pub fn session_model_label(&self, record: &RunRecord) -> String {
        let Some(id) = record.reported_model.as_deref().or(record.model.as_deref()) else {
            return if record.outcome == RunOutcome::Running {
                "Resolving model…".to_string()
            } else {
                record.harness.title().to_string()
            };
        };
        let title = self.model_title(id, record.harness, record.reported_model_title.as_deref());
        match record.reported_effort.as_deref().or(record.effort.as_deref()) {
            Some(eff) => format!("{title} · {}", effort_title(eff)),
            None => title,
        }
    }

    pub fn routine_config_label(&self, routine: &Routine) -> String {
        let mut parts = vec![routine.harness.title().to_string()];
        let model_id = routine.model.as_deref().or_else(|| {
            self.models
                .get(&routine.harness)
                .and_then(|opts| opts.iter().find(|o| o.is_default))
                .map(|o| o.id.as_str())
        });
        if let Some(id) = model_id {
            parts.push(self.model_title(id, routine.harness, None));
        }
        if let Some(eff) = &routine.effort {
            parts.push(effort_title(eff));
        }
        parts.join(" · ")
    }

    fn load_quick_replies(prefs: &dyn PreferencesStore) -> Vec<QuickReply> {
        if let Some(bytes) = prefs.get_bytes("quickReplies")
            && let Ok(parsed) = serde_json::from_slice::<Vec<QuickReply>>(&bytes)
        {
            return parsed;
        }
        if let Some(list) = prefs.get_string_list("quickReplies") {
            return list.into_iter().map(|s| QuickReply::new(s.clone(), s)).collect();
        }
        QuickReply::defaults()
    }

    fn by_harness(raw: HashMap<String, String>) -> HashMap<Harness, String> {
        raw.into_iter()
            .filter_map(|(k, v)| {
                let h = Harness::parse(&k)?;
                (h.is_agent() && !v.is_empty()).then_some((h, v))
            })
            .collect()
    }
}

impl SettingsStore {
    pub fn set_executable_overrides_on(&self, scheduler: &rota_core::Scheduler) {
        let map: std::collections::HashMap<Harness, String> = self
            .executables
            .iter()
            .filter_map(|(k, v)| {
                let h = Harness::parse(k)?;
                (!v.is_empty()).then_some((h, v.clone()))
            })
            .collect();
        scheduler.set_executable_overrides(map);
        scheduler.set_claude_interactive(self.claude_interactive);
        scheduler.set_completion_notifications(self.completion_notifications);
    }
}

pub fn effort_title(effort: &str) -> String {
    if effort == "none" {
        "No effort".to_string()
    } else {
        capitalize_ascii(effort)
    }
}

pub fn capitalize_ascii(s: &str) -> String {
    let mut chars = s.chars();
    match chars.next() {
        Some(c) => format!("{}{}", c.to_ascii_uppercase(), chars.as_str()),
        None => String::new(),
    }
}
