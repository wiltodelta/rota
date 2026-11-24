//! Event routing: wheel scrolling, keyboard shortcuts, and Accessibility actions.

use rota_ui::{A11yEvent, EditKey, Modifiers, UiInputEvent};
use uuid::Uuid;

use crate::actions::{AppAction, FocusTarget, SettingsPane, SidebarSelection};
use crate::app_state::AppState;

impl AppState {
    pub fn process_frame_inputs(&mut self, events: &[UiInputEvent], a11y_events: &[A11yEvent], sf: f32) {
        self.process_frame_inputs_at(events, a11y_events, sf, 0.0);
    }

    pub fn process_frame_inputs_at(
        &mut self,
        events: &[UiInputEvent],
        a11y_events: &[A11yEvent],
        sf: f32,
        now_seconds: f64,
    ) {
        self.now_seconds = now_seconds;
        if self
            .copied_feedback
            .as_ref()
            .is_some_and(|(_, t)| now_seconds - *t >= 1.5)
        {
            self.copied_feedback = None;
        }
        for ev in events {
            self.handle_ui_event(ev, sf, now_seconds);
        }
        for ax in a11y_events {
            self.handle_a11y_event(ax);
        }
    }

    pub fn drain_shell_events(&mut self) -> bool {
        let mut dirty = self.sync_from_scheduler(false);
        while let Ok(ev) = self.shell_rx.try_recv() {
            dirty = true;
            self.handle_shell_event(ev);
        }
        dirty
    }

    fn handle_ui_event(&mut self, ev: &UiInputEvent, scale_factor: f32, now_seconds: f64) {
        match ev {
            UiInputEvent::Resized(sz) => {
                self.viewport_size = *sz;
                if sz.width >= 820.0 && sz.height >= 520.0 {
                    self.settings.set_window_size(sz.width, sz.height);
                }
            }
            UiInputEvent::PointerMoved(pt) => self.handle_pointer_moved(*pt, now_seconds),
            UiInputEvent::PointerDown {
                pos,
                button,
                click_count,
            } => self.handle_pointer_down_at(*pos, *button, *click_count, now_seconds),
            UiInputEvent::PointerUp { pos, button } => self.handle_pointer_up(*pos, *button),
            UiInputEvent::Wheel { delta, phase } => {
                let fallback_h = (self.viewport_size.height - 96.0).max(120.0);
                let rf_h = self.scroll_viewport_height("routineFormScroll", 400.0);
                let im_h = self.scroll_viewport_height("importResults", 340.0);
                if let Some(modal) = &mut self.routine_modal {
                    modal.scroll.handle_wheel_delta_with_phase(
                        *delta,
                        *phase,
                        scale_factor,
                        rf_h,
                        now_seconds,
                    );
                } else if let Some(modal) = &mut self.import_modal {
                    modal.scroll.handle_wheel_delta_with_phase(
                        *delta,
                        *phase,
                        scale_factor,
                        im_h,
                        now_seconds,
                    );
                } else if self.is_pointer_in_sidebar() {
                    let h = self.scroll_viewport_height("routineSidebar", fallback_h);
                    self.sidebar_scroll.handle_wheel_delta_with_phase(
                        *delta,
                        *phase,
                        scale_factor,
                        h,
                        now_seconds,
                    );
                } else if let Some(pane) = self.settings_pane {
                    let h =
                        self.scroll_viewport_height(&format!("settingsScroll-{}", pane.as_str()), fallback_h);
                    self.settings_scroll.handle_wheel_delta_with_phase(
                        *delta,
                        *phase,
                        scale_factor,
                        h,
                        now_seconds,
                    );
                } else {
                    match &self.selection {
                        Some(SidebarSelection::Session(sid)) => {
                            let h = self.scroll_viewport_height("chatTranscript", fallback_h);
                            if let Some(tr) = self.transcripts.get_mut(sid) {
                                tr.scroll.handle_wheel_delta_with_phase(
                                    *delta,
                                    *phase,
                                    scale_factor,
                                    h,
                                    now_seconds,
                                );
                            }
                        }
                        Some(SidebarSelection::Routine(_)) => {
                            let h = self.scroll_viewport_height("routineHistoryScroll", fallback_h);
                            self.routine_detail_scroll.handle_wheel_delta_with_phase(
                                *delta,
                                *phase,
                                scale_factor,
                                h,
                                now_seconds,
                            );
                        }
                        Some(SidebarSelection::Schedule) => {
                            let h = self.scroll_viewport_height("scheduleList", fallback_h);
                            self.schedule_state.scroll.handle_wheel_delta_with_phase(
                                *delta,
                                *phase,
                                scale_factor,
                                h,
                                now_seconds,
                            );
                        }
                        None => {}
                    }
                }
            }
            UiInputEvent::Key { key, modifiers } => {
                self.modifiers = *modifiers;
                self.last_caret_reset_time = now_seconds;
                self.handle_key(key.clone(), *modifiers);
            }
            UiInputEvent::ImePreedit(pre) => {
                self.ime_preedit = pre.clone();
                self.last_caret_reset_time = now_seconds;
            }
            UiInputEvent::FileHovered(h) => self.file_drop_hovered = *h,
            UiInputEvent::FileDropped(path) => self.handle_dropped_file(path.clone()),
            UiInputEvent::CloseRequested => {
                self.main_window_visible = false;
                self.settings_pane = None;
            }
            UiInputEvent::Focused(f) => {
                self.window_focused = *f;
                self.last_caret_reset_time = now_seconds;
            }
        }
    }

    fn is_pointer_in_sidebar(&self) -> bool {
        let Some(pt) = self.pointer_pos else {
            return false;
        };
        let Some(tree) = &self.last_tree else {
            return false;
        };
        self.sidebar_shown()
            && tree
                .bounds_by_id("routineSidebar")
                .is_some_and(|sb| sb.width > 0.0 && pt.x <= sb.max_x() + 12.0)
    }

    fn handle_a11y_event(&mut self, ev: &A11yEvent) {
        match ev {
            A11yEvent::Press(id) => {
                if let Some(act) = self.actions.resolve(*id).cloned() {
                    if !matches!(act, AppAction::OpenMenu(_)) {
                        self.open_menu = None;
                    }
                    self.execute_action(act);
                }
            }
            A11yEvent::SetSelected { id, action, selected } => {
                if !selected {
                    return;
                }
                if let Some(act_id) = action
                    && let Some(act) = self.actions.resolve(*act_id).cloned()
                {
                    self.execute_action(act);
                } else if let Some(rid) = id.strip_prefix("routineRow-") {
                    self.execute_action(AppAction::SelectRoutine(rid.to_string()));
                } else if let Some(sid_str) = id.strip_prefix("sessionRow-")
                    && let Ok(uuid) = Uuid::parse_str(sid_str)
                {
                    self.execute_action(AppAction::SelectSession(uuid));
                } else if let Some(pane_str) = id.strip_prefix("settingsPane-")
                    && let Some(pane) = SettingsPane::parse(pane_str)
                {
                    self.execute_action(AppAction::OpenSettings(Some(pane)));
                }
            }
            A11yEvent::SetFocused { id, focused, .. } => {
                if !focused {
                    return;
                }
                self.focus = match id.as_str() {
                    "routineSidebar" => Some(FocusTarget::Sidebar),
                    "composer" => Some(FocusTarget::Composer),
                    "chatTextScale" => Some(FocusTarget::ChatTextScale),
                    "routineSkill" => Some(FocusTarget::RoutineSkill),
                    "routineName" => Some(FocusTarget::RoutineName),
                    "routineFolder" => Some(FocusTarget::RoutineFolder),
                    "routineSchedule" => Some(FocusTarget::RoutineSchedule),
                    "routineRunLimit" => Some(FocusTarget::RoutineRunLimit),
                    "routinePrompt" => Some(FocusTarget::RoutinePrompt),
                    "importSearch" => Some(FocusTarget::ImportSearch),
                    other if other.starts_with("questionField-") => Some(FocusTarget::QuestionField(
                        other["questionField-".len()..].to_string(),
                    )),
                    other if other.starts_with("quickReplyTitle-") => other["quickReplyTitle-".len()..]
                        .parse::<usize>()
                        .ok()
                        .map(FocusTarget::QuickReplyTitle)
                        .or_else(|| Some(FocusTarget::Control(id.clone()))),
                    other if other.starts_with("quickReplyMsg-") => other["quickReplyMsg-".len()..]
                        .parse::<usize>()
                        .ok()
                        .map(FocusTarget::QuickReplyMessage)
                        .or_else(|| Some(FocusTarget::Control(id.clone()))),
                    "" => self.focus.clone(),
                    _ => Some(FocusTarget::Control(id.clone())),
                };
            }
            A11yEvent::SetValue { id, value, .. } => self.apply_set_value(id, value),
        }
    }

    pub(crate) fn handle_menu_edit_key(&mut self, key: EditKey) {
        self.handle_key(
            key,
            Modifiers {
                cmd: true,
                ..Default::default()
            },
        );
    }

    fn handle_key(&mut self, key: EditKey, mods: Modifiers) {
        if mods.cmd
            && let EditKey::Text(ref ch) = key
            && matches!(ch.as_str(), "=" | "+" | "-" | "0")
        {
            match (mods.alt, ch.as_str()) {
                (true, "=" | "+") => self.execute_action(AppAction::AdjustChatScale(1)),
                (true, "-") => self.execute_action(AppAction::AdjustChatScale(-1)),
                (true, "0") => self.execute_action(AppAction::ResetChatScale),
                (false, "=" | "+") => self.settings.step_interface_scale(1),
                (false, "-") => self.settings.step_interface_scale(-1),
                (false, "0") => self.settings.set_interface_scale(1.0),
                _ => {}
            }
            return;
        }
        if self.focus == Some(FocusTarget::ChatTextScale) && !mods.cmd {
            match key {
                EditKey::Left | EditKey::Down => {
                    self.settings.set_chat_scale(self.settings.chat_scale - 0.05);
                    return;
                }
                EditKey::Right | EditKey::Up => {
                    self.settings.set_chat_scale(self.settings.chat_scale + 0.05);
                    return;
                }
                _ => {}
            }
        }
        if key == EditKey::Escape {
            if self.open_menu.take().is_some() {
                return;
            }
            if self.confirm_delete_session.is_some() || self.confirm_delete_routine.is_some() {
                self.confirm_delete_session = None;
                self.confirm_delete_routine = None;
            } else if self.routine_modal.is_some() || self.import_modal.is_some() {
                self.routine_modal = None;
                self.import_modal = None;
            } else if self.restart_popover_open {
                self.restart_popover_open = false;
            } else if self.filter_menu_open {
                self.filter_menu_open = false;
            } else if self.settings_pane.is_some() {
                self.execute_action(AppAction::CloseSettings);
            } else if self.selection == Some(SidebarSelection::Schedule) {
                self.execute_action(AppAction::ToggleSchedule);
            } else {
                self.focus = Some(FocusTarget::Sidebar);
            }
            return;
        }

        if mods.cmd
            && let EditKey::Text(ref ch) = key
            && ch.len() == 1
            && let Some(digit) = ch.chars().next().and_then(|c| c.to_digit(10))
            && (1..=9).contains(&digit)
            && let Some(SidebarSelection::Session(sid)) = self.selection
        {
            let idx = (digit - 1) as usize;
            if mods.alt {
                self.execute_action(AppAction::SendQuickReply {
                    session_id: sid,
                    index: idx,
                });
                return;
            } else if let Some(rec) = self.scheduler.current_record(sid)
                && let Some(q) = rec.next_question()
                && let Some(tr) = self.transcripts.get(&sid)
                && let Some(draft) = tr.question_drafts.get(&q.id)
                && let Some(field) = draft.current_field()
                && let Some(opt) = field.options.get(idx)
            {
                self.execute_action(AppAction::SelectQuestionOption {
                    field_id: field.id.clone(),
                    option_id: opt.id.clone(),
                });
                return;
            }
        }

        if self.dispatch_key_to_focused_editor(&key, mods) {
            return;
        }

        if let Some(FocusTarget::Control(ref cid)) = self.focus.clone()
            && !mods.cmd
            && (key == EditKey::Return || matches!(key, EditKey::Text(ref s) if s == " "))
            && let Some(act_id) = self.actions.action_for_element(cid)
            && let Some(act) = self.actions.resolve(act_id).cloned()
        {
            self.execute_action(act);
            return;
        }

        if let Some(SidebarSelection::Session(sid)) = self.selection
            && let Some(tr) = self.transcripts.get_mut(&sid)
        {
            if key == EditKey::Copy && tr.selection.copy_to_clipboard(&tr.selectable_blocks) {
                return;
            }
            if key == EditKey::SelectAll {
                tr.selection.select_all(&tr.selectable_blocks);
                return;
            }
        }

        if self.focus == Some(FocusTarget::Sidebar) && !mods.cmd {
            match key {
                EditKey::Up => self.step_sidebar_selection(-1),
                EditKey::Down => self.step_sidebar_selection(1),
                EditKey::Return => {
                    if matches!(self.selection, Some(SidebarSelection::Session(_))) {
                        self.focus = Some(FocusTarget::Composer);
                    }
                }
                EditKey::PageUp => self.page_active_transcript(-1.0),
                EditKey::PageDown => self.page_active_transcript(1.0),
                EditKey::Text(ref s) if s == " " => {
                    self.page_active_transcript(if mods.shift { -1.0 } else { 1.0 });
                }
                EditKey::Backspace | EditKey::Delete => match self.selection.clone() {
                    Some(SidebarSelection::Session(sid)) => {
                        if self
                            .scheduler
                            .current_record(sid)
                            .is_some_and(|r| r.outcome != rota_core::model::RunOutcome::Running)
                        {
                            self.execute_action(AppAction::PromptDeleteSession(sid));
                        }
                    }
                    Some(SidebarSelection::Routine(rid)) => {
                        self.execute_action(AppAction::PromptDeleteRoutine(rid));
                    }
                    _ => {}
                },
                _ => {}
            }
        }
    }

    fn page_active_transcript(&mut self, dir: f32) {
        let Some(SidebarSelection::Session(sid)) = self.selection else {
            return;
        };
        let vp_h = self
            .last_tree
            .as_ref()
            .and_then(|t| t.bounds_by_id("chatTranscript"))
            .map_or(420.0, |b| b.height);
        let Some(tr) = self.transcripts.get_mut(&sid) else {
            return;
        };
        let max_scroll = (tr.scroll.total_height() - vp_h).max(0.0);
        let step = (vp_h * 0.85).max(80.0) * dir;
        let next = (tr.scroll.scroll_y + step).clamp(0.0, max_scroll);
        tr.scroll.scroll_y = next;
        tr.scroll.stick_to_bottom = dir > 0.0 && next >= max_scroll - 4.0;
    }
}
