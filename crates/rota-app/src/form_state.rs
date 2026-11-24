//! Modal & view form state models (`RoutineFormState`, `ImportSheetState`, `ScheduleViewState`).

use std::collections::HashSet;

use jiff::Timestamp;
use jiff::tz::TimeZone;
use rota_core::import::ImportScan;
use rota_core::model::{Harness, Routine};
use rota_core::schedule::ScheduleCalendar;
use rota_ui::{ReturnBehavior, TextEditState, VirtualScrollState};

use crate::actions::SchedulePreset;

pub struct RoutineFormState {
    pub is_new: bool,
    pub original_id: Option<String>,
    pub harness: Harness,
    pub model: Option<String>,
    pub effort: Option<String>,
    pub preset: SchedulePreset,
    pub skill_input: TextEditState,
    pub name_input: TextEditState,
    pub folder_input: TextEditState,
    pub schedule_input: TextEditState,
    pub run_limit_input: TextEditState,
    pub prompt_input: TextEditState,
    pub time_limit_minutes: Option<i64>,
    pub run_limit: Option<i64>,
    pub scheduled_at: Option<Timestamp>,
    pub enabled: bool,
    pub generated_prompt: String,
    pub scroll: VirtualScrollState,
    cached_folder_check: Option<(String, bool)>,
}

impl RoutineFormState {
    pub fn folder_is_missing(&mut self) -> bool {
        let folder_txt = self.folder_input.text().trim();
        if folder_txt.is_empty() {
            return false;
        }
        if let Some((ref prev, exists)) = self.cached_folder_check
            && prev == folder_txt
        {
            return !exists;
        }
        let exists = std::path::Path::new(folder_txt).is_dir();
        self.cached_folder_check = Some((folder_txt.to_string(), exists));
        !exists
    }

    pub fn new_default() -> Self {
        let now = Timestamp::now();
        let next_hour = Timestamp::from_second(((now.as_second() / 3600) + 1) * 3600).unwrap_or(now);
        Self {
            is_new: true,
            original_id: None,
            harness: Harness::Claude,
            model: None,
            effort: None,
            preset: SchedulePreset::Weekdays,
            skill_input: TextEditState::single_line(""),
            name_input: TextEditState::single_line(""),
            folder_input: TextEditState::single_line(""),
            schedule_input: TextEditState::single_line("0 9 * * 1-5"),
            run_limit_input: TextEditState::single_line("2"),
            prompt_input: TextEditState::multi_line("", ReturnBehavior::InsertNewline),
            time_limit_minutes: None,
            run_limit: None,
            scheduled_at: Some(next_hour),
            enabled: true,
            generated_prompt: String::new(),
            scroll: VirtualScrollState::new_top(),
            cached_folder_check: None,
        }
    }

    pub fn from_existing(r: &Routine) -> Self {
        let preset = if !r.repeats {
            SchedulePreset::Once
        } else {
            match r.schedule.as_str() {
                "0 9 * * 1-5" => SchedulePreset::Weekdays,
                "0 9 * * *" => SchedulePreset::Daily,
                "0 9 * * 1" => SchedulePreset::Weekly,
                "0 9 1 * *" => SchedulePreset::Monthly,
                "0 * * * *" => SchedulePreset::Hourly,
                _ => SchedulePreset::Custom,
            }
        };
        Self {
            is_new: false,
            original_id: Some(r.id.clone()),
            harness: r.harness,
            model: r.model.clone(),
            effort: r.effort.clone(),
            preset,
            skill_input: TextEditState::single_line(&r.id),
            name_input: TextEditState::single_line(&r.name),
            folder_input: TextEditState::single_line(&r.working_directory),
            schedule_input: TextEditState::single_line(&r.schedule),
            run_limit_input: TextEditState::single_line(
                r.run_limit.map_or_else(|| "2".to_string(), |n| n.to_string()),
            ),
            prompt_input: TextEditState::multi_line(&r.prompt, ReturnBehavior::InsertNewline),
            time_limit_minutes: r.time_limit_minutes,
            run_limit: r.run_limit,
            scheduled_at: r.scheduled_at,
            enabled: r.enabled,
            generated_prompt: String::new(),
            scroll: VirtualScrollState::new_top(),
            cached_folder_check: None,
        }
    }

    pub fn sync_generated_prompt(&mut self) {
        if !self.harness.is_agent() {
            if self.prompt_input.text() == self.generated_prompt {
                self.prompt_input.set_text("");
                self.generated_prompt.clear();
            }
            return;
        }
        let skill = self.skill_input.text().trim();
        let cwd = self.folder_input.text().trim();
        if !skill.is_empty()
            && !cwd.is_empty()
            && (self.prompt_input.is_empty() || self.prompt_input.text() == self.generated_prompt)
        {
            let next = Routine::default_prompt(skill, cwd);
            self.prompt_input.set_text(&next);
            self.generated_prompt = next;
        }
    }

    pub fn build_routine(&self, existing: Option<&Routine>) -> Routine {
        let id = self.skill_input.text().trim().to_string();
        let raw_name = self.name_input.text().trim();
        let name = if raw_name.is_empty() {
            id.clone()
        } else {
            raw_name.to_string()
        };
        let repeats = self.preset != SchedulePreset::Once;
        let schedule = if let Some(cron) = self.preset.default_cron() {
            cron.to_string()
        } else {
            self.schedule_input.text().trim().to_string()
        };
        let mut out = Routine::new(
            id,
            name,
            self.folder_input.text().trim(),
            schedule,
            self.harness,
            self.enabled,
            self.prompt_input.text(),
        );
        out.repeats = repeats;
        out.scheduled_at = self.scheduled_at;
        out.model = self.model.clone();
        out.effort = self.effort.clone();
        out.time_limit_minutes = self.time_limit_minutes;
        out.run_limit = if repeats { self.run_limit } else { None };
        if let Some(prev) = existing {
            out.import_identity = prev.import_identity.clone();
            if out.has_same_schedule(prev) {
                out.scheduled_run_count = prev.scheduled_run_count;
                out.schedule_completed_at = prev.schedule_completed_at;
                out.next_fire = prev.next_fire;
            }
        }
        out
    }
}

pub struct ImportSheetState {
    pub scans: Option<Vec<ImportScan>>,
    pub chosen: HashSet<String>,
    pub search_input: TextEditState,
    pub show_imported: bool,
    pub target_harness: Option<Harness>,
    pub scroll: VirtualScrollState,
}

impl Default for ImportSheetState {
    fn default() -> Self {
        Self::new()
    }
}

impl ImportSheetState {
    pub fn new() -> Self {
        Self {
            scans: None,
            chosen: HashSet::new(),
            search_input: TextEditState::single_line(""),
            show_imported: false,
            target_harness: None,
            scroll: VirtualScrollState::new_top(),
        }
    }
}

pub struct ScheduleViewState {
    pub start_day: Timestamp,
    pub selected_day: Option<Timestamp>,
    pub pending_scroll_day: Option<String>,
    pub scroll: VirtualScrollState,
}

impl ScheduleViewState {
    pub fn new(now: Timestamp) -> Self {
        let start = ScheduleCalendar::start_of_local_day(now, &TimeZone::system());
        Self {
            start_day: start,
            selected_day: None,
            pending_scroll_day: None,
            scroll: VirtualScrollState::new_top(),
        }
    }
}

impl crate::app_state::AppState {
    pub(crate) fn execute_form_action(&mut self, action: crate::actions::AppAction) {
        use crate::actions::{AppAction, SidebarSelection};
        use rota_core::import::RoutineImport;
        use rota_platform::pick_directory;

        match action {
            AppAction::ScheduleStepWeeks(w) => {
                let secs = self.schedule_state.start_day.as_second() + i64::from(w) * 7 * 86400;
                if let Ok(ts) = Timestamp::from_second(secs) {
                    self.schedule_state.start_day =
                        ScheduleCalendar::start_of_local_day(ts, &TimeZone::system());
                    self.schedule_state.selected_day = None;
                }
            }
            AppAction::ScheduleToday => {
                let start = ScheduleCalendar::start_of_local_day(Timestamp::now(), &TimeZone::system());
                self.schedule_state.start_day = start;
                self.schedule_state.selected_day = Some(start);
            }
            AppAction::ScheduleSelectDay(sec) => {
                let picked = Timestamp::from_second(sec).ok();
                self.schedule_state.selected_day = picked;
                if let Some(ts) = picked {
                    let z = ts.to_zoned(TimeZone::system());
                    self.schedule_state.pending_scroll_day =
                        Some(format!("{:04}-{:02}-{:02}", z.year(), z.month(), z.day()));
                }
            }
            AppAction::ToggleShowPausedInSchedule => {
                self.settings
                    .set_show_paused_in_schedule(!self.settings.show_paused_in_schedule);
            }
            AppAction::FormSetHarness(h) => {
                if let Some(f) = &mut self.routine_modal {
                    f.harness = h;
                    f.model = None;
                    f.effort = None;
                    f.sync_generated_prompt();
                }
            }
            AppAction::FormChooseFolder => {
                let init = self
                    .routine_modal
                    .as_ref()
                    .map(|f| f.folder_input.text().to_string());
                if let Some(dir) = pick_directory(init.as_deref())
                    && let Some(f) = &mut self.routine_modal
                {
                    f.folder_input.set_text(dir.to_string_lossy().into_owned());
                    f.sync_generated_prompt();
                }
            }
            AppAction::FormSetModel(opt) => {
                if let Some(f) = &mut self.routine_modal {
                    let (fixed, efforts) = crate::views::menu_overlay::model_efforts_for(
                        &self.settings,
                        f.harness,
                        opt.as_deref(),
                    );
                    f.model = opt;
                    if fixed
                        || f.effort
                            .as_deref()
                            .is_some_and(|e| !efforts.iter().any(|x| x == e))
                    {
                        f.effort = None;
                    }
                }
            }
            AppAction::FormSetEffort(opt) => {
                if let Some(f) = &mut self.routine_modal {
                    f.effort = opt;
                }
            }
            AppAction::FormSetPreset(p) => {
                if let Some(f) = &mut self.routine_modal {
                    f.preset = p;
                    if p == SchedulePreset::Once {
                        f.run_limit = None;
                    }
                    if let Some(cron) = p.default_cron() {
                        f.schedule_input.set_text(cron);
                    }
                }
            }
            AppAction::FormApplyCron(cron) => {
                if let Some(f) = &mut self.routine_modal {
                    f.preset = SchedulePreset::Custom;
                    f.schedule_input.set_text(&cron);
                }
            }
            AppAction::FormSetRunLimitEnabled(on) => {
                if let Some(f) = &mut self.routine_modal {
                    f.run_limit = if on { Some(2) } else { None };
                    if on {
                        f.run_limit_input.set_text("2");
                    }
                }
            }
            AppAction::FormToggleTimeLimit => {
                if let Some(f) = &mut self.routine_modal {
                    f.time_limit_minutes = if f.time_limit_minutes.is_some() {
                        None
                    } else {
                        Some(60)
                    };
                }
            }
            AppAction::FormAdjustTimeLimit(delta) => {
                if let Some(f) = &mut self.routine_modal
                    && let Some(cur) = f.time_limit_minutes
                {
                    f.time_limit_minutes = Some((cur + delta).clamp(5, 1440));
                }
            }
            AppAction::FormToggleRunLimit => {
                if let Some(f) = &mut self.routine_modal {
                    f.run_limit = if f.run_limit.is_some() { None } else { Some(5) };
                }
            }
            AppAction::FormAdjustRunLimit(delta) => {
                if let Some(f) = &mut self.routine_modal
                    && let Some(cur) = f.run_limit
                {
                    f.run_limit = Some((cur + delta).clamp(1, 999));
                }
            }
            AppAction::SaveRoutineForm => {
                let Some(form) = self.routine_modal.as_ref() else {
                    return;
                };
                let existing = form
                    .original_id
                    .as_deref()
                    .and_then(|id| self.routines.iter().find(|r| r.id == id));
                let candidate = form.build_routine(existing);
                let is_new = form.is_new;
                if candidate.problem(is_new, Timestamp::now()).is_some() {
                    return;
                }
                let res = if is_new {
                    self.scheduler.create_routine(candidate.clone())
                } else {
                    self.scheduler.update_routine(candidate.clone())
                };
                match res {
                    Ok(_) => {
                        let rid = candidate.id;
                        self.routine_modal = None;
                        self.sync_from_scheduler(true);
                        self.selection = Some(SidebarSelection::Routine(rid));
                    }
                    Err(e) => self.error_banner = Some(e),
                }
            }
            AppAction::ImportToggleShowImported => {
                if let Some(imp) = &mut self.import_modal {
                    imp.show_imported = !imp.show_imported;
                }
            }
            AppAction::ImportToggleCandidate(cid) => {
                if let Some(imp) = &mut self.import_modal
                    && !imp.chosen.insert(cid.clone())
                {
                    imp.chosen.remove(&cid);
                }
            }
            AppAction::ImportSelectAllSource(src_idx) => {
                if let Some(imp) = &mut self.import_modal
                    && let Some(scans) = &imp.scans
                    && let Some(scan) = scans.get(src_idx)
                {
                    let ids: Vec<String> = scan
                        .candidates
                        .iter()
                        .filter(|c| c.unsupported.is_none() && !RoutineImport::is_imported(c, &self.routines))
                        .map(|c| c.id())
                        .collect();
                    let all = !ids.is_empty() && ids.iter().all(|id| imp.chosen.contains(id));
                    for id in ids {
                        if all {
                            imp.chosen.remove(&id);
                        } else {
                            imp.chosen.insert(id);
                        }
                    }
                }
            }
            AppAction::ImportSetTargetHarness(opt) => {
                if let Some(imp) = &mut self.import_modal {
                    imp.target_harness = opt;
                }
            }
            AppAction::ImportCycleTargetHarness => {
                if let Some(imp) = &mut self.import_modal {
                    imp.target_harness = match imp.target_harness {
                        None => Some(Harness::Claude),
                        Some(Harness::Claude) => Some(Harness::Codex),
                        Some(Harness::Codex) => Some(Harness::Grok),
                        Some(Harness::Grok) => Some(Harness::Antigravity),
                        _ => None,
                    };
                }
            }
            AppAction::ConfirmImportSelected => {
                let Some(imp) = self.import_modal.take() else {
                    return;
                };
                let mut to_import = Vec::new();
                let mut existing = self.routines.clone();
                for scan in imp.scans.unwrap_or_default() {
                    for cand in scan.candidates {
                        if imp.chosen.contains(&cand.id())
                            && let Some(mut r) = RoutineImport::routine_to_import(&cand, &existing)
                        {
                            if let Some(h) = imp.target_harness
                                && h != cand.source.harness()
                            {
                                r.harness = h;
                                r.model = None;
                                r.effort = None;
                            }
                            existing.push(r.clone());
                            to_import.push(r);
                        }
                    }
                }
                if !to_import.is_empty() {
                    let first_id = to_import[0].id.clone();
                    let _ = self.scheduler.import_routines(to_import);
                    self.sync_from_scheduler(true);
                    self.selection = Some(SidebarSelection::Routine(first_id));
                }
            }
            other => self.execute_settings_and_panel_action(other),
        }
    }
}
