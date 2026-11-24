//! Native file Drag & Drop staging (`NSDraggingDestination`), interactive scrollbar thumb dragging, and scroll physics ticking.

use std::path::PathBuf;

use rota_core::storage::ChatAttachmentStore;
use rota_ui::{Point, scroll_y_from_track_pointer};

use crate::actions::{AppAction, SettingsPane, SidebarSelection};
use crate::app_state::AppState;

impl AppState {
    pub fn handle_dropped_file(&mut self, path: PathBuf) {
        if let Some(form) = &mut self.routine_modal {
            if path.is_dir() {
                form.folder_input.set_text(path.to_string_lossy());
                form.sync_generated_prompt();
            }
            return;
        }
        let Some(SidebarSelection::Session(sid)) = self.selection else {
            return;
        };
        let Some(rec) = self.scheduler.current_record(sid) else {
            return;
        };
        if !rec.harness.is_agent() {
            return;
        }
        if let Some(log) = &rec.log_path {
            match ChatAttachmentStore::new(std::path::Path::new(log)).stage(&[path]) {
                Ok(staged) => {
                    self.composer_attachments.entry(sid).or_default().extend(staged);
                    self.composer_error = None;
                }
                Err(e) => self.composer_error = Some(e.to_string()),
            }
        }
    }

    pub fn scroll_viewport_height(&self, container_id: &str, fallback: f32) -> f32 {
        self.last_tree
            .as_ref()
            .and_then(|t| t.bounds_by_id(container_id))
            .map_or(fallback, |b| b.height.max(60.0))
    }

    pub fn tick_all_scroll_physics(&mut self, now_seconds: f64) {
        let fallback_h = (self.viewport_size.height - 96.0).max(120.0);
        let sb_h = self.scroll_viewport_height("routineSidebar", fallback_h);
        let set_id = self.settings_pane.map_or_else(
            || "settingsScroll-general".to_string(),
            |p| format!("settingsScroll-{}", p.as_str()),
        );
        let set_h = self.scroll_viewport_height(&set_id, fallback_h);
        let rd_h = self.scroll_viewport_height("routineHistoryScroll", fallback_h);
        let sc_h = self.scroll_viewport_height("scheduleList", fallback_h);
        let rf_h = self.scroll_viewport_height("routineFormScroll", 400.0);
        let im_h = self.scroll_viewport_height("importResults", 340.0);
        let tr_h = self.scroll_viewport_height("chatTranscript", fallback_h);

        self.sidebar_scroll
            .tick_physics(now_seconds, sb_h, &mut self.activity_clock);
        self.settings_scroll
            .tick_physics(now_seconds, set_h, &mut self.activity_clock);
        self.routine_detail_scroll
            .tick_physics(now_seconds, rd_h, &mut self.activity_clock);
        self.schedule_state
            .scroll
            .tick_physics(now_seconds, sc_h, &mut self.activity_clock);
        if let Some(m) = &mut self.routine_modal {
            m.scroll.tick_physics(now_seconds, rf_h, &mut self.activity_clock);
        }
        if let Some(m) = &mut self.import_modal {
            m.scroll.tick_physics(now_seconds, im_h, &mut self.activity_clock);
        }
        if let Some(SidebarSelection::Session(sid)) = self.selection
            && let Some(tr) = self.transcripts.get_mut(&sid)
        {
            tr.scroll
                .tick_physics(now_seconds, tr_h, &mut self.activity_clock);
        }
    }

    pub fn try_begin_scrollbar_drag(&mut self, pos: Point, hit_id: Option<&str>, now_seconds: f64) -> bool {
        let Some(id) = hit_id else { return false };
        let Some(key) = id.strip_prefix("scrollbarThumb-") else {
            return false;
        };
        let thumb_top = self
            .last_tree
            .as_ref()
            .and_then(|t| t.bounds_by_id(id))
            .map_or(0.0, |b| pos.y - b.y);
        self.dragging_scrollbar = Some((key.to_string(), thumb_top.max(0.0)));
        self.update_scrollbar_drag(pos, now_seconds);
        true
    }

    pub fn update_scrollbar_drag(&mut self, pos: Point, now_seconds: f64) {
        let Some((key, grab_off)) = self.dragging_scrollbar.clone() else {
            return;
        };
        let container_id = match key.as_str() {
            "sidebar" => "routineSidebar".to_string(),
            "transcript" => "chatTranscript".to_string(),
            "routineDetail" => "routineHistoryScroll".to_string(),
            "schedule" => "scheduleList".to_string(),
            "routineForm" => "routineFormScroll".to_string(),
            "import" => "importResults".to_string(),
            other if other.starts_with("settings-") => other.replacen("settings-", "settingsScroll-", 1),
            _ => return,
        };
        let Some(vp) = self
            .last_tree
            .as_ref()
            .and_then(|t| t.bounds_by_id(&container_id))
        else {
            return;
        };
        let local_y = pos.y - vp.y;

        let apply = |sc: &mut rota_ui::VirtualScrollState| {
            let total = sc.total_height();
            let next = scroll_y_from_track_pointer(local_y, vp.height, total, Some(grab_off));
            let max_y = sc.max_scroll_y(vp.height);
            sc.scroll_y = next.clamp(0.0, max_y);
            sc.stick_to_bottom = (max_y - sc.scroll_y) <= sc.sticky_threshold_pt;
            sc.physics.note_activity(now_seconds);
        };

        match key.as_str() {
            "sidebar" => apply(&mut self.sidebar_scroll),
            "routineDetail" => apply(&mut self.routine_detail_scroll),
            "schedule" => apply(&mut self.schedule_state.scroll),
            "routineForm" => {
                if let Some(m) = &mut self.routine_modal {
                    apply(&mut m.scroll);
                }
            }
            "import" => {
                if let Some(m) = &mut self.import_modal {
                    apply(&mut m.scroll);
                }
            }
            other if other.starts_with("settings-") => apply(&mut self.settings_scroll),
            "transcript" => {
                if let Some(SidebarSelection::Session(sid)) = self.selection
                    && let Some(tr) = self.transcripts.get_mut(&sid)
                {
                    apply(&mut tr.scroll);
                }
            }
            _ => {}
        }
    }

    pub(crate) fn step_sidebar_selection(&mut self, dir: i32) {
        if let Some(pane) = self.settings_pane {
            let cur = SettingsPane::ALL.iter().position(|&p| p == pane).unwrap_or(0) as i32;
            let next = (cur + dir).clamp(0, (SettingsPane::ALL.len() - 1) as i32) as usize;
            let p = SettingsPane::ALL[next];
            self.settings_pane = Some(p);
            self.settings.set_last_settings_pane(p);
            return;
        }
        let mut items: Vec<SidebarSelection> = self
            .routines
            .iter()
            .map(|r| SidebarSelection::Routine(r.id.clone()))
            .collect();
        items.extend(
            self.visible_sessions()
                .into_iter()
                .map(|s| SidebarSelection::Session(s.id)),
        );
        if items.is_empty() {
            return;
        }
        let cur = self
            .selection
            .as_ref()
            .and_then(|sel| items.iter().position(|x| x == sel))
            .map_or(0, |i| i as i32);
        let next = (cur + dir).clamp(0, (items.len() - 1) as i32) as usize;
        match &items[next] {
            SidebarSelection::Routine(rid) => self.execute_action(AppAction::SelectRoutine(rid.clone())),
            SidebarSelection::Session(sid) => self.execute_action(AppAction::SelectSession(*sid)),
            SidebarSelection::Schedule => {}
        }
    }
}
