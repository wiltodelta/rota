//! `RoutineScheduleForm` & execution time-limit grouped sections for `RoutineForm`.

use jiff::Timestamp;
use jiff::tz::TimeZone;
use rota_core::model::Routine;
use rota_core::schedule::ScheduleText;
use rota_ui::{A11yRole, A11ySpec, IconKind, TextEditState, Theme, UiElement};

use crate::actions::{AppAction, FocusTarget, MenuId, SchedulePreset};
use crate::app_state::AppState;
use crate::views::form_rows::{form_row, form_section, form_toggle_row};
use crate::views::widgets::{button, icon_button, mono_text, popup_button_with_value, text_field_box};

#[allow(clippy::too_many_arguments)]
pub fn build_schedule_and_limits_sections(
    state: &mut AppState,
    theme: &Theme,
    width: f32,
    preset: SchedulePreset,
    sched_in: &TextEditState,
    run_limit_in: &TextEditState,
    time_limit: Option<i64>,
    run_limit: Option<i64>,
    candidate: &Routine,
    now: Timestamp,
) -> (UiElement, UiElement) {
    let hov = state.hovered_id.clone();

    let rep_act = state
        .actions
        .register_named("routineRepeat", AppAction::OpenMenu(MenuId::FormRepeat));
    let mut sched_rows = vec![form_row(
        theme,
        "Repeat",
        width,
        popup_button_with_value(
            theme,
            "routineRepeat",
            preset.title(),
            preset.title(),
            None,
            rep_act,
            true,
            hov.as_deref() == Some("routineRepeat"),
        ),
    )];

    if preset == SchedulePreset::Custom {
        let f_sched = state
            .actions
            .register(AppAction::FocusField(FocusTarget::RoutineSchedule));
        let presets_act = state
            .actions
            .register_named("schedulePresets", AppAction::OpenMenu(MenuId::FormCronPresets));
        let cron_trailing = UiElement::row()
            .align_center()
            .gap(theme.ui_px(6.0))
            .child(text_field_box(
                theme,
                "routineSchedule",
                "Cron schedule",
                "0 9 * * 1-5",
                sched_in,
                state.focus == Some(FocusTarget::RoutineSchedule),
                true,
                theme.ui_px(180.0),
                theme.ui_px(20.0),
                f_sched,
            ))
            .child(icon_button(
                theme,
                "schedulePresets",
                "Common schedules",
                IconKind::Clock,
                presets_act,
                false,
                true,
                hov.as_deref() == Some("schedulePresets"),
            ));
        sched_rows.push(form_row(theme, "Cron schedule", width, cron_trailing));
    }

    if preset != SchedulePreset::Once {
        let ends_lbl = if run_limit.is_some() {
            "After a Number of Runs"
        } else {
            "Never"
        };
        let ends_act = state
            .actions
            .register_named("routineEnds", AppAction::OpenMenu(MenuId::FormEnds));
        sched_rows.push(form_row(
            theme,
            "Ends",
            width,
            popup_button_with_value(
                theme,
                "routineEnds",
                ends_lbl,
                ends_lbl,
                None,
                ends_act,
                true,
                hov.as_deref() == Some("routineEnds"),
            ),
        ));

        if run_limit.is_some() {
            let f_rl = state
                .actions
                .register(AppAction::FocusField(FocusTarget::RoutineRunLimit));
            sched_rows.push(form_row(
                theme,
                "Scheduled runs in total",
                width,
                text_field_box(
                    theme,
                    "routineRunLimit",
                    "Scheduled runs in total",
                    "2",
                    run_limit_in,
                    state.focus == Some(FocusTarget::RoutineRunLimit),
                    true,
                    theme.ui_px(76.0),
                    theme.ui_px(20.0),
                    f_rl,
                ),
            ));
        }
    }

    let tz = TimeZone::system();
    let sched_preview = if candidate.is_schedule_complete() {
        "Schedule complete. Change its repetition or run limit to start again.".to_string()
    } else if let Some(nf) = candidate.next_scheduled_fire(now, &tz) {
        format!(
            "{} · Next: {}",
            candidate.schedule_description(),
            ScheduleText::format_abbreviated_date_time(nf, &tz)
        )
    } else {
        "Choose a valid cron schedule with an upcoming run.".to_string()
    };

    let sched_sec = form_section(
        theme,
        Some(("Schedule", None)),
        width,
        sched_rows,
        Some((&sched_preview, Some("routineSchedulePreview"))),
    );

    // Limits section
    let tl_toggle = state
        .actions
        .register_named("routineTimeLimit", AppAction::FormToggleTimeLimit);
    let mut limit_rows = vec![form_toggle_row(
        theme,
        "routineTimeLimit",
        "Stop after time limit",
        width,
        time_limit.is_some(),
        true,
        tl_toggle,
    )];

    if let Some(mins) = time_limit {
        let dec = state.actions.register(AppAction::FormAdjustTimeLimit(-5));
        let inc = state.actions.register(AppAction::FormAdjustTimeLimit(5));
        let val_str = format_minutes_human(mins);
        let mut v_spec = A11ySpec::new(A11yRole::StaticText, &val_str);
        v_spec.value = Some(val_str.clone());
        let stepper = UiElement::row()
            .align_center()
            .gap(theme.ui_px(6.0))
            .child(button(
                theme,
                "tlMinus",
                "-",
                None,
                dec,
                false,
                false,
                mins > 5,
                hov.as_deref() == Some("tlMinus"),
            ))
            .child(
                mono_text(&val_str, theme.body_size(), theme.text_primary, 72.0, Some(1))
                    .id("routineTimeLimitValue")
                    .a11y(v_spec),
            )
            .child(button(
                theme,
                "tlPlus",
                "+",
                None,
                inc,
                false,
                false,
                mins < 1440,
                hov.as_deref() == Some("tlPlus"),
            ));
        limit_rows.push(form_row(theme, "Time limit", width, stepper));
    }

    let limits_sec = form_section(theme, Some(("Limits", None)), width, limit_rows, None);
    (sched_sec, limits_sec)
}

fn format_minutes_human(mins: i64) -> String {
    let h = mins / 60;
    let m = mins % 60;
    match (h, m) {
        (0, m) => format!("{m} min"),
        (h, 0) => format!("{h} h"),
        (h, m) => format!("{h} h {m} min"),
    }
}
