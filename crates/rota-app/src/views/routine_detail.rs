//! `RoutineDetail` view: adaptive 1-row/2-row schedule header (`Scheduled [switch]`, `Run Now`, `Edit…`) and authentic `SessionHistoryRow` list.

use jiff::Timestamp;
use jiff::tz::TimeZone;
use rota_core::model::serde_ext::uppercase_uuid;
use rota_core::model::{Routine, RunOutcome, RunRecord};
use rota_core::schedule::ScheduleText;
use rota_core::transcript::{SessionPreview, Transcript};
use rota_platform::abbreviate_tilde;
use rota_ui::{
    A11yRole, A11ySpec, Color, Edges, IconKind, Point, TextAlign, TextLayoutOpts, TextSpan, Theme, UiElement,
};

use crate::actions::AppAction;
use crate::app_state::AppState;
use crate::views::widgets::{
    button, format_relative_or_short, hairline_h, harness_color, harness_icon, interactive_scrollbar_overlay,
    label_1line, label_semibold_1line, label_wrapped, labeled_switch_leading_animated,
};

pub fn build_routine_detail(
    state: &mut AppState,
    theme: &Theme,
    routine: &Routine,
    width: f32,
    height: f32,
    now_seconds: f64,
) -> UiElement {
    let running = state.scheduler.is_running(&routine.id);
    let pulse = running.then(|| state.activity_clock.pulse_opacity(now_seconds));
    let pad_x = theme.ui_px(24.0);
    let inner_w = (width - pad_x * 2.0).max(200.0);
    let now = Timestamp::now();

    let next_str = if routine.is_schedule_complete() {
        "Schedule complete".to_string()
    } else if !routine.enabled {
        "Paused".to_string()
    } else if let Some(nf) = routine.next_fire {
        format!("Next {}", format_relative_or_short(nf, now))
    } else {
        "Scheduled".to_string()
    };
    let cfg_label = state.settings.routine_config_label(routine);
    let cwd_display = abbreviate_tilde(&routine.working_directory);
    let meta_line = format!("{next_str} · {cfg_label} · {cwd_display}");

    let open_dir = state.actions.register_named(
        "routineOpenFolder",
        AppAction::OpenUrlOrPath(routine.working_directory.clone()),
    );
    let toggle_act = state.actions.register_named(
        "routineEnabled",
        AppAction::ToggleRoutineEnabled(routine.id.clone()),
    );
    let run_act = if running {
        state
            .actions
            .register_named("stopRoutine", AppAction::StopRoutine(routine.id.clone()))
    } else {
        state
            .actions
            .register_named("runNow", AppAction::RunRoutineNow(routine.id.clone()))
    };
    let edit_act = state
        .actions
        .register_named("editRoutine", AppAction::EditRoutine(routine.id.clone()));
    let hov = state.hovered_id.clone();

    let sw_prog = state.switch_progress("routineEnabled", routine.enabled, now_seconds);
    let controls = UiElement::row()
        .align_center()
        .gap(theme.ui_px(10.0))
        .flex_shrink(0.0)
        .child(labeled_switch_leading_animated(
            theme,
            "routineEnabled",
            "Scheduled",
            routine.enabled,
            sw_prog,
            !routine.is_schedule_complete(),
            toggle_act,
        ))
        .child(if running {
            button(
                theme,
                "stopRoutine",
                "Stop",
                Some(IconKind::Stop),
                run_act,
                false,
                true,
                true,
                hov.as_deref() == Some("stopRoutine"),
            )
        } else {
            button(
                theme,
                "runNow",
                "Run Now",
                Some(IconKind::Play),
                run_act,
                true,
                false,
                true,
                hov.as_deref() == Some("runNow"),
            )
        })
        .child(button(
            theme,
            "editRoutine",
            "Edit…",
            Some(IconKind::Sliders),
            edit_act,
            false,
            false,
            true,
            hov.as_deref() == Some("editRoutine"),
        ));

    let single_row = inner_w >= theme.ui_px(580.0);
    let sum_w = if single_row {
        (inner_w - theme.ui_px(330.0)).max(160.0)
    } else {
        inner_w
    };

    let summary_col = UiElement::column()
        .width(sum_w)
        .gap(theme.ui_px(3.0))
        .clip()
        .child(label_semibold_1line(
            routine.schedule_description(),
            theme.heading_size(),
            theme.text_primary,
            sum_w,
        ))
        .child(
            UiElement::row()
                .id("routineOpenFolder")
                .min_height(theme.ui_px(24.0))
                .align_center()
                .gap(theme.ui_px(5.0))
                .padding(Edges::xy(theme.ui_px(4.0), theme.ui_px(2.0)))
                .rounded(theme.ui_px(5.0))
                .bg(if hov.as_deref() == Some("routineOpenFolder") {
                    theme.subtle_hover
                } else {
                    Color::TRANSPARENT
                })
                .on_click(open_dir)
                .a11y(A11ySpec::new(A11yRole::Button, &cwd_display))
                .child(label_1line(
                    &meta_line,
                    theme.caption_size(),
                    theme.text_secondary,
                    sum_w - 24.0,
                ))
                .child(UiElement::icon(
                    IconKind::Folder,
                    theme.ui_px(12.0),
                    theme.text_muted,
                )),
        );

    let (hdr, hdr_h) = if single_row {
        (
            UiElement::row()
                .width(width)
                .align_center()
                .justify_between()
                .padding(Edges::xy(pad_x, theme.ui_px(12.0)))
                .bg(theme.surface)
                .clip()
                .child(summary_col)
                .child(controls),
            theme.ui_px(64.0),
        )
    } else {
        (
            UiElement::column()
                .width(width)
                .padding(Edges::new(theme.ui_px(8.0), pad_x, theme.ui_px(12.0), pad_x))
                .gap(theme.ui_px(8.0))
                .bg(theme.surface)
                .clip()
                .child(summary_col)
                .child(
                    UiElement::row()
                        .width(inner_w)
                        .align_center()
                        .justify_end()
                        .clip()
                        .child(controls),
                ),
            theme.ui_px(94.0),
        )
    };

    let scroll_h = (height - hdr_h - 1.0).max(120.0);
    let records = state.scheduler.records_for(&routine.id);

    if records.is_empty() {
        let empty = UiElement::column()
            .id("routineHistoryScroll")
            .width(width)
            .height(scroll_h)
            .align_center()
            .justify_center()
            .bg(theme.surface)
            .clip()
            .a11y(A11ySpec::new(A11yRole::Group, "Routine Sessions"))
            .child(UiElement::text(
                vec![TextSpan::new(
                    "No sessions yet",
                    theme.body_size(),
                    theme.text_secondary,
                )],
                TextLayoutOpts {
                    align: TextAlign::Center,
                    ..Default::default()
                },
            ));
        return UiElement::column()
            .width(width)
            .height(height)
            .bg(theme.surface)
            .clip()
            .child(hdr)
            .child(hairline_h(theme))
            .child(empty);
    }

    let mut list_col = UiElement::column()
        .width(width)
        .padding(Edges::xy(pad_x, theme.ui_px(12.0)))
        .gap(theme.ui_px(2.0));

    for (idx, rec) in records.iter().take(25).enumerate() {
        if idx > 0 {
            list_col = list_col.child(hairline_h(theme));
        }
        list_col = list_col.child(build_history_row(state, theme, rec, inner_w, pulse));
    }

    if state.routine_detail_scroll.item_count() == 0 {
        let est_h = 40.0 + (records.len().min(25) as f32) * theme.ui_px(72.0);
        state.routine_detail_scroll.set_heights(&[est_h], scroll_h);
    }
    let total_h = state.routine_detail_scroll.total_height();
    let eff_scroll_y = state.routine_detail_scroll.effective_scroll_y();
    let sb_active = state
        .dragging_scrollbar
        .as_ref()
        .is_some_and(|(k, _)| k == "routineDetail")
        || state.hovered_id.as_deref() == Some("scrollbarThumb-routineDetail");
    let sb_opt = interactive_scrollbar_overlay(
        theme,
        "routineDetail",
        &state.routine_detail_scroll,
        scroll_h,
        total_h,
        width,
        sb_active,
        now_seconds,
        &mut state.activity_clock,
    );

    let mut scroll_el = UiElement::column()
        .id("routineHistoryScroll")
        .width(width)
        .height(scroll_h)
        .bg(theme.surface)
        .clip()
        .scroll_offset(Point::new(0.0, eff_scroll_y))
        .a11y(A11ySpec::new(A11yRole::ScrollArea, "Routine Sessions"))
        .child(list_col.id("routineDetailContent"));
    if let Some(sb_thumb) = sb_opt {
        scroll_el = scroll_el.child(sb_thumb);
    }

    UiElement::column()
        .width(width)
        .height(height)
        .bg(theme.surface)
        .clip()
        .child(hdr)
        .child(hairline_h(theme))
        .child(scroll_el)
}

fn build_history_row(
    state: &mut AppState,
    theme: &Theme,
    record: &RunRecord,
    width: f32,
    pulse: Option<f32>,
) -> UiElement {
    let _ = pulse;
    let uuid_str = uppercase_uuid(record.id);
    let row_id = format!("sessionHistory-{uuid_str}");
    let hovered = state.hovered_id.as_deref() == Some(row_id.as_str());
    let tz = TimeZone::system();
    let date_str = ScheduleText::format_abbreviated_date_time(record.started_at, &tz);
    let preview = state
        .preview_cache
        .get(&(record.id, record.last_activity_at()))
        .cloned()
        .unwrap_or_else(|| SessionPreview::text(record, None));
    let model_str = state.settings.session_model_label(record);
    let dur = record
        .ended_at
        .map(|e| Transcript::readable_seconds((e.as_second() - record.started_at.as_second()).max(0) as u64));
    let lead_meta = if model_str == record.harness.title() {
        model_str
    } else {
        format!("{} · {model_str}", record.harness.title())
    };
    let meta = match dur {
        Some(d) => format!("{lead_meta} · {d}"),
        None => lead_meta,
    };

    // Authentic `SessionHistoryRow.swift`: SF Symbol per status, orange `BubbleAlert` + primary semibold text when `needs_attention`!
    let (status_txt, status_icon, ic_col, txt_col, semibold_status) = if record.needs_attention() {
        (
            "Needs your reply".to_string(),
            IconKind::BubbleAlert,
            theme.warning,
            theme.text_primary,
            true,
        )
    } else {
        match &record.outcome {
            RunOutcome::Running => (
                record.status_title(),
                IconKind::Clock,
                theme.accent,
                theme.accent,
                false,
            ),
            RunOutcome::Succeeded => (
                "Completed".to_string(),
                IconKind::CheckCircle,
                theme.text_muted,
                theme.text_secondary,
                false,
            ),
            RunOutcome::Cancelled => (
                "Stopped".to_string(),
                IconKind::StopCircle,
                theme.text_muted,
                theme.text_secondary,
                false,
            ),
            RunOutcome::Skipped(_) => (
                "Skipped".to_string(),
                IconKind::Clock,
                theme.text_muted,
                theme.text_secondary,
                false,
            ),
            _ => (
                record.status_title(),
                IconKind::Warning,
                theme.danger,
                theme.danger,
                true,
            ),
        }
    };

    let status_lbl = if semibold_status {
        label_semibold_1line(status_txt, theme.caption_size(), txt_col, 152.0)
    } else {
        label_1line(status_txt, theme.caption_size(), txt_col, 152.0)
    };
    let status_el = UiElement::row()
        .align_center()
        .gap(theme.ui_px(5.0))
        .flex_shrink(0.0)
        .child(UiElement::icon(status_icon, theme.ui_px(13.0), ic_col))
        .child(status_lbl);

    let inner_w = (width - theme.ui_px(16.0)).max(120.0);
    let mut box_el = UiElement::column()
        .id(row_id.clone())
        .width(width)
        .padding(Edges::xy(theme.ui_px(8.0), theme.ui_px(10.0)))
        .gap(theme.ui_px(4.5))
        .rounded(theme.ui_px(8.0))
        .bg(if hovered && !record.is_skip() {
            theme.subtle_hover
        } else {
            Color::TRANSPARENT
        })
        .clip()
        .a11y(A11ySpec::new(A11yRole::Button, &preview))
        .child(
            UiElement::row()
                .width(inner_w)
                .align_center()
                .justify_between()
                .clip()
                .child(label_1line(
                    &date_str,
                    theme.caption_size(),
                    theme.text_secondary,
                    inner_w * 0.56,
                ))
                .child(status_el),
        )
        .child(
            label_wrapped(&preview, theme.body_size(), theme.text_primary, inner_w, Some(2))
                .id(format!("sessionPreview-{uuid_str}")),
        )
        .child(
            UiElement::row()
                .align_center()
                .gap(theme.ui_px(6.0))
                .clip()
                .child(UiElement::icon(
                    harness_icon(record.harness),
                    theme.ui_px(13.0),
                    harness_color(theme, record.harness),
                ))
                .child(label_1line(
                    &meta,
                    theme.caption_size(),
                    theme.text_secondary,
                    inner_w - 22.0,
                )),
        );

    if !record.is_skip() {
        let open_act = state
            .actions
            .register_named(&row_id, AppAction::SelectSession(record.id));
        box_el = box_el.on_click(open_act);
    }
    box_el
}
