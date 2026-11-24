//! Core `AppAction` execution for navigation, sessions, questions, and composer.

use std::path::Path;

use rota_core::model::{ChatMessage, Harness, QuestionAnswer, QuestionFieldKind, RunOutcome, SessionFilters};
use rota_core::storage::ChatAttachmentStore;
use rota_core::transcript::Outgoing;
use rota_platform::{clipboard_set, open_url_or_path, pick_files};
use uuid::Uuid;

use crate::actions::{AppAction, FocusTarget, SettingsPane, SidebarSelection};
use crate::app_state::AppState;
use crate::form_state::{ImportSheetState, RoutineFormState};

impl AppState {
    pub fn execute_action(&mut self, action: AppAction) {
        match action {
            AppAction::Noop => {}
            AppAction::ToggleSidebar => {
                if self.settings_pane.is_none() {
                    self.settings.set_sidebar_visible(!self.settings.sidebar_visible);
                }
            }
            AppAction::ToggleSchedule => {
                if self.routines.is_empty() {
                    return;
                }
                self.settings_pane = None;
                if self.selection == Some(SidebarSelection::Schedule) {
                    self.selection = self.selection_before_schedule.take();
                    if self.selection.is_none() {
                        self.select_initial_destination();
                    }
                } else {
                    self.selection_before_schedule = self.selection.take();
                    self.selection = Some(SidebarSelection::Schedule);
                }
            }
            AppAction::OpenNewRoutine => {
                self.error_banner = None;
                self.main_window_visible = true;
                self.routine_modal = Some(RoutineFormState::new_default());
                self.focus = Some(FocusTarget::RoutineSkill);
            }
            AppAction::OpenImportSheet => {
                self.main_window_visible = true;
                self.import_modal = Some(ImportSheetState::new());
                self.focus = Some(FocusTarget::ImportSearch);
                self.spawn_import_scan();
            }
            AppAction::OpenSettings(opt_pane) => {
                self.main_window_visible = true;
                if self.settings_pane.is_none() {
                    self.selection_before_settings = self.selection.clone();
                }
                let pane = opt_pane.unwrap_or(self.settings.last_settings_pane);
                self.settings_pane = Some(pane);
                self.settings.set_last_settings_pane(pane);
                self.settings_scroll.scroll_y = 0.0;
                if pane == SettingsPane::Agents && self.settings.installed.is_empty() {
                    self.spawn_agent_discovery();
                }
            }
            AppAction::CloseSettings => {
                if self.settings_pane.take().is_some() {
                    if let Some(prev) = self.selection_before_settings.take() {
                        self.selection = Some(prev);
                    } else if self.selection.is_none() {
                        self.select_initial_destination();
                    }
                }
            }
            AppAction::SelectRoutine(rid) => {
                self.error_banner = None;
                self.settings_pane = None;
                self.restart_popover_open = false;
                self.selection = Some(SidebarSelection::Routine(rid));
                self.routine_detail_scroll.scroll_y = 0.0;
            }
            AppAction::SelectSession(sid) => {
                self.error_banner = None;
                self.settings_pane = None;
                self.restart_popover_open = false;
                self.selection = Some(SidebarSelection::Session(sid));
                self.refresh_session_transcript(sid, false);
                self.sync_from_scheduler(true);
            }
            AppAction::ToggleFilterMenu => {
                self.filter_menu_open = !self.filter_menu_open;
            }
            AppAction::OpenMenu(menu_id) => {
                let anchor_id = menu_id.anchor_element_id();
                let anchor = self
                    .last_tree
                    .as_ref()
                    .and_then(|t| t.bounds_by_id(&anchor_id))
                    .unwrap_or_else(|| rota_ui::Rect::new(24.0, 56.0, 160.0, 30.0));
                if self.open_menu.as_ref().is_some_and(|(m, _)| m == &menu_id) {
                    self.open_menu = None;
                } else {
                    self.open_menu = Some((menu_id, anchor));
                }
            }
            AppAction::CloseMenu => {
                self.open_menu = None;
            }
            AppAction::ToggleSessionFilter(f) => {
                self.session_filters = self.session_filters.toggling(f);
                self.session_filters.persist(self.settings.prefs());
            }
            AppAction::ResetSessionFilters => {
                self.session_filters = SessionFilters::default();
                self.session_filters.persist(self.settings.prefs());
                self.filter_menu_open = false;
            }
            AppAction::FocusField(target) => self.focus = Some(target),
            AppAction::ShowSessionRoutine(rid) => self.execute_action(AppAction::SelectRoutine(rid)),
            AppAction::OpenInTerminal(sid) => {
                if let Err(e) = self
                    .scheduler
                    .open_in_terminal(sid, self.settings.preferred_terminal.as_deref())
                {
                    self.error_banner = Some(e);
                }
            }
            AppAction::RevealSessionLog(sid) => {
                if let Some(rec) = self.scheduler.current_record(sid)
                    && let Some(log) = &rec.log_path
                    && let Some(parent) = Path::new(log).parent()
                {
                    open_url_or_path(&parent.to_string_lossy());
                }
            }
            AppAction::ToggleRestartPopover => self.restart_popover_open = !self.restart_popover_open,
            AppAction::RestartSessionWith { session_id, harness } => {
                self.restart_popover_open = false;
                self.open_menu = None;
                match self.scheduler.restart_session(session_id, harness, None, None) {
                    Ok(next) => {
                        self.sync_from_scheduler(true);
                        self.execute_action(AppAction::SelectSession(next.id));
                    }
                    Err(e) => self.error_banner = Some(e),
                }
            }
            AppAction::SetSessionModel { session_id, model } => {
                if let Some(rec) = self.scheduler.current_record(session_id) {
                    let (_, efforts) = crate::views::menu_overlay::model_efforts_for(
                        &self.settings,
                        rec.harness,
                        model.as_deref(),
                    );
                    let kept_effort = rec
                        .effort
                        .filter(|e| efforts.is_empty() || efforts.iter().any(|x| x == e));
                    let _ = self.scheduler.configure_session(session_id, model, kept_effort);
                    self.sync_from_scheduler(true);
                }
            }
            AppAction::SetSessionEffort { session_id, effort } => {
                if let Some(rec) = self.scheduler.current_record(session_id) {
                    let _ = self.scheduler.configure_session(session_id, rec.model, effort);
                    self.sync_from_scheduler(true);
                }
            }
            AppAction::ToggleMarkUnread(sid) => {
                if let Some(rec) = self.scheduler.current_record(sid) {
                    if rec.is_unread() {
                        let _ = self.scheduler.mark_read(sid);
                    } else {
                        let _ = self.scheduler.mark_unread(sid);
                        if let Some(tr) = self.transcripts.get_mut(&sid) {
                            tr.last_marked_read = true;
                        }
                    }
                    self.sync_from_scheduler(true);
                }
            }
            AppAction::PromptDeleteSession(sid) => {
                self.confirm_delete_session = self.scheduler.current_record(sid);
            }
            AppAction::ConfirmDeleteSession => {
                if let Some(rec) = self.confirm_delete_session.take() {
                    let _ = self.scheduler.delete_session(rec.id);
                    self.transcripts.remove(&rec.id);
                    self.composer_drafts.remove(&rec.id);
                    self.composer_attachments.remove(&rec.id);
                    self.sync_from_scheduler(true);
                    if self.selection == Some(SidebarSelection::Session(rec.id)) {
                        self.selection = Some(SidebarSelection::Routine(rec.routine_id));
                    }
                }
            }
            AppAction::CancelDeleteModal | AppAction::CloseModal => {
                self.confirm_delete_session = None;
                self.confirm_delete_routine = None;
                self.routine_modal = None;
                self.import_modal = None;
            }
            AppAction::StopSession(sid) => {
                let _ = self.scheduler.stop_session(sid);
                self.sync_from_scheduler(true);
            }
            AppAction::DismissAttention(sid) => {
                let _ = self.scheduler.dismiss_attention(sid);
                self.sync_from_scheduler(true);
            }
            AppAction::LoadEarlierMessages(sid) => self.refresh_session_transcript(sid, true),
            AppAction::ScrollToLatest(sid) | AppAction::RevealQuestion(sid) => {
                let vp_h = self.scroll_viewport_height("chatTranscript", 400.0);
                if let Some(tr) = self.transcripts.get_mut(&sid) {
                    tr.scroll.physics = Default::default();
                    tr.scroll.scroll_to_bottom(vp_h, false);
                }
            }
            AppAction::ToggleTranscriptDisclosure { session_id, item_id } => {
                if let Some(tr) = self.transcripts.get_mut(&session_id)
                    && !tr.expanded_items.insert(item_id)
                {
                    tr.expanded_items.remove(&item_id);
                }
            }
            AppAction::CopyText(text) => clipboard_set(&text),
            AppAction::OpenUrlOrPath(target) => open_url_or_path(&target),
            other => self.execute_secondary_action(other),
        }
    }

    fn execute_secondary_action(&mut self, action: AppAction) {
        match action {
            AppAction::ToggleQuestionContext(sid) => {
                if let Some(tr) = self.transcripts.get_mut(&sid) {
                    tr.question_context_expanded = !tr.question_context_expanded;
                }
            }
            AppAction::SelectQuestionOption { field_id, option_id } => {
                if let Some(SidebarSelection::Session(sid)) = self.selection
                    && let Some(rec) = self.scheduler.current_record(sid)
                    && let Some(q) = rec.next_question()
                    && let Some(tr) = self.transcripts.get_mut(&sid)
                    && let Some(draft) = tr.question_drafts.get_mut(&q.id)
                    && let Some(field) = q.fields.iter().find(|f| f.id == field_id)
                {
                    if field.kind == QuestionFieldKind::Multiple {
                        let list = draft.values.entry(field_id).or_default();
                        if let Some(pos) = list.iter().position(|x| x == &option_id) {
                            list.remove(pos);
                        } else {
                            list.push(option_id);
                        }
                    } else {
                        draft.select_other(false, field);
                        draft.values.insert(field_id, vec![option_id]);
                    }
                }
            }
            AppAction::SelectQuestionOther { field_id } => {
                if let Some(SidebarSelection::Session(sid)) = self.selection
                    && let Some(rec) = self.scheduler.current_record(sid)
                    && let Some(q) = rec.next_question()
                    && let Some(tr) = self.transcripts.get_mut(&sid)
                    && let Some(draft) = tr.question_drafts.get_mut(&q.id)
                    && let Some(field) = q.fields.iter().find(|f| f.id == field_id)
                {
                    let next = !draft.custom_fields.contains(&field_id);
                    draft.select_other(next, field);
                    if next {
                        self.focus = Some(FocusTarget::QuestionField(field_id));
                    }
                }
            }
            AppAction::QuestionPrev => self.step_question(false),
            AppAction::QuestionNext => self.step_question(true),
            AppAction::QuestionSubmit(act_name) => {
                if let Some(SidebarSelection::Session(sid)) = self.selection
                    && let Some(rec) = self.scheduler.current_record(sid)
                    && let Some(q) = rec.next_question().cloned()
                    && let Some(tr) = self.transcripts.get_mut(&sid)
                    && let Some(draft) = tr.question_drafts.get_mut(&q.id)
                {
                    let sched = self.scheduler.clone();
                    let qid = q.id.clone();
                    draft.send(&act_name, |ans: QuestionAnswer| {
                        sched.answer_question(sid, &qid, ans).map(|_| ())
                    });
                    self.sync_from_scheduler(true);
                    self.refresh_session_transcript(sid, false);
                }
            }
            AppAction::AttachFiles(sid) => {
                let Some(rec) = self.scheduler.current_record(sid) else {
                    return;
                };
                let picked = pick_files(true, None);
                if !picked.is_empty()
                    && let Some(log) = &rec.log_path
                {
                    match ChatAttachmentStore::new(Path::new(log)).stage(&picked) {
                        Ok(staged) => {
                            self.composer_attachments.entry(sid).or_default().extend(staged);
                            self.composer_error = None;
                        }
                        Err(e) => self.composer_error = Some(e.to_string()),
                    }
                }
            }
            AppAction::RemoveAttachment { session_id, index } => {
                if let Some(list) = self.composer_attachments.get_mut(&session_id)
                    && index < list.len()
                {
                    let removed = list.remove(index);
                    if let Some(rec) = self.scheduler.current_record(session_id)
                        && let Some(log) = &rec.log_path
                    {
                        let _ = ChatAttachmentStore::new(Path::new(log)).discard(&removed);
                    }
                }
            }
            AppAction::SendQuickReply { session_id, index } => {
                let replies = self.settings.sendable_replies();
                if let Some(reply) = replies.get(index) {
                    let text = reply.text().to_string();
                    match self.scheduler.send_message(session_id, &text, &[]) {
                        Ok(_) => {
                            if let Some(tr) = self.transcripts.get_mut(&session_id) {
                                let seen = Outgoing::count(&text, &tr.snapshot.items);
                                tr.outbox.push(Outgoing { text, seen });
                            }
                            self.sync_from_scheduler(true);
                        }
                        Err(e) => self.error_banner = Some(e),
                    }
                }
            }
            AppAction::SendComposer(sid) => self.send_composer_message(sid),
            AppAction::CycleSessionModel(sid) => {
                if let Some(rec) = self.scheduler.current_record(sid)
                    && let Some(models) = self.settings.models.get(&rec.harness).cloned()
                    && !models.is_empty()
                {
                    let cur = rec.reported_model.as_deref().or(rec.model.as_deref());
                    let pos = cur.and_then(|c| models.iter().position(|m| m.id == c));
                    let next = match pos {
                        None => Some(models[0].id.clone()),
                        Some(i) if i + 1 < models.len() => Some(models[i + 1].id.clone()),
                        Some(_) => None,
                    };
                    let _ = self.scheduler.configure_session(sid, next, rec.effort);
                    self.sync_from_scheduler(true);
                }
            }
            AppAction::CycleSessionEffort(sid) => {
                if let Some(rec) = self.scheduler.current_record(sid) {
                    const EFFORTS: [&str; 4] = ["low", "medium", "high", "xhigh"];
                    let cur = rec.reported_effort.as_deref().or(rec.effort.as_deref());
                    let pos = cur.and_then(|c| EFFORTS.iter().position(|&e| e == c));
                    let next = match pos {
                        None => Some(EFFORTS[0].to_string()),
                        Some(i) if i + 1 < EFFORTS.len() => Some(EFFORTS[i + 1].to_string()),
                        Some(_) => None,
                    };
                    let _ = self.scheduler.configure_session(sid, rec.model, next);
                    self.sync_from_scheduler(true);
                }
            }
            AppAction::SelectDiscussionAgent(h) => self.settings.set_discussion_agent(h),
            AppAction::SetDiscussionModel(m) => {
                let agent = self.settings.discussion_agent;
                let (fixed, efforts) =
                    crate::views::menu_overlay::model_efforts_for(&self.settings, agent, m.as_deref());
                if let Some(id) = m {
                    self.settings.discussion_models.insert(agent, id);
                } else {
                    self.settings.discussion_models.remove(&agent);
                }
                if fixed
                    || self
                        .settings
                        .discussion_efforts
                        .get(&agent)
                        .is_some_and(|e| !efforts.iter().any(|x| x == e))
                {
                    self.settings.discussion_efforts.remove(&agent);
                }
            }
            AppAction::SetDiscussionEffort(eff) => {
                let agent = self.settings.discussion_agent;
                if let Some(e) = eff {
                    self.settings.discussion_efforts.insert(agent, e);
                } else {
                    self.settings.discussion_efforts.remove(&agent);
                }
            }
            AppAction::ToggleRoutineEnabled(rid) => {
                if let Some(r) = self.routines.iter().find(|r| r.id == rid) {
                    let _ = self.scheduler.set_enabled(&rid, !r.enabled);
                    self.sync_from_scheduler(true);
                }
            }
            AppAction::RunRoutineNow(rid) => {
                if let Ok(rec) = self.scheduler.run_now(&rid) {
                    self.sync_from_scheduler(true);
                    self.execute_action(AppAction::SelectSession(rec.id));
                }
            }
            AppAction::StopRoutine(rid) => {
                let _ = self.scheduler.stop_routine(&rid);
                self.sync_from_scheduler(true);
            }
            AppAction::EditRoutine(rid) => {
                if let Some(r) = self.routines.iter().find(|r| r.id == rid).cloned() {
                    self.main_window_visible = true;
                    self.routine_modal = Some(RoutineFormState::from_existing(&r));
                    self.focus = Some(FocusTarget::RoutineName);
                }
            }
            AppAction::PromptDeleteRoutine(rid) => self.confirm_delete_routine = Some(rid),
            AppAction::ConfirmDeleteRoutine => {
                if let Some(rid) = self.confirm_delete_routine.take() {
                    let _ = self.scheduler.delete_routine(&rid);
                    self.routine_modal = None;
                    self.sync_from_scheduler(true);
                    self.select_initial_destination();
                }
            }
            other => self.execute_form_action(other),
        }
    }

    fn step_question(&mut self, forward: bool) {
        if let Some(SidebarSelection::Session(sid)) = self.selection
            && let Some(rec) = self.scheduler.current_record(sid)
            && let Some(q) = rec.next_question()
            && let Some(tr) = self.transcripts.get_mut(&sid)
            && let Some(draft) = tr.question_drafts.get_mut(&q.id)
        {
            if forward {
                draft.move_forward();
            } else {
                draft.move_back();
            }
        }
    }

    fn send_composer_message(&mut self, sid: Uuid) {
        let Some(rec) = self.scheduler.current_record(sid) else {
            return;
        };
        let draft = self
            .composer_drafts
            .get(&sid)
            .map_or("", |d| d.text())
            .trim()
            .to_string();
        let attachments = self.composer_attachments.get(&sid).cloned().unwrap_or_default();
        if draft.is_empty() && attachments.is_empty() {
            return;
        }
        if rec.harness == Harness::Shell && rec.outcome != RunOutcome::Running {
            let agent = self.settings.discussion_agent;
            let model = self.settings.discussion_models.get(&agent).cloned();
            let effort = self.settings.discussion_efforts.get(&agent).cloned();
            match self
                .scheduler
                .discuss_shell_session(sid, agent, &draft, model, effort)
            {
                Ok(next) => {
                    self.composer_drafts.remove(&sid);
                    self.sync_from_scheduler(true);
                    self.execute_action(AppAction::SelectSession(next.id));
                }
                Err(e) => self.composer_error = Some(e),
            }
            return;
        }
        let Ok(encoded) = ChatMessage::new(draft, attachments).encoded() else {
            return;
        };
        match self.scheduler.send_message(sid, &encoded, &[]) {
            Ok(_) => {
                if let Some(ed) = self.composer_drafts.get_mut(&sid) {
                    ed.set_text("");
                }
                self.composer_attachments.remove(&sid);
                self.composer_error = None;
                if let Some(tr) = self.transcripts.get_mut(&sid) {
                    let seen = Outgoing::count(&encoded, &tr.snapshot.items);
                    tr.outbox.push(Outgoing { text: encoded, seen });
                }
                self.sync_from_scheduler(true);
            }
            Err(e) => self.composer_error = Some(e),
        }
    }
}
