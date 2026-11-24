//! Keyboard editing & Tab-focus cycling for focused `TextEditState` fields (`composer`, `routineForm`, `questionField`, `quickReplies`).

use rota_ui::{EditKey, EditOutcome, Modifiers, ReturnBehavior, TextEditState};

use crate::actions::{AppAction, FocusTarget, SchedulePreset, SidebarSelection};
use crate::app_state::AppState;

impl AppState {
    pub(crate) fn step_tab_focus(&mut self, backwards: bool) -> bool {
        if self.focus_order.is_empty() {
            return false;
        }
        let step = if backwards { -1 } else { 1 };
        let next_idx = if let Some(cur) = &self.focus
            && let Some(pos) = self.focus_order.iter().position(|t| t == cur)
        {
            (pos as i32 + step).rem_euclid(self.focus_order.len() as i32) as usize
        } else if backwards {
            self.focus_order.len() - 1
        } else {
            0
        };
        self.focus = Some(self.focus_order[next_idx].clone());
        true
    }

    pub(crate) fn dispatch_key_to_focused_editor(&mut self, key: &EditKey, mods: Modifiers) -> bool {
        if *key == EditKey::Tab && !mods.cmd && !mods.ctrl && !mods.alt {
            return self.step_tab_focus(mods.shift);
        }
        let Some(target) = self.focus.clone() else {
            return false;
        };
        match target {
            FocusTarget::Composer => {
                let Some(SidebarSelection::Session(sid)) = self.selection else {
                    return false;
                };
                let ed = self
                    .composer_drafts
                    .entry(sid)
                    .or_insert_with(|| TextEditState::multi_line("", ReturnBehavior::SubmitOnReturn));
                if *key == EditKey::Return && (mods.alt || mods.shift) {
                    ed.insert_str("\n");
                    return true;
                }
                if let EditOutcome::Submitted(_) = ed.handle_key(key.clone(), mods, None) {
                    self.execute_action(AppAction::SendComposer(sid));
                }
                true
            }
            FocusTarget::QuestionField(fid) => {
                let Some(SidebarSelection::Session(sid)) = self.selection else {
                    return false;
                };
                let Some(q) = self
                    .scheduler
                    .current_record(sid)
                    .and_then(|r| r.next_question().cloned())
                else {
                    return false;
                };
                let Some(tr) = self.transcripts.get_mut(&sid) else {
                    return false;
                };
                let Some(draft) = tr.question_drafts.get_mut(&q.id) else {
                    return false;
                };
                let cur = draft.other.get(&fid).cloned().unwrap_or_default();
                let ed = tr
                    .question_editors
                    .entry((q.id.clone(), fid.clone()))
                    .or_insert_with(|| TextEditState::multi_line(cur, ReturnBehavior::InsertNewline));
                ed.handle_key(key.clone(), mods, None);
                draft.set_other(&fid, ed.text().to_string());
                true
            }
            FocusTarget::RoutineSkill
            | FocusTarget::RoutineName
            | FocusTarget::RoutineFolder
            | FocusTarget::RoutineSchedule
            | FocusTarget::RoutineRunLimit
            | FocusTarget::RoutinePrompt => {
                if *key == EditKey::Tab {
                    let is_new = self.routine_modal.as_ref().is_none_or(|f| f.is_new);
                    let mut order = Vec::new();
                    if is_new {
                        order.push(FocusTarget::RoutineSkill);
                    }
                    order.push(FocusTarget::RoutineName);
                    order.push(FocusTarget::RoutineFolder);
                    order.push(FocusTarget::RoutinePrompt);
                    order.push(FocusTarget::RoutineSchedule);
                    if let Some(pos) = order.iter().position(|t| *t == target) {
                        let step = if mods.shift { -1 } else { 1 };
                        let next = (pos as i32 + step).rem_euclid(order.len() as i32) as usize;
                        self.focus = Some(order[next].clone());
                    }
                    return true;
                }
                let Some(form) = &mut self.routine_modal else {
                    return false;
                };
                match target {
                    FocusTarget::RoutineSkill => {
                        form.skill_input.handle_key(key.clone(), mods, None);
                        form.sync_generated_prompt();
                    }
                    FocusTarget::RoutineName => {
                        form.name_input.handle_key(key.clone(), mods, None);
                    }
                    FocusTarget::RoutineFolder => {
                        form.folder_input.handle_key(key.clone(), mods, None);
                        form.sync_generated_prompt();
                    }
                    FocusTarget::RoutineSchedule => {
                        form.preset = SchedulePreset::Custom;
                        form.schedule_input.handle_key(key.clone(), mods, None);
                    }
                    FocusTarget::RoutineRunLimit => {
                        form.run_limit_input.handle_key(key.clone(), mods, None);
                        if let Ok(n) = form.run_limit_input.text().trim().parse::<i64>() {
                            form.run_limit = Some(n.clamp(1, 9999));
                        }
                    }
                    FocusTarget::RoutinePrompt => {
                        form.prompt_input.handle_key(key.clone(), mods, None);
                    }
                    _ => {}
                }
                true
            }
            FocusTarget::ImportSearch => {
                if let Some(imp) = &mut self.import_modal {
                    imp.search_input.handle_key(key.clone(), mods, None);
                    return true;
                }
                false
            }
            FocusTarget::QuickReplyTitle(idx) | FocusTarget::QuickReplyMessage(idx) => {
                if *key == EditKey::Tab && !self.quick_reply_edits.is_empty() {
                    let total = self.quick_reply_edits.len() * 2;
                    let cur_slot = idx * 2 + usize::from(matches!(target, FocusTarget::QuickReplyMessage(_)));
                    let step = if mods.shift { -1 } else { 1 };
                    let next_slot = (cur_slot as i32 + step).rem_euclid(total as i32) as usize;
                    self.focus = Some(if next_slot.is_multiple_of(2) {
                        FocusTarget::QuickReplyTitle(next_slot / 2)
                    } else {
                        FocusTarget::QuickReplyMessage(next_slot / 2)
                    });
                    return true;
                }
                if let Some((_, t_ed, m_ed)) = self.quick_reply_edits.get_mut(idx) {
                    if matches!(target, FocusTarget::QuickReplyTitle(_)) {
                        t_ed.handle_key(key.clone(), mods, None);
                    } else {
                        m_ed.handle_key(key.clone(), mods, None);
                    }
                    if let Some(qr) = self.settings.quick_replies.get_mut(idx) {
                        qr.title = t_ed.text().to_string();
                        qr.message = m_ed.text().to_string();
                        self.settings.save_quick_replies();
                    }
                    return true;
                }
                false
            }
            _ => false,
        }
    }
}
