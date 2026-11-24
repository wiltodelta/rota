//! Settings actions, macOS menu bar / AppleEvent `ShellEvent` dispatch, and `MenuBarPanel` keyboard/click routing.

use std::path::Path;

use rota_core::model::QuickReply;
use rota_core::runners::AgentAccess;
use rota_platform::{
    ComputerUseAccess, NotificationUserEvent, SystemUpdater, installed_terminals, open_url_or_path,
    pick_files, set_launch_at_login,
};
use uuid::Uuid;

use crate::actions::{AppAction, PanelInput, ShellEvent, SidebarSelection};
use crate::app_state::AppState;
use crate::shell_macos::wake_app_event_loop;

impl AppState {
    pub(crate) fn execute_settings_and_panel_action(&mut self, action: AppAction) {
        match action {
            AppAction::DismissErrorBanner => {
                self.error_banner = None;
            }
            AppAction::CopyTextWithId { id, text } => {
                rota_platform::clipboard_set(&text);
                self.copied_feedback = Some((id, self.now_seconds));
            }
            AppAction::SetInterfaceScale(idx) => {
                if let Some(&s) = crate::settings_store::INTERFACE_SCALE_LEVELS.get(idx as usize) {
                    self.settings.set_interface_scale(s);
                }
            }
            AppAction::ToggleCompletionNotifications => {
                let next = !self.settings.completion_notifications;
                self.settings.set_completion_notifications(next);
                self.scheduler.set_completion_notifications(next);
            }
            AppAction::SetPreferredTerminal(opt) => self.settings.set_preferred_terminal(opt),
            AppAction::CyclePreferredTerminal => {
                let terms = installed_terminals();
                let cur = self
                    .settings
                    .preferred_terminal
                    .as_deref()
                    .and_then(|p| terms.iter().position(|t| t.bundle_id() == p));
                let next = match cur {
                    None => terms.first().map(|t| t.bundle_id().to_string()),
                    Some(i) if i + 1 < terms.len() => Some(terms[i + 1].bundle_id().to_string()),
                    Some(_) => None,
                };
                self.settings.set_preferred_terminal(next);
            }
            AppAction::ChooseCustomTerminal => {
                if let Some(f) = pick_files(false, Some("/Applications")).into_iter().next() {
                    self.settings
                        .set_preferred_terminal(Some(f.to_string_lossy().into_owned()));
                }
            }
            AppAction::ToggleLaunchAtLogin => {
                let next = !self.settings.launch_at_login;
                match set_launch_at_login(next) {
                    Ok(()) => {
                        self.settings.launch_at_login = next;
                        self.settings.login_error = None;
                    }
                    Err(e) => self.settings.login_error = Some(e),
                }
            }
            AppAction::ToggleAutoCheckUpdates => {
                SystemUpdater::set_automatically_checks(!SystemUpdater::automatically_checks());
            }
            AppAction::CheckForUpdatesNow => SystemUpdater::check_for_updates(),
            AppAction::SetChatFontMono(mono) => self.settings.set_chat_font_mono(mono),
            AppAction::SetChatScaleDirect(pct) => {
                self.settings.set_chat_scale(f32::from(pct) / 100.0);
            }
            AppAction::AdjustChatScale(dir) => {
                self.settings
                    .set_chat_scale(self.settings.chat_scale + (dir as f32) * 0.1);
            }
            AppAction::ResetChatScale => self.settings.set_chat_scale(1.0),
            AppAction::AddQuickReply => {
                self.settings.quick_replies.push(QuickReply::new("", ""));
                self.settings.save_quick_replies();
                self.quick_reply_edits = Self::build_quick_reply_edits(&self.settings);
            }
            AppAction::RemoveQuickReply(idx) => {
                if idx < self.settings.quick_replies.len() {
                    self.settings.quick_replies.remove(idx);
                    self.settings.save_quick_replies();
                    self.quick_reply_edits = Self::build_quick_reply_edits(&self.settings);
                }
            }
            AppAction::RestoreDefaultQuickReplies => {
                self.settings.restore_default_replies();
                self.quick_reply_edits = Self::build_quick_reply_edits(&self.settings);
            }
            AppAction::SetAgentExecutable { harness, path } => {
                self.settings.set_executable(harness, path);
                self.settings.set_executable_overrides_on(&self.scheduler);
                self.spawn_agent_discovery();
            }
            AppAction::ChooseAgentExecutable(h) => {
                if let Some(p) = pick_files(false, None).into_iter().next() {
                    self.settings
                        .set_executable(h, Some(p.to_string_lossy().into_owned()));
                    self.settings.set_executable_overrides_on(&self.scheduler);
                    self.spawn_agent_discovery();
                }
            }
            AppAction::ResetAgentExecutable(h) => {
                self.settings.set_executable(h, None);
                self.settings.set_executable_overrides_on(&self.scheduler);
                self.spawn_agent_discovery();
            }
            AppAction::ToggleClaudeInteractive => {
                let next = !self.settings.claude_interactive;
                self.settings.set_claude_interactive(next);
                self.scheduler.set_claude_interactive(next);
            }
            AppAction::RequestAccessibilityPermission => ComputerUseAccess::request_accessibility(),
            AppAction::RequestScreenRecordingPermission => ComputerUseAccess::request_screen_recording(),
            AppAction::InstallCliCommand => {
                if let Some(helper) = AgentAccess::helper() {
                    match AgentAccess::install_command(&AgentAccess::command_link(), &helper) {
                        Ok(()) => {
                            self.settings.command_installed = true;
                            self.settings.mcp_error = None;
                        }
                        Err(e) => self.settings.mcp_error = Some(e),
                    }
                }
            }
            AppAction::ToggleAgentMcp(h) => {
                if self.settings.mcp_busy.is_some() {
                    return;
                }
                let add = !self.settings.mcp_added.get(&h).copied().unwrap_or(false);
                if add
                    && !self.settings.command_installed
                    && let Some(helper) = AgentAccess::helper()
                    && let Err(e) = AgentAccess::install_command(&AgentAccess::command_link(), &helper)
                {
                    self.settings.mcp_error = Some(e);
                    return;
                }
                self.settings.mcp_busy = Some(h);
                let exe = self.settings.effective_executable(h);
                let cmd = AgentAccess::command_link().to_string_lossy().into_owned();
                let tx = self.shell_tx.clone();
                std::thread::spawn(move || {
                    let error = AgentAccess::change(h, add, &exe, &cmd);
                    let added = AgentAccess::is_added(h, &exe);
                    let _ = tx.send(ShellEvent::McpToggleFinished {
                        harness: h,
                        added,
                        error,
                    });
                    wake_app_event_loop();
                });
            }
            AppAction::PanelOpenMain => {
                self.panel_visible = false;
                self.main_window_visible = true;
            }
            AppAction::PanelSelectRoutine(rid) => {
                self.panel_visible = false;
                self.main_window_visible = true;
                let latest = self
                    .sessions
                    .iter()
                    .find(|s| s.routine_id == rid && !s.is_skip())
                    .map(|s| s.id);
                if let Some(sid) = latest {
                    self.execute_action(AppAction::SelectSession(sid));
                } else {
                    self.execute_action(AppAction::SelectRoutine(rid));
                }
            }
            AppAction::PanelToggleRunRoutine(rid) => {
                if self.scheduler.is_running(&rid) {
                    let _ = self.scheduler.stop_routine(&rid);
                } else {
                    let _ = self.scheduler.run_now(&rid);
                }
                self.sync_from_scheduler(true);
            }
            AppAction::PanelOpenSettings => {
                self.panel_visible = false;
                self.execute_action(AppAction::OpenSettings(None));
            }
            AppAction::PanelQuit => std::process::exit(0),
            _ => {}
        }
    }

    pub(crate) fn handle_shell_event(&mut self, ev: ShellEvent) {
        match ev {
            ShellEvent::ReopenMainWindow => {
                self.panel_visible = false;
                self.main_window_visible = true;
                if self.selection.is_none() && self.settings_pane.is_none() {
                    self.select_initial_destination();
                }
            }
            ShellEvent::HideMainWindow => {
                self.main_window_visible = false;
                self.settings_pane = None;
            }
            ShellEvent::OpenSettings(p) => self.execute_action(AppAction::OpenSettings(p)),
            ShellEvent::OpenNewRoutine => self.execute_action(AppAction::OpenNewRoutine),
            ShellEvent::OpenImportRoutines => self.execute_action(AppAction::OpenImportSheet),
            ShellEvent::ShowSchedule => self.execute_action(AppAction::ToggleSchedule),
            ShellEvent::ScheduleStep(w) => {
                if self.selection != Some(SidebarSelection::Schedule) {
                    self.execute_action(AppAction::ToggleSchedule);
                }
                self.execute_action(AppAction::ScheduleStepWeeks(w));
            }
            ShellEvent::ScheduleToday => {
                if self.selection != Some(SidebarSelection::Schedule) {
                    self.execute_action(AppAction::ToggleSchedule);
                }
                self.execute_action(AppAction::ScheduleToday);
            }
            ShellEvent::ToggleShowPaused => self.execute_action(AppAction::ToggleShowPausedInSchedule),
            ShellEvent::ToggleSidebar => self.execute_action(AppAction::ToggleSidebar),
            ShellEvent::EditCommand(key) => self.handle_menu_edit_key(key),
            ShellEvent::ZoomInterface(d) => self.settings.step_interface_scale(d),
            ShellEvent::ResetInterfaceZoom => self.settings.set_interface_scale(1.0),
            ShellEvent::ZoomChat(d) => self.execute_action(AppAction::AdjustChatScale(d)),
            ShellEvent::ResetChatZoom => self.execute_action(AppAction::ResetChatScale),
            ShellEvent::RunSelectedRoutine => {
                if let Some(r) = self.selected_routine().cloned() {
                    self.execute_action(AppAction::RunRoutineNow(r.id));
                }
            }
            ShellEvent::StopSelected => match &self.selection {
                Some(SidebarSelection::Session(sid)) => self.execute_action(AppAction::StopSession(*sid)),
                _ => {
                    if let Some(r) = self.selected_routine().cloned() {
                        self.execute_action(AppAction::StopRoutine(r.id));
                    }
                }
            },
            ShellEvent::EditSelectedRoutine => {
                if let Some(r) = self.selected_routine().cloned() {
                    self.execute_action(AppAction::EditRoutine(r.id));
                }
            }
            ShellEvent::ShowSelectedRoutine => {
                if let Some(r) = self.selected_routine().cloned() {
                    self.execute_action(AppAction::SelectRoutine(r.id));
                }
            }
            ShellEvent::OpenSelectedInTerminal => {
                if let Some(SidebarSelection::Session(sid)) = self.selection {
                    self.execute_action(AppAction::OpenInTerminal(sid));
                }
            }
            ShellEvent::RevealSelectedLog => {
                if let Some(SidebarSelection::Session(sid)) = self.selection
                    && let Some(rec) = self.scheduler.current_record(sid)
                    && let Some(log) = &rec.log_path
                    && let Some(parent) = Path::new(log).parent()
                {
                    open_url_or_path(&parent.to_string_lossy());
                }
            }
            ShellEvent::RevealSelectedQuestion => {
                if let Some(SidebarSelection::Session(sid)) = self.selection {
                    self.execute_action(AppAction::RevealQuestion(sid));
                }
            }
            ShellEvent::DismissSelectedAttention => {
                if let Some(SidebarSelection::Session(sid)) = self.selection {
                    self.execute_action(AppAction::DismissAttention(sid));
                }
            }
            ShellEvent::ToggleSelectedRead => {
                if let Some(SidebarSelection::Session(sid)) = self.selection {
                    self.execute_action(AppAction::ToggleMarkUnread(sid));
                }
            }
            ShellEvent::LoadSelectedEarlier => {
                if let Some(SidebarSelection::Session(sid)) = self.selection {
                    self.execute_action(AppAction::LoadEarlierMessages(sid));
                }
            }
            ShellEvent::DeleteSelectedSession => {
                if let Some(SidebarSelection::Session(sid)) = self.selection {
                    self.execute_action(AppAction::PromptDeleteSession(sid));
                }
            }
            ShellEvent::OpenHelp => open_url_or_path("https://github.com/wiltodelta/rota#readme"),
            ShellEvent::CheckForUpdates => SystemUpdater::check_for_updates(),
            ShellEvent::QuitRequested => std::process::exit(0),
            ShellEvent::TogglePanel => {
                self.panel_visible = !self.panel_visible;
                if self.panel_visible {
                    self.panel_highlighted = None;
                }
            }
            ShellEvent::PanelAction(pa) => self.handle_panel_input(pa),
            ShellEvent::Notification(nev) => match nev {
                NotificationUserEvent::OpenSession(s) => {
                    if let Ok(uuid) = Uuid::parse_str(&s) {
                        self.main_window_visible = true;
                        self.execute_action(AppAction::SelectSession(uuid));
                    }
                }
                NotificationUserEvent::OpenRoutine(rid) => {
                    self.main_window_visible = true;
                    self.execute_action(AppAction::SelectRoutine(rid));
                }
                NotificationUserEvent::ReplyToSession { session_id, text } => {
                    if let Ok(uuid) = Uuid::parse_str(&session_id) {
                        let _ = self.scheduler.send_message(uuid, &text, &[]);
                        self.sync_from_scheduler(true);
                    }
                }
            },
            ShellEvent::DiscoveryFinished {
                installed,
                mcp_added,
                command_installed,
            } => {
                self.settings.installed = installed;
                self.settings.mcp_added = mcp_added;
                self.settings.command_installed = command_installed;
            }
            ShellEvent::ModelCatalogLoaded { harness, options } => {
                self.settings.models.insert(harness, options);
                self.settings.loading_models.remove(&harness);
            }
            ShellEvent::ImportScanFinished(scans) => {
                if let Some(imp) = &mut self.import_modal {
                    imp.scans = Some(scans);
                }
            }
            ShellEvent::McpToggleFinished {
                harness,
                added,
                error,
            } => {
                self.settings.mcp_busy = None;
                self.settings.mcp_added.insert(harness, added);
                self.settings.mcp_error = error.map(|e| format!("{}: {e}", harness.title()));
            }
        }
    }

    fn handle_panel_input(&mut self, pa: PanelInput) {
        match pa {
            PanelInput::Hover(opt_id) => {
                if let Some(ref id) = opt_id
                    && let Some(rid) = id
                        .strip_prefix("panelRow-")
                        .or_else(|| id.strip_prefix("panelRun-"))
                {
                    self.panel_highlighted = Some(rid.to_string());
                }
                self.panel_hovered_id = opt_id;
            }
            PanelInput::MoveHighlight(dir) => {
                if self.routines.is_empty() {
                    return;
                }
                let next_idx = match &self.panel_highlighted {
                    None => {
                        if dir >= 0 {
                            0
                        } else {
                            self.routines.len() - 1
                        }
                    }
                    Some(cur) => {
                        let pos = self.routines.iter().position(|r| &r.id == cur).unwrap_or(0) as i32;
                        (pos + dir).rem_euclid(self.routines.len() as i32) as usize
                    }
                };
                self.panel_highlighted = Some(self.routines[next_idx].id.clone());
            }
            PanelInput::ActivateHighlighted => {
                if let Some(rid) = self.panel_highlighted.clone() {
                    self.execute_action(AppAction::PanelSelectRoutine(rid));
                }
            }
            PanelInput::RunHighlighted => {
                if let Some(rid) = self.panel_highlighted.clone()
                    && !self.scheduler.is_running(&rid)
                {
                    let _ = self.scheduler.run_now(&rid);
                    self.sync_from_scheduler(true);
                }
            }
            PanelInput::StopHighlighted => {
                if let Some(rid) = self.panel_highlighted.clone() {
                    let _ = self.scheduler.stop_routine(&rid);
                    self.sync_from_scheduler(true);
                }
            }
            PanelInput::ClosePanel => self.panel_visible = false,
            PanelInput::OpenMain => self.execute_action(AppAction::PanelOpenMain),
            PanelInput::OpenNew => {
                self.panel_visible = false;
                self.execute_action(AppAction::OpenNewRoutine);
            }
            PanelInput::OpenSchedule => {
                self.panel_visible = false;
                self.main_window_visible = true;
                if self.selection != Some(SidebarSelection::Schedule) {
                    self.execute_action(AppAction::ToggleSchedule);
                }
            }
            PanelInput::OpenRoutine(rid) => self.execute_action(AppAction::PanelSelectRoutine(rid)),
            PanelInput::OpenSession(sid) => {
                self.panel_visible = false;
                self.main_window_visible = true;
                self.execute_action(AppAction::SelectSession(sid));
            }
            PanelInput::ToggleRun(rid) => self.execute_action(AppAction::PanelToggleRunRoutine(rid)),
            PanelInput::OpenSettings => self.execute_action(AppAction::PanelOpenSettings),
            PanelInput::Quit => std::process::exit(0),
        }
    }
}
