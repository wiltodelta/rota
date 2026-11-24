//! `RoutineForm` modal (`New Routine` / `Edit Routine`, `id: "routineForm"`): grouped-form pickers, missing-folder warning, and dirty check.

use jiff::Timestamp;
use rota_ui::{A11yRole, A11ySpec, Edges, IconKind, Point, Size, Theme, UiElement};

use crate::actions::{AppAction, FocusTarget, MenuId};
use crate::app_state::AppState;
use crate::settings_store::effort_title;
use crate::views::form_rows::{form_page_bg, form_row, form_section};
use crate::views::menu_overlay::{default_model_label, model_efforts_for};
use crate::views::routine_schedule_form::build_schedule_and_limits_sections;
use crate::views::widgets::{
    button, hairline_h, harness_icon, interactive_scrollbar_overlay, label_1line, label_semibold_1line,
    modal_card, popup_button_with_value, text_field_box,
};

pub fn build_routine_form_modal(
    state: &mut AppState,
    theme: &Theme,
    viewport: Size,
    now_seconds: f64,
) -> UiElement {
    let modal_w = (viewport.width - 48.0).clamp(480.0, 620.0);
    let modal_h = (viewport.height - 36.0).clamp(400.0, 580.0);
    let pad_x = theme.ui_px(20.0);
    let inner_w = (modal_w - pad_x * 2.0).max(240.0);

    let folder_missing = state
        .routine_modal
        .as_mut()
        .is_some_and(|f| f.folder_is_missing());
    let Some(form_snap) = state.routine_modal.as_ref().map(|f| {
        let existing = f
            .original_id
            .as_deref()
            .and_then(|id| state.routines.iter().find(|r| r.id == id));
        let candidate = f.build_routine(existing);
        let unchanged = existing.is_some_and(|ex| ex == &candidate);
        (
            f.is_new,
            f.original_id.clone(),
            f.harness,
            f.model.clone(),
            f.effort.clone(),
            f.preset,
            f.skill_input.clone(),
            f.name_input.clone(),
            f.folder_input.clone(),
            f.schedule_input.clone(),
            f.run_limit_input.clone(),
            f.prompt_input.clone(),
            f.time_limit_minutes,
            f.run_limit,
            f.scroll.effective_scroll_y(),
            candidate,
            unchanged,
        )
    }) else {
        return UiElement::column();
    };

    let (
        is_new,
        orig_id,
        harness,
        model_id,
        effort_id,
        preset,
        skill_in,
        name_in,
        folder_in,
        sched_in,
        run_limit_in,
        prompt_in,
        time_limit,
        run_limit,
        scroll_y,
        candidate,
        unchanged,
    ) = form_snap;

    let id_taken = is_new && state.routines.iter().any(|r| r.id == candidate.id);
    let now = Timestamp::now();
    let problem = if id_taken {
        Some("A routine with this ID already exists.".to_string())
    } else {
        candidate.problem(is_new, now)
    };

    let title = if is_new { "New Routine" } else { "Edit Routine" };
    let (hdr_h, ftr_h) = (theme.ui_px(44.0), theme.ui_px(54.0));
    let body_h = (modal_h - hdr_h - ftr_h - 2.0).max(160.0);
    let hov = state.hovered_id.clone();

    // Section 1: Harness, Model, Effort
    let h_act = state
        .actions
        .register_named("routineHarness", AppAction::OpenMenu(MenuId::FormHarness));
    let mut agent_rows = vec![form_row(
        theme,
        "Runs on",
        inner_w,
        popup_button_with_value(
            theme,
            "routineHarness",
            harness.title(),
            harness.title(),
            Some(harness_icon(harness)),
            h_act,
            true,
            hov.as_deref() == Some("routineHarness"),
        ),
    )];

    if harness.is_agent() {
        let m_label = model_id.as_deref().map_or_else(
            || default_model_label(&state.settings, harness),
            |m| state.settings.model_title(m, harness, None),
        );
        let (effort_fixed, _) = model_efforts_for(&state.settings, harness, model_id.as_deref());
        let e_label = if effort_fixed {
            "Not supported".to_string()
        } else {
            effort_id
                .as_deref()
                .map_or_else(|| "Default".to_string(), effort_title)
        };
        let m_act = state
            .actions
            .register_named("routineModel", AppAction::OpenMenu(MenuId::FormModel));
        let e_act = state
            .actions
            .register_named("routineEffort", AppAction::OpenMenu(MenuId::FormEffort));
        agent_rows.push(form_row(
            theme,
            "Model",
            inner_w,
            popup_button_with_value(
                theme,
                "routineModel",
                &m_label,
                &m_label,
                None,
                m_act,
                true,
                hov.as_deref() == Some("routineModel"),
            ),
        ));
        agent_rows.push(form_row(
            theme,
            "Reasoning effort",
            inner_w,
            popup_button_with_value(
                theme,
                "routineEffort",
                &e_label,
                &e_label,
                None,
                e_act,
                !effort_fixed,
                hov.as_deref() == Some("routineEffort"),
            ),
        ));
    }
    let agent_sec = form_section(theme, None, inner_w, agent_rows, None);

    // Section 2: Identity & Project Folder (Skill/ID hidden when editing an existing routine!)
    let field_w = (inner_w * 0.58).max(160.0);
    let mut id_rows = Vec::new();
    if is_new {
        let f_skill = state
            .actions
            .register(AppAction::FocusField(FocusTarget::RoutineSkill));
        let id_lbl = if harness.is_agent() { "Skill / ID" } else { "ID" };
        id_rows.push(form_row(
            theme,
            id_lbl,
            inner_w,
            text_field_box(
                theme,
                "routineSkill",
                "Skill",
                "weekly-report",
                &skill_in,
                state.focus == Some(FocusTarget::RoutineSkill),
                true,
                field_w,
                theme.ui_px(20.0),
                f_skill,
            ),
        ));
    }
    let f_name = state
        .actions
        .register(AppAction::FocusField(FocusTarget::RoutineName));
    id_rows.push(form_row(
        theme,
        "Name",
        inner_w,
        text_field_box(
            theme,
            "routineName",
            "Name",
            "Weekly report",
            &name_in,
            state.focus == Some(FocusTarget::RoutineName),
            false,
            field_w,
            theme.ui_px(20.0),
            f_name,
        ),
    ));

    let id_sec = form_section(theme, None, inner_w, id_rows, None);

    let f_folder = state
        .actions
        .register(AppAction::FocusField(FocusTarget::RoutineFolder));
    let choose_act = state
        .actions
        .register_named("chooseRoutineFolder", AppAction::FormChooseFolder);
    let folder_box_w = (inner_w - theme.ui_px(136.0)).max(120.0);

    let mut folder_block = UiElement::column()
        .width(inner_w)
        .padding(Edges::xy(theme.ui_px(12.0), theme.ui_px(9.0)))
        .gap(theme.ui_px(6.0))
        .clip()
        .child(
            UiElement::row()
                .width(inner_w - theme.ui_px(24.0))
                .align_center()
                .gap(theme.ui_px(8.0))
                .clip()
                .child(text_field_box(
                    theme,
                    "routineFolder",
                    "Project folder",
                    "/path/to/project",
                    &folder_in,
                    state.focus == Some(FocusTarget::RoutineFolder),
                    true,
                    folder_box_w,
                    theme.ui_px(20.0),
                    f_folder,
                ))
                .child(button(
                    theme,
                    "chooseRoutineFolder",
                    "Choose…",
                    Some(IconKind::Folder),
                    choose_act,
                    false,
                    false,
                    true,
                    hov.as_deref() == Some("chooseRoutineFolder"),
                )),
        );
    if folder_missing {
        folder_block = folder_block.child(
            UiElement::row()
                .align_center()
                .gap(theme.ui_px(5.0))
                .child(UiElement::icon(
                    IconKind::Warning,
                    theme.ui_px(12.0),
                    theme.warning,
                ))
                .child(label_1line(
                    "No folder at this path.",
                    theme.caption_size(),
                    theme.warning,
                    inner_w - 48.0,
                )),
        );
    }
    let folder_sec = form_section(
        theme,
        Some(("Project folder", None)),
        inner_w,
        vec![folder_block],
        None,
    );

    // Section 3: Prompt / Command
    let f_prompt = state
        .actions
        .register(AppAction::FocusField(FocusTarget::RoutinePrompt));
    let (p_lbl, p_ph) = if harness.is_agent() {
        ("Prompt", "Describe what the agent should do…")
    } else {
        ("Shell command", "./scripts/run.sh")
    };
    let prompt_sec = form_section(
        theme,
        Some((p_lbl, None)),
        inner_w,
        vec![
            UiElement::column()
                .width(inner_w)
                .padding(Edges::all(theme.ui_px(10.0)))
                .child(text_field_box(
                    theme,
                    "routinePrompt",
                    p_lbl,
                    p_ph,
                    &prompt_in,
                    state.focus == Some(FocusTarget::RoutinePrompt),
                    !harness.is_agent(),
                    inner_w - theme.ui_px(20.0),
                    theme.ui_px(68.0),
                    f_prompt,
                )),
        ],
        None,
    );

    let (sched_sec, limits_sec) = build_schedule_and_limits_sections(
        state,
        theme,
        inner_w,
        preset,
        &sched_in,
        &run_limit_in,
        time_limit,
        run_limit,
        &candidate,
        now,
    );

    let form_col = UiElement::column()
        .id("routineFormContent")
        .width(modal_w)
        .padding(Edges::xy(pad_x, theme.ui_px(14.0)))
        .gap(theme.ui_px(14.0))
        .child(agent_sec)
        .child(id_sec)
        .child(folder_sec)
        .child(prompt_sec)
        .child(sched_sec)
        .child(limits_sec);

    let total_h = if let Some(f) = &mut state.routine_modal {
        if f.scroll.item_count() == 0 {
            f.scroll.set_heights(&[theme.ui_px(620.0)], body_h);
        }
        f.scroll.total_height()
    } else {
        body_h
    };

    let cancel_act = state.actions.register_named("Cancel", AppAction::CloseModal);
    let (save_id, save_lbl) = if is_new {
        ("addRoutine", "Add")
    } else {
        ("saveRoutine", "Save")
    };
    let save_act = state.actions.register_named(save_id, AppAction::SaveRoutineForm);

    let mut left_ftr = UiElement::row().align_center().gap(theme.ui_px(8.0)).clip();
    if let Some(rid) = orig_id {
        let del_act = state
            .actions
            .register_named("deleteRoutineBtn", AppAction::PromptDeleteRoutine(rid));
        left_ftr = left_ftr.child(button(
            theme,
            "deleteRoutineBtn",
            "Delete…",
            Some(IconKind::Trash),
            del_act,
            false,
            true,
            true,
            hov.as_deref() == Some("deleteRoutineBtn"),
        ));
    }
    if let Some(err) = state.error_banner.as_deref().or(problem.as_deref()) {
        let mut pspec = A11ySpec::new(A11yRole::StaticText, err);
        pspec.value = Some(err.to_string());
        let id_t = skill_in.text().trim();
        let blank_hint = state.error_banner.is_none()
            && (id_t.is_empty()
                || (rota_core::model::Routine::is_valid_id(id_t)
                    && (folder_in.text().trim().is_empty() || prompt_in.text().trim().is_empty())));
        let prob_col = if blank_hint {
            theme.text_muted
        } else {
            theme.danger
        };
        left_ftr = left_ftr.child(
            label_1line(err, theme.caption_size(), prob_col, inner_w * 0.52)
                .id("sheetProblem")
                .a11y(pspec),
        );
    }

    let can_save = problem.is_none() && (is_new || !unchanged);
    let footer = UiElement::row()
        .width(modal_w)
        .height(ftr_h)
        .align_center()
        .justify_between()
        .padding(Edges::xy(pad_x, theme.ui_px(10.0)))
        .clip()
        .child(left_ftr)
        .child(
            UiElement::row()
                .align_center()
                .gap(theme.ui_px(8.0))
                .flex_shrink(0.0)
                .child(button(
                    theme,
                    "Cancel",
                    "Cancel",
                    None,
                    cancel_act,
                    false,
                    false,
                    true,
                    hov.as_deref() == Some("Cancel"),
                ))
                .child(button(
                    theme,
                    save_id,
                    save_lbl,
                    None,
                    save_act,
                    true,
                    false,
                    can_save,
                    hov.as_deref() == Some(save_id),
                )),
        );

    let sb_active = state
        .dragging_scrollbar
        .as_ref()
        .is_some_and(|(k, _)| k == "routineForm")
        || hov.as_deref() == Some("scrollbarThumb-routineForm");
    let sb_opt = state
        .routine_modal
        .as_ref()
        .map(|f| f.scroll.clone())
        .and_then(|sc| {
            interactive_scrollbar_overlay(
                theme,
                "routineForm",
                &sc,
                (body_h - 4.0).max(120.0),
                total_h,
                modal_w - 1.0,
                sb_active,
                now_seconds,
                &mut state.activity_clock,
            )
        });
    let scroll_box = UiElement::column()
        .id("routineFormScroll")
        .width(modal_w)
        .height((body_h - 4.0).max(120.0))
        .bg(form_page_bg(theme))
        .clip()
        .scroll_offset(Point::new(0.0, scroll_y))
        .a11y(A11ySpec::new(A11yRole::ScrollArea, "Routine Settings"))
        .child(form_col)
        .children(sb_opt);
    let body_wrap = UiElement::column()
        .width(modal_w)
        .height(body_h)
        .padding(Edges::xy(0.0, 2.0))
        .bg(form_page_bg(theme))
        .clip()
        .child(scroll_box);

    modal_card(theme, "routineForm", title, modal_w, modal_h)
        .child(
            UiElement::row()
                .width(modal_w)
                .height(hdr_h)
                .align_center()
                .padding(Edges::xy(pad_x, theme.ui_px(10.0)))
                .child(label_semibold_1line(
                    title,
                    theme.title_size(),
                    theme.text_primary,
                    inner_w,
                )),
        )
        .child(hairline_h(theme))
        .child(body_wrap)
        .child(hairline_h(theme))
        .child(footer)
}
