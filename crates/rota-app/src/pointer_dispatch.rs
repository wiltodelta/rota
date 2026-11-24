//! Pointer hit-testing, sidebar split-resizing, editor click-to-caret/drag-selection, tooltips, and native menu triggers.

use rota_ui::{MouseButton, Point, ReturnBehavior, TextEditState};
use uuid::Uuid;

use crate::actions::{FocusTarget, SidebarSelection};
use crate::app_state::AppState;
use crate::popup_macos::PopupRequest;

impl AppState {
    pub(crate) fn update_slider_from_pointer(&mut self, pt: Point) {
        if let Some(b) = self
            .last_tree
            .as_ref()
            .and_then(|t| t.bounds_by_id("chatTextScale"))
            && b.width > 4.0
        {
            let thumb_r = 8.0 * self.settings.interface_scale;
            let usable = (b.width - thumb_r * 2.0).max(4.0);
            let frac = ((pt.x - (b.x + thumb_r)) / usable).clamp(0.0, 1.0);
            let raw = 0.7 + frac * 1.3;
            let snapped = if (raw - 1.0).abs() <= 0.025 {
                1.0
            } else {
                (raw * 20.0).round() / 20.0
            };
            self.settings.set_chat_scale(snapped);
        }
    }

    pub(crate) fn handle_pointer_moved(&mut self, pt: Point, now_seconds: f64) {
        self.pointer_pos = Some(pt);
        if self.dragging_splitter {
            self.settings.set_sidebar_width((pt.x - 10.0).clamp(220.0, 360.0));
            return;
        }
        if self.dragging_slider {
            self.update_slider_from_pointer(pt);
            return;
        }
        if self.dragging_scrollbar.is_some() {
            self.update_scrollbar_drag(pt, now_seconds);
            return;
        }
        let hit = self.last_tree.as_ref().and_then(|t| t.hit_test(pt));
        self.hovered_id = hit.as_ref().and_then(|h| h.id.clone());

        if let Some(h) = &hit
            && let Some(tip) = &h.tooltip
            && !tip.is_empty()
        {
            let id = h.id.clone().unwrap_or_else(|| tip.clone());
            let keep_start = self
                .hover_tooltip
                .as_ref()
                .filter(|(prev_id, ..)| prev_id == &id)
                .map(|(_, _, _, t0)| *t0)
                .unwrap_or(now_seconds);
            self.hover_tooltip = Some((id, tip.clone(), h.bounds, keep_start));
        } else {
            self.hover_tooltip = None;
        }

        if self.dragging_editor {
            self.drag_focused_editor(pt);
            return;
        }
        if let Some(SidebarSelection::Session(sid)) = self.selection
            && let Some(tr) = self.transcripts.get_mut(&sid)
            && tr.selection.is_dragging
        {
            tr.selection.update_drag(pt, &tr.selectable_blocks);
        }
    }

    pub(crate) fn handle_pointer_down_at(
        &mut self,
        pos: Point,
        button: MouseButton,
        click_count: u8,
        now_seconds: f64,
    ) {
        self.pointer_pos = Some(pos);
        let is_context = button == MouseButton::Right || (button == MouseButton::Left && self.modifiers.ctrl);
        let hit = self.last_tree.as_ref().and_then(|t| t.hit_test(pos));

        if is_context {
            self.open_context_menu_at(pos, hit.and_then(|h| h.id));
            return;
        }
        if button != MouseButton::Left {
            return;
        }

        if let Some(h) = &hit
            && let Some(id) = h.id.as_deref()
        {
            if self.try_begin_scrollbar_drag(pos, Some(id), now_seconds) {
                return;
            }
            if id == "sidebarSplitter" {
                self.open_menu = None;
                self.dragging_splitter = true;
                return;
            }
            if id == "chatTextScale" {
                self.open_menu = None;
                self.focus = Some(FocusTarget::ChatTextScale);
                self.dragging_slider = true;
                self.update_slider_from_pointer(pos);
                return;
            }
            if let Some(target) = editor_focus_target(id) {
                self.open_menu = None;
                self.restart_popover_open = false;
                self.filter_menu_open = false;
                self.focus = Some(target);
                self.last_caret_reset_time = now_seconds;
                self.click_editor_at(id, pos, click_count, self.modifiers.shift);
                self.dragging_editor = true;
                return;
            }
        }

        if let Some(hit) = hit
            && let Some(act_id) = hit.action
            && let Some(action) = self.actions.resolve(act_id).cloned()
        {
            use crate::actions::AppAction;
            // Real macOS `NSMenu` popups and `NSTableView` row selections fire immediately on `MouseDown`.
            if let AppAction::OpenMenu(menu_id) = action {
                self.open_menu = None;
                self.pending_popup = Some(PopupRequest::DropdownMenu {
                    menu_id,
                    anchor: hit.bounds,
                });
                return;
            }
            let immediate_row = matches!(
                action,
                AppAction::SelectRoutine(_) | AppAction::SelectSession(_) | AppAction::OpenSettings(Some(_))
            );
            if immediate_row || self.open_menu.is_some() {
                let keep_menu = matches!(action, AppAction::OpenMenu(_));
                if !keep_menu {
                    self.open_menu = None;
                }
                self.restart_popover_open = false;
                self.filter_menu_open = false;
                self.execute_action(action);
                return;
            }
            // Standard macOS `NSButton` / `NSSwitch` semantics: depress on `MouseDown`, fire on `MouseUp` inside bounds.
            self.pressed_id = hit.id;
            self.pressed_action = Some(act_id);
            return;
        }

        if self.open_menu.take().is_some() {
            return;
        }
        self.restart_popover_open = false;
        self.filter_menu_open = false;
        let modal_open = self.routine_modal.is_some()
            || self.import_modal.is_some()
            || self.confirm_delete_session.is_some()
            || self.confirm_delete_routine.is_some();
        if !modal_open && pos.y <= 50.0 {
            self.pending_window_drag = true;
            return;
        }
        if !modal_open
            && self.settings_pane.is_none()
            && let Some(SidebarSelection::Session(sid)) = self.selection
            && let Some(tr) = self.transcripts.get_mut(&sid)
        {
            tr.selection
                .begin_click_or_drag(pos, click_count, &tr.selectable_blocks, self.modifiers.shift);
        }
    }

    pub(crate) fn handle_pointer_up(&mut self, pos: Point, button: MouseButton) {
        self.dragging_splitter = false;
        self.dragging_editor = false;
        self.dragging_slider = false;
        self.dragging_scrollbar = None;
        if let Some(SidebarSelection::Session(sid)) = self.selection
            && let Some(tr) = self.transcripts.get_mut(&sid)
        {
            tr.selection.end_drag();
        }
        if button != MouseButton::Left {
            self.pressed_id = None;
            self.pressed_action = None;
            return;
        }
        let pressed_id = self.pressed_id.take();
        let pressed_act = self.pressed_action.take();
        if let Some(act_id) = pressed_act {
            let hit = self.last_tree.as_ref().and_then(|t| t.hit_test(pos));
            let released_inside = match (&pressed_id, hit.as_ref()) {
                (Some(pid), Some(h)) => h.id.as_deref() == Some(pid.as_str()) || h.action == Some(act_id),
                (None, Some(h)) => h.action == Some(act_id),
                _ => false,
            };
            let current_act_id = pressed_id
                .as_deref()
                .and_then(|pid| self.actions.action_for_element(pid))
                .or_else(|| hit.as_ref().and_then(|h| h.action))
                .unwrap_or(act_id);
            if released_inside && let Some(action) = self.actions.resolve(current_act_id).cloned() {
                self.open_menu = None;
                self.restart_popover_open = false;
                self.filter_menu_open = false;
                self.execute_action(action);
            }
        }
    }

    fn open_context_menu_at(&mut self, pos: Point, hit_id: Option<String>) {
        if let Some(id) = hit_id.as_deref() {
            if let Some(rid) = id.strip_prefix("routineRow-") {
                self.pending_popup = Some(PopupRequest::RoutineContext {
                    rid: rid.to_string(),
                    pt: pos,
                });
                return;
            }
            if let Some(sid_str) = id.strip_prefix("sessionRow-")
                && let Ok(sid) = Uuid::parse_str(sid_str)
            {
                self.pending_popup = Some(PopupRequest::SessionContext { sid, pt: pos });
                return;
            }
            if let Some(target) = editor_focus_target(id) {
                self.focus = Some(target);
                self.pending_popup = Some(PopupRequest::EditorContext { pt: pos });
                return;
            }
        }
        if let Some(SidebarSelection::Session(sid)) = self.selection
            && self
                .last_tree
                .as_ref()
                .and_then(|t| t.bounds_by_id("chatTranscript"))
                .is_some_and(|b| b.contains(pos))
        {
            self.pending_popup = Some(PopupRequest::TranscriptContext { sid, pt: pos });
        }
    }

    fn click_editor_at(&mut self, id: &str, pos: Point, click_count: u8, shift: bool) {
        let text_id = format!("{id}-text");
        let Some((bounds, shaped)) = self
            .last_tree
            .as_ref()
            .and_then(|t| t.shaped_text_by_id(&text_id).map(|(b, s)| (b, s.clone())))
        else {
            return;
        };
        let local = Point::new((pos.x - bounds.x).max(0.0), (pos.y - bounds.y).max(0.0));
        self.with_editor_mut(id, |ed| ed.pointer_down(local, click_count, shift, &shaped));
    }

    fn drag_focused_editor(&mut self, pos: Point) {
        let Some(id) = self.focus.as_ref().and_then(editor_id_for_focus) else {
            return;
        };
        let text_id = format!("{id}-text");
        let Some((bounds, shaped)) = self
            .last_tree
            .as_ref()
            .and_then(|t| t.shaped_text_by_id(&text_id).map(|(b, s)| (b, s.clone())))
        else {
            return;
        };
        let local = Point::new((pos.x - bounds.x).max(0.0), (pos.y - bounds.y).max(0.0));
        self.with_editor_mut(&id, |ed| ed.pointer_drag(local, &shaped));
    }

    pub(crate) fn ensure_focused_editor_visible(&mut self, tree: &rota_ui::ComputedUiTree) {
        let Some(id) = self.focus.as_ref().and_then(editor_id_for_focus) else {
            return;
        };
        let text_id = format!("{id}-text");
        let Some(box_bounds) = tree.bounds_by_id(&id) else {
            return;
        };
        let Some((_, shaped)) = tree.shaped_text_by_id(&text_id).map(|(b, s)| (b, s.clone())) else {
            return;
        };
        let inner = rota_ui::Size::new((box_bounds.width - 20.0).max(24.0), box_bounds.height.max(20.0));
        self.with_editor_mut(&id, |ed| ed.ensure_cursor_visible(&shaped, inner));
    }

    fn with_editor_mut(&mut self, id: &str, f: impl FnOnce(&mut TextEditState)) {
        if id == "composer"
            && let Some(SidebarSelection::Session(sid)) = self.selection
        {
            let ed = self
                .composer_drafts
                .entry(sid)
                .or_insert_with(|| TextEditState::multi_line("", ReturnBehavior::SubmitOnReturn));
            f(ed);
            return;
        }
        if let Some(form) = &mut self.routine_modal {
            match id {
                "routineSkill" => f(&mut form.skill_input),
                "routineName" => f(&mut form.name_input),
                "routineFolder" => f(&mut form.folder_input),
                "routineSchedule" => f(&mut form.schedule_input),
                "routineRunLimit" => f(&mut form.run_limit_input),
                "routinePrompt" => f(&mut form.prompt_input),
                _ => {}
            }
            return;
        }
        if id == "importSearch"
            && let Some(imp) = &mut self.import_modal
        {
            f(&mut imp.search_input);
            return;
        }
        if let Some(fid) = id.strip_prefix("questionField-")
            && let Some(SidebarSelection::Session(sid)) = self.selection
            && let Some(qid) = self
                .scheduler
                .current_record(sid)
                .and_then(|r| r.next_question().map(|q| q.id.clone()))
            && let Some(tr) = self.transcripts.get_mut(&sid)
        {
            let cur = tr
                .question_drafts
                .get(&qid)
                .and_then(|d| d.other.get(fid).cloned())
                .unwrap_or_default();
            let ed = tr
                .question_editors
                .entry((qid, fid.to_string()))
                .or_insert_with(|| TextEditState::multi_line(cur, ReturnBehavior::InsertNewline));
            f(ed);
            return;
        }
        if let Some(idx_str) = id.strip_prefix("quickReplyTitle-")
            && let Ok(idx) = idx_str.parse::<usize>()
            && let Some((_, t_ed, _)) = self.quick_reply_edits.get_mut(idx)
        {
            f(t_ed);
            return;
        }
        if let Some(idx_str) = id.strip_prefix("quickReplyMsg-")
            && let Ok(idx) = idx_str.parse::<usize>()
            && let Some((_, _, m_ed)) = self.quick_reply_edits.get_mut(idx)
        {
            f(m_ed);
        }
    }

    pub(crate) fn apply_set_value(&mut self, id: &str, value: &str) {
        use crate::actions::SchedulePreset;
        if id == "chatTextScale" {
            if let Ok(v) = value.trim().parse::<f32>() {
                self.settings.set_chat_scale(v);
            }
            return;
        }
        if id == "composer"
            && let Some(SidebarSelection::Session(sid)) = self.selection
        {
            self.composer_drafts
                .entry(sid)
                .or_insert_with(|| TextEditState::multi_line("", ReturnBehavior::SubmitOnReturn))
                .set_text(value);
            return;
        }
        if let Some(fid) = id.strip_prefix("questionField-")
            && let Some(SidebarSelection::Session(sid)) = self.selection
            && let Some(rec) = self.scheduler.current_record(sid)
            && let Some(q) = rec.next_question()
            && let Some(tr) = self.transcripts.get_mut(&sid)
            && let Some(draft) = tr.question_drafts.get_mut(&q.id)
        {
            draft.set_other(fid, value);
            tr.question_editors
                .entry((q.id.clone(), fid.to_string()))
                .or_insert_with(|| TextEditState::multi_line(value, ReturnBehavior::InsertNewline))
                .set_text(value);
            return;
        }
        if let Some(idx_str) = id
            .strip_prefix("quickReplyTitle-")
            .or_else(|| id.strip_prefix("quickReplyMsg-"))
            && let Ok(idx) = idx_str.parse::<usize>()
            && let Some((_, t_ed, m_ed)) = self.quick_reply_edits.get_mut(idx)
        {
            if id.starts_with("quickReplyTitle-") {
                t_ed.set_text(value);
            } else {
                m_ed.set_text(value);
            }
            if let Some(qr) = self.settings.quick_replies.get_mut(idx) {
                qr.title = t_ed.text().to_string();
                qr.message = m_ed.text().to_string();
                self.settings.save_quick_replies();
            }
            return;
        }
        if let Some(form) = &mut self.routine_modal {
            match id {
                "routineSkill" => {
                    form.skill_input.set_text(value);
                    form.sync_generated_prompt();
                }
                "routineName" => form.name_input.set_text(value),
                "routineFolder" => {
                    form.folder_input.set_text(value);
                    form.sync_generated_prompt();
                }
                "routineSchedule" => {
                    form.preset = SchedulePreset::Custom;
                    form.schedule_input.set_text(value);
                }
                "routineRunLimit" => {
                    form.run_limit_input.set_text(value.trim());
                    if let Ok(n) = value.trim().parse::<i64>() {
                        form.run_limit = Some(n.clamp(1, 9999));
                    }
                }
                "routinePrompt" => form.prompt_input.set_text(value),
                _ => {}
            }
        }
        if id == "importSearch"
            && let Some(imp) = &mut self.import_modal
        {
            imp.search_input.set_text(value);
        }
    }
}

fn editor_focus_target(id: &str) -> Option<FocusTarget> {
    match id {
        "composer" => Some(FocusTarget::Composer),
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
            .map(FocusTarget::QuickReplyTitle),
        other if other.starts_with("quickReplyMsg-") => other["quickReplyMsg-".len()..]
            .parse::<usize>()
            .ok()
            .map(FocusTarget::QuickReplyMessage),
        _ => None,
    }
}

fn editor_id_for_focus(focus: &FocusTarget) -> Option<String> {
    match focus {
        FocusTarget::Composer => Some("composer".to_string()),
        FocusTarget::RoutineSkill => Some("routineSkill".to_string()),
        FocusTarget::RoutineName => Some("routineName".to_string()),
        FocusTarget::RoutineFolder => Some("routineFolder".to_string()),
        FocusTarget::RoutineSchedule => Some("routineSchedule".to_string()),
        FocusTarget::RoutineRunLimit => Some("routineRunLimit".to_string()),
        FocusTarget::RoutinePrompt => Some("routinePrompt".to_string()),
        FocusTarget::ImportSearch => Some("importSearch".to_string()),
        FocusTarget::QuestionField(fid) => Some(format!("questionField-{fid}")),
        FocusTarget::QuickReplyTitle(i) => Some(format!("quickReplyTitle-{i}")),
        FocusTarget::QuickReplyMessage(i) => Some(format!("quickReplyMsg-{i}")),
        _ => None,
    }
}
