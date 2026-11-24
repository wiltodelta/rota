//! Tahoe floating sidebar (`routineSidebar`): traffic-light inset, real `HarnessStatusIcon`, vibrant selection pill, `sessionFilter` button, and scrollbar.

use jiff::Timestamp;
use rota_core::model::serde_ext::uppercase_uuid;
use rota_core::model::{Routine, RunOutcome, RunRecord};
use rota_core::transcript::SessionPreview;
use rota_ui::{
    A11yRole, A11ySpec, Color, Edges, FontWeight, IconKind, Point, TextLayoutOpts, TextSpan, Theme, UiElement,
};

use crate::actions::{AppAction, FocusTarget, SidebarSelection};
use crate::app_state::AppState;
use crate::views::sidebar_filters::build_sessions_filter_header;
use crate::views::widgets::{
    day_group_title, hairline_h, harness_status_icon, label_1line, label_semibold_1line,
    routine_next_subtitle,
};

pub fn build_main_sidebar(
    state: &mut AppState,
    theme: &Theme,
    width: f32,
    height: f32,
    now_seconds: f64,
) -> UiElement {
    let top_inset = theme.ui_px(42.0);
    let footer_h = theme.ui_px(42.0);
    let list_h = (height - top_inset - footer_h - 1.0).max(80.0);
    let pad_x = theme.ui_px(10.0);
    let inner_w = (width - pad_x * 2.0).max(160.0);
    let sb_bg = if state.window_vibrant {
        Color::TRANSPARENT
    } else {
        theme.sidebar
    };
    let now = Timestamp::now();
    let pulse = if state.running_count > 0 {
        state.activity_clock.pulse_opacity(now_seconds)
    } else {
        1.0
    };

    let section_hdr = |title: &str, top: f32| {
        UiElement::row()
            .width(inner_w)
            .padding(Edges::new(
                theme.ui_px(top),
                theme.ui_px(8.0),
                theme.ui_px(3.0),
                theme.ui_px(8.0),
            ))
            .child(
                label_semibold_1line(title, theme.caption_size(), theme.text_muted, inner_w - 16.0)
                    .a11y(A11ySpec::new(A11yRole::Heading, title)),
            )
    };
    let empty_row = |id: &str, msg: &str| {
        UiElement::row()
            .id(id)
            .width(inner_w)
            .padding(Edges::xy(theme.ui_px(8.0), theme.ui_px(8.0)))
            .child(label_1line(
                msg,
                theme.body_size(),
                theme.text_muted,
                inner_w - 16.0,
            ))
            .a11y(A11ySpec::new(A11yRole::StaticText, msg))
    };

    let mut list_content = UiElement::column()
        .id("sidebarContent")
        .width(width)
        .padding(Edges::new(theme.ui_px(4.0), pad_x, theme.ui_px(12.0), pad_x))
        .gap(theme.ui_px(2.0))
        .child(section_hdr("Routines", 2.0));

    if state.routines.is_empty() {
        list_content = list_content.child(empty_row("sidebarEmpty", "No routines yet"));
    } else {
        let routines = state.routines.clone();
        for routine in &routines {
            list_content = list_content.child(build_routine_row(state, theme, routine, inner_w, now, pulse));
        }
    }

    let filter_section = build_sessions_filter_header(state, theme, inner_w);
    list_content = list_content
        .child(UiElement::row().height(theme.ui_px(5.0)))
        .child(filter_section);

    let visible = state.visible_sessions();
    if visible.is_empty() {
        let msg = if state.sessions.is_empty() {
            "No sessions yet"
        } else {
            "No matching sessions"
        };
        list_content = list_content.child(empty_row("sessionFilterEmpty", msg));
    } else {
        let mut current_day = String::new();
        for rec in &visible {
            let group_label = day_group_title(rec.last_activity_at(), now);
            if group_label != current_day {
                current_day = group_label;
                list_content = list_content.child(section_hdr(&current_day, 6.0));
            }
            list_content = list_content.child(build_session_row(state, theme, rec, inner_w, pulse));
        }
    }

    let measured_h = state.sidebar_scroll.total_height().max(
        110.0
            + (state.routines.len() as f32) * theme.ui_px(48.0)
            + (visible.len() as f32) * theme.ui_px(66.0),
    );
    if state.sidebar_scroll.item_count() == 0 {
        state.sidebar_scroll.set_heights(&[measured_h], list_h);
    }
    let total_sb_h = state.sidebar_scroll.total_height();
    let eff_scroll_y = state.sidebar_scroll.effective_scroll_y();
    let sb_drag_or_hov = state
        .dragging_scrollbar
        .as_ref()
        .is_some_and(|(k, _)| k == "sidebar")
        || state.hovered_id.as_deref() == Some("scrollbarThumb-sidebar");
    let sb_overlay = crate::views::widgets::interactive_scrollbar_overlay(
        theme,
        "sidebar",
        &state.sidebar_scroll,
        list_h,
        total_sb_h,
        width,
        sb_drag_or_hov,
        now_seconds,
        &mut state.activity_clock,
    );
    let mut sb_spec = A11ySpec::new(A11yRole::ScrollArea, "Routines and Sessions");
    sb_spec.focused = state.focus == Some(FocusTarget::Sidebar);

    let mut scroll_area = UiElement::column()
        .id("routineSidebar")
        .width(width)
        .height(list_h)
        .clip()
        .scroll_offset(Point::new(0.0, eff_scroll_y))
        .a11y(sb_spec)
        .child(list_content);
    if let Some(sb_thumb) = sb_overlay {
        scroll_area = scroll_area.child(sb_thumb);
    }

    let open_settings_act = state
        .actions
        .register_named("sidebarSettings", AppAction::OpenSettings(None));
    let settings_hovered = state.is_hovered("sidebarSettings");
    let settings_footer = UiElement::row()
        .width(width)
        .height(footer_h)
        .align_center()
        .padding(Edges::xy(pad_x, theme.ui_px(5.0)))
        .child(
            UiElement::row()
                .id("sidebarSettings")
                .width(inner_w)
                .height(theme.ui_px(28.0))
                .align_center()
                .gap(theme.ui_px(8.0))
                .padding(Edges::xy(theme.ui_px(8.0), theme.ui_px(4.0)))
                .rounded(theme.ui_px(8.0))
                .bg(if settings_hovered {
                    theme.subtle_hover
                } else {
                    Color::TRANSPARENT
                })
                .on_click(open_settings_act)
                .a11y(A11ySpec::new(A11yRole::Button, "Settings"))
                .child(UiElement::icon(
                    IconKind::Settings,
                    theme.ui_px(15.0),
                    theme.text_secondary,
                ))
                .child(label_1line(
                    "Settings",
                    theme.body_size(),
                    theme.text_secondary,
                    width - theme.ui_px(60.0),
                )),
        );

    UiElement::column()
        .width(width)
        .height(height)
        .bg(sb_bg)
        .clip()
        .child(UiElement::row().width(width).height(top_inset))
        .child(scroll_area)
        .child(hairline_h(theme))
        .child(settings_footer)
}

fn build_routine_row(
    state: &mut AppState,
    theme: &Theme,
    routine: &Routine,
    width: f32,
    now: Timestamp,
    pulse: f32,
) -> UiElement {
    let row_id = format!("routineRow-{}", routine.id);
    let selected = state.selection == Some(SidebarSelection::Routine(routine.id.clone()));
    let hovered = state.hovered_id.as_deref() == Some(row_id.as_str());
    let running = state.scheduler.is_running(&routine.id);
    let last_failed = state
        .sessions
        .iter()
        .find(|s| s.routine_id == routine.id && !s.is_skip())
        .is_some_and(|s| s.outcome.is_failure());

    let dot_col = if running {
        theme.accent.with_alpha(pulse)
    } else if last_failed {
        theme.danger
    } else if routine.enabled {
        theme.success
    } else {
        theme.text_muted.with_alpha(0.65)
    };
    let (bg, title_col, sub_col, cutout) = if selected {
        (
            theme.selection_fill,
            theme.selection_text,
            theme.selection_text.with_alpha(0.84),
            theme.selection_fill,
        )
    } else if hovered {
        (
            theme.subtle_hover,
            theme.text_primary,
            theme.text_secondary,
            theme.subtle_hover,
        )
    } else {
        (
            Color::TRANSPARENT,
            theme.text_primary,
            theme.text_secondary,
            theme.sidebar,
        )
    };
    let act = state
        .actions
        .register_named(&row_id, AppAction::SelectRoutine(routine.id.clone()));
    let text_w = (width - theme.ui_px(50.0)).max(60.0);
    let subtitle = routine_next_subtitle(routine, running, now);

    let text_col = UiElement::column()
        .width(text_w)
        .gap(theme.ui_px(1.5))
        .clip()
        .child(
            UiElement::text(
                vec![TextSpan::new(&routine.name, theme.body_size(), title_col).weight(FontWeight::Medium)],
                TextLayoutOpts {
                    max_width: Some(text_w),
                    max_lines: Some(1),
                    ..Default::default()
                },
            )
            .a11y(A11ySpec::new(A11yRole::StaticText, &routine.name)),
        )
        .child(
            label_1line(&subtitle, theme.caption_size(), sub_col, text_w)
                .id(format!("routineHarness-{}", routine.id))
                .a11y(A11ySpec::new(A11yRole::StaticText, subtitle)),
        );

    let mut spec = A11ySpec::new(A11yRole::Row, &routine.name);
    spec.selected = selected;
    UiElement::row()
        .id(row_id)
        .width(width)
        .align_center()
        .gap(theme.ui_px(9.0))
        .padding(Edges::xy(theme.ui_px(8.0), theme.ui_px(4.5)))
        .rounded(theme.ui_px(9.0))
        .bg(bg)
        .clip()
        .on_click(act)
        .a11y(spec)
        .child(harness_status_icon(
            theme,
            routine.harness,
            dot_col,
            selected,
            cutout,
        ))
        .child(text_col)
}

fn build_session_row(
    state: &mut AppState,
    theme: &Theme,
    record: &RunRecord,
    width: f32,
    pulse: f32,
) -> UiElement {
    let uuid_str = uppercase_uuid(record.id);
    let row_id = format!("sessionRow-{uuid_str}");
    let selected = state.selection == Some(SidebarSelection::Session(record.id));
    let hovered = state.hovered_id.as_deref() == Some(row_id.as_str());
    let (bg, title_col, sub_col, meta_col, cutout) = if selected {
        (
            theme.selection_fill,
            theme.selection_text,
            theme.selection_text.with_alpha(0.86),
            theme.selection_text.with_alpha(0.76),
            theme.selection_fill,
        )
    } else if hovered {
        (
            theme.subtle_hover,
            theme.text_primary,
            theme.text_secondary,
            theme.text_muted,
            theme.subtle_hover,
        )
    } else {
        (
            Color::TRANSPARENT,
            theme.text_primary,
            theme.text_secondary,
            theme.text_muted,
            theme.sidebar,
        )
    };
    let act = state
        .actions
        .register_named(&row_id, AppAction::SelectSession(record.id));

    let routine_name = state
        .routines
        .iter()
        .find(|r| r.id == record.routine_id)
        .map_or_else(|| record.routine_id.clone(), |r| r.name.clone());
    let preview = state
        .preview_cache
        .get(&(record.id, record.last_activity_at()))
        .cloned()
        .unwrap_or_else(|| SessionPreview::text(record, None));
    let time_str = rota_core::schedule::ScheduleText::format_short_time(
        record.last_activity_at(),
        &jiff::tz::TimeZone::system(),
    );
    let meta = format!(
        "{} · {time_str} · {}",
        record.harness.title(),
        record.compact_status_title(record.harness.takes_messages())
    );

    let status_col = if record.outcome == RunOutcome::Running {
        theme.accent.with_alpha(pulse)
    } else if record.needs_attention() {
        theme.warning
    } else if record.outcome.is_failure() {
        theme.danger
    } else {
        theme.success
    };

    let has_badge = record.needs_attention() || record.is_unread();
    let text_w = (width - theme.ui_px(if has_badge { 68.0 } else { 50.0 })).max(60.0);
    let pw = if record.is_unread() {
        FontWeight::Semibold
    } else {
        FontWeight::Regular
    };
    let body = UiElement::column()
        .width(text_w)
        .gap(theme.ui_px(1.5))
        .clip()
        .child(
            UiElement::text(
                vec![TextSpan::new(&preview, theme.body_size(), title_col).weight(pw)],
                TextLayoutOpts {
                    max_width: Some(text_w),
                    max_lines: Some(2),
                    line_height_factor: 1.22,
                    ..Default::default()
                },
            )
            .id(format!("sidebarPreview-{uuid_str}"))
            .a11y(A11ySpec::new(A11yRole::StaticText, &preview)),
        )
        .child(
            label_1line(&routine_name, theme.caption_size(), sub_col, text_w)
                .a11y(A11ySpec::new(A11yRole::StaticText, &routine_name)),
        )
        .child(
            label_1line(&meta, theme.ui_px(11.0), meta_col, text_w)
                .id(format!("sessionHarness-{uuid_str}"))
                .a11y(A11ySpec::new(A11yRole::StaticText, &meta)),
        );

    let mut rspec = A11ySpec::new(A11yRole::Row, routine_name);
    rspec.selected = selected;
    let mut row = UiElement::row()
        .id(row_id)
        .width(width)
        .align_center()
        .gap(theme.ui_px(9.0))
        .padding(Edges::xy(theme.ui_px(8.0), theme.ui_px(5.0)))
        .rounded(theme.ui_px(9.0))
        .bg(bg)
        .clip()
        .on_click(act)
        .a11y(rspec)
        .child(harness_status_icon(
            theme,
            record.harness,
            status_col,
            selected,
            cutout,
        ))
        .child(body);

    if record.needs_attention() {
        row = row.child(UiElement::icon(
            IconKind::BubbleAlert,
            theme.ui_px(15.0),
            if selected { Color::WHITE } else { theme.warning },
        ));
    } else if record.is_unread() {
        let u = theme.ui_px(8.5);
        row = row.child(
            UiElement::row()
                .width(u)
                .height(u)
                .rounded(u * 0.5)
                .bg(theme.selection_fill)
                .border(
                    if selected { 1.5 } else { 0.0 },
                    if selected {
                        Color::WHITE
                    } else {
                        Color::TRANSPARENT
                    },
                )
                .flex_shrink(0.0),
        );
    }
    row
}
