//! 7-day `ScheduleView` (`id: "scheduleView"`): 2-line header (`scheduleNextRun`), joined `[ < | Today | > ]` capsule, multi-dot strip, and agenda list.

use jiff::Timestamp;
use jiff::tz::TimeZone;
use rota_core::model::RunRecord;
use rota_core::schedule::{CalendarDay, CalendarQuery, ScheduleCalendar, ScheduleText};
use rota_ui::{
    A11yRole, A11ySpec, Color, Edges, FontWeight, IconKind, Point, TextAlign, TextLayoutOpts, TextSpan,
    Theme, UiElement,
};

use crate::actions::{AppAction, MenuId};
use crate::app_state::AppState;
use crate::views::schedule_rows::{build_agenda_row, build_day_cell};
use crate::views::widgets::{
    button, circle_action_button, format_relative_or_short, hairline_h, label_1line, label_semibold_1line,
};

pub fn build_schedule_view(
    state: &mut AppState,
    theme: &Theme,
    width: f32,
    height: f32,
    now_seconds: f64,
) -> UiElement {
    let tz = TimeZone::system();
    let now = Timestamp::now();
    let (win_start, win_end) = ScheduleCalendar::agenda_interval(state.schedule_state.start_day, 7, &tz);
    let skips: Vec<RunRecord> = state
        .routines
        .iter()
        .flat_map(|r| state.scheduler.records_for(&r.id))
        .filter(|rec| rec.is_skip() && rec.started_at >= win_start && rec.started_at < win_end)
        .collect();
    let query = CalendarQuery {
        start: win_start,
        end: win_end,
        now,
        include_paused: state.settings.show_paused_in_schedule,
        routine_id: None,
        tz: tz.clone(),
    };
    let days = ScheduleCalendar::days(&query, &state.routines, &skips);

    let pad_x = theme.ui_px(24.0);
    let inner_w = (width - pad_x * 2.0).max(220.0);

    let period_title = match (days.first(), days.last()) {
        (Some(f), Some(l)) => format!(
            "{} - {}",
            ScheduleText::format_day_header(&f.id, &tz),
            ScheduleText::format_day_header(&l.id, &tz)
        ),
        _ => "Schedule".to_string(),
    };

    let all_paused = !state.routines.is_empty() && state.routines.iter().all(|r| !r.enabled);
    let next_subtitle = if let Some((r, nf)) = state
        .routines
        .iter()
        .filter(|r| r.enabled)
        .filter_map(|r| r.next_fire.map(|nf| (r, nf)))
        .min_by_key(|(_, nf)| *nf)
    {
        format!("Next: {} {}", r.name, format_relative_or_short(nf, now))
    } else if all_paused {
        "All routines are paused".to_string()
    } else {
        "Nothing scheduled in these seven days".to_string()
    };

    let prev_act = state
        .actions
        .register_named("schedulePrevious", AppAction::ScheduleStepWeeks(-1));
    let today_act = state
        .actions
        .register_named("scheduleToday", AppAction::ScheduleToday);
    let next_act = state
        .actions
        .register_named("scheduleNext", AppAction::ScheduleStepWeeks(1));
    let opts_act = state
        .actions
        .register_named("scheduleOptions", AppAction::OpenMenu(MenuId::ScheduleOptions));
    let hov = state.hovered_id.clone();

    let nav_h = theme.ui_px(28.0);
    let nav_capsule = UiElement::row()
        .height(nav_h)
        .align_center()
        .rounded(nav_h * 0.5)
        .bg(theme.elevated)
        .border(1.0, theme.border)
        .shadow(6.0, Point::new(0.0, 1.5), theme.shadow_color)
        .clip()
        .flex_shrink(0.0)
        .child(
            UiElement::row()
                .id("schedulePrevious")
                .width(theme.ui_px(30.0))
                .height(nav_h)
                .align_center()
                .justify_center()
                .bg(if hov.as_deref() == Some("schedulePrevious") {
                    theme.subtle_hover
                } else {
                    Color::TRANSPARENT
                })
                .on_click(prev_act)
                .tooltip("Previous Week")
                .a11y(A11ySpec::new(A11yRole::Button, "Previous Week"))
                .child(UiElement::icon(
                    IconKind::Back,
                    theme.ui_px(12.0),
                    theme.text_primary,
                )),
        )
        .child(
            UiElement::column()
                .width(1.0)
                .height(theme.ui_px(16.0))
                .bg(theme.subtle_border),
        )
        .child(
            UiElement::row()
                .id("scheduleToday")
                .height(nav_h)
                .align_center()
                .padding(Edges::xy(theme.ui_px(11.0), 0.0))
                .bg(if hov.as_deref() == Some("scheduleToday") {
                    theme.subtle_hover
                } else {
                    Color::TRANSPARENT
                })
                .on_click(today_act)
                .a11y(A11ySpec::new(A11yRole::Button, "Today"))
                .child(UiElement::text(
                    vec![
                        TextSpan::new("Today", theme.body_size(), theme.text_primary)
                            .weight(FontWeight::Medium),
                    ],
                    TextLayoutOpts {
                        max_lines: Some(1),
                        ..Default::default()
                    },
                )),
        )
        .child(
            UiElement::column()
                .width(1.0)
                .height(theme.ui_px(16.0))
                .bg(theme.subtle_border),
        )
        .child(
            UiElement::row()
                .id("scheduleNext")
                .width(theme.ui_px(30.0))
                .height(nav_h)
                .align_center()
                .justify_center()
                .bg(if hov.as_deref() == Some("scheduleNext") {
                    theme.subtle_hover
                } else {
                    Color::TRANSPARENT
                })
                .on_click(next_act)
                .tooltip("Next Week")
                .a11y(A11ySpec::new(A11yRole::Button, "Next Week"))
                .child(UiElement::icon(
                    IconKind::ChevronRight,
                    theme.ui_px(12.0),
                    theme.text_primary,
                )),
        );

    let mut p_spec = A11ySpec::new(A11yRole::Heading, &period_title);
    p_spec.value = Some(period_title.clone());
    let title_w = (inner_w - theme.ui_px(164.0)).max(120.0);

    let hdr = UiElement::row()
        .width(width)
        .align_center()
        .justify_between()
        .padding(Edges::new(theme.ui_px(10.0), pad_x, theme.ui_px(6.0), pad_x))
        .bg(theme.surface)
        .clip()
        .child(
            UiElement::column()
                .width(title_w)
                .gap(theme.ui_px(2.0))
                .clip()
                .child(
                    UiElement::text(
                        vec![
                            TextSpan::new(&period_title, theme.heading_size(), theme.text_primary)
                                .weight(FontWeight::Semibold),
                        ],
                        TextLayoutOpts {
                            max_width: Some(title_w),
                            max_lines: Some(2),
                            line_height_factor: 1.24,
                            ..Default::default()
                        },
                    )
                    .id("schedulePeriodTitle")
                    .a11y(p_spec),
                )
                .child(
                    label_1line(
                        &next_subtitle,
                        theme.caption_size(),
                        theme.text_secondary,
                        title_w,
                    )
                    .id("scheduleNextRun")
                    .a11y(A11ySpec::new(A11yRole::StaticText, &next_subtitle)),
                ),
        )
        .child(
            UiElement::row()
                .align_center()
                .gap(theme.ui_px(8.0))
                .flex_shrink(0.0)
                .child(circle_action_button(
                    theme,
                    "scheduleOptions",
                    "Schedule Options",
                    IconKind::Filter,
                    opts_act,
                    state.settings.show_paused_in_schedule,
                    false,
                    true,
                    hov.as_deref() == Some("scheduleOptions"),
                ))
                .child(nav_capsule),
        );

    let cell_w = ((inner_w - theme.ui_px(6.0) * 6.0) / 7.0).floor().max(32.0);
    let mut strip = UiElement::row()
        .id("scheduleWeekStrip")
        .width(width)
        .gap(theme.ui_px(6.0))
        .padding(Edges::xy(pad_x, theme.ui_px(8.0)))
        .bg(theme.surface)
        .clip()
        .a11y(A11ySpec::new(A11yRole::Group, "Week"));

    for day in &days {
        strip = strip.child(build_day_cell(state, theme, day, cell_w, &tz));
    }

    let list_h = (height - theme.ui_px(134.0)).max(100.0);
    let filled: Vec<&CalendarDay> = days.iter().filter(|d| !d.entries.is_empty()).collect();

    if filled.is_empty() {
        let show_paused_btn = all_paused && !state.settings.show_paused_in_schedule;
        let desc = if show_paused_btn {
            "All routines are paused. Show paused routines to preview their scheduled times."
        } else {
            "No runs are scheduled in these seven days."
        };
        let mut empty_col = UiElement::column()
            .width(inner_w.min(400.0))
            .align_center()
            .gap(theme.ui_px(8.0))
            .child(UiElement::icon(
                IconKind::Calendar,
                theme.ui_px(30.0),
                theme.text_muted,
            ))
            .child(UiElement::text(
                vec![
                    TextSpan::new("Nothing scheduled", theme.heading_size(), theme.text_primary)
                        .weight(FontWeight::Semibold),
                ],
                TextLayoutOpts {
                    align: TextAlign::Center,
                    ..Default::default()
                },
            ))
            .child(UiElement::text(
                vec![TextSpan::new(desc, theme.body_size(), theme.text_secondary)],
                TextLayoutOpts {
                    max_width: Some(inner_w.min(380.0)),
                    max_lines: Some(3),
                    line_height_factor: 1.45,
                    align: TextAlign::Center,
                },
            ));
        if show_paused_btn {
            let sp_act = state
                .actions
                .register_named("scheduleShowPaused", AppAction::ToggleShowPausedInSchedule);
            empty_col = empty_col.child(button(
                theme,
                "scheduleShowPaused",
                "Show Paused Routines",
                None,
                sp_act,
                false,
                false,
                true,
                hov.as_deref() == Some("scheduleShowPaused"),
            ));
        }

        let sc_empty = UiElement::column()
            .id("scheduleList")
            .width(width)
            .height(list_h)
            .align_center()
            .justify_center()
            .bg(theme.surface)
            .clip()
            .a11y(A11ySpec::new(A11yRole::ScrollArea, "Scheduled Runs"))
            .child(empty_col);

        return UiElement::column()
            .id("scheduleView")
            .width(width)
            .height(height)
            .bg(theme.surface)
            .clip()
            .a11y(A11ySpec::new(A11yRole::Group, "Schedule"))
            .child(hdr)
            .child(strip)
            .child(hairline_h(theme))
            .child(sc_empty);
    }

    let mut agenda = UiElement::column()
        .width(width)
        .padding(Edges::xy(pad_x, theme.ui_px(12.0)))
        .gap(theme.ui_px(8.0));

    for (d_idx, day) in filled.iter().enumerate() {
        if d_idx > 0 {
            agenda = agenda.child(UiElement::row().height(theme.ui_px(6.0)));
        }
        let base_hdr = ScheduleText::format_day_header(&day.id, &tz);
        let day_hdr = if day.is_today {
            format!("Today · {base_hdr}")
        } else {
            base_hdr
        };
        let total_runs: usize = day.entries.iter().map(|e| e.count.max(1)).sum();
        let count_lbl = if total_runs == 1 {
            "1 run".to_string()
        } else {
            format!("{total_runs} runs")
        };

        agenda = agenda.child(
            UiElement::row()
                .id(format!("scheduleDayHeader-{}", day.id))
                .width(inner_w)
                .align_center()
                .justify_between()
                .padding(Edges::xy(theme.ui_px(4.0), theme.ui_px(2.0)))
                .child(label_semibold_1line(
                    &day_hdr,
                    theme.caption_size(),
                    if day.is_today {
                        theme.selection_fill
                    } else {
                        theme.text_secondary
                    },
                    inner_w - 80.0,
                ))
                .child(label_1line(
                    count_lbl,
                    theme.caption_size(),
                    theme.text_muted,
                    72.0,
                )),
        );

        for (e_idx, entry) in day.entries.iter().enumerate() {
            if e_idx > 0 {
                agenda = agenda.child(hairline_h(theme));
            }
            agenda = agenda.child(build_agenda_row(state, theme, entry, inner_w, &tz));
        }
    }

    if state.schedule_state.scroll.item_count() == 0 {
        let total_entries: usize = days.iter().map(|d| d.entries.len()).sum();
        let est_h = 120.0 + (total_entries as f32) * theme.ui_px(58.0);
        state.schedule_state.scroll.set_heights(&[est_h], list_h);
    }
    let total_h = state.schedule_state.scroll.total_height();
    let eff_scroll_y = state.schedule_state.scroll.effective_scroll_y();
    let sb_active = state
        .dragging_scrollbar
        .as_ref()
        .is_some_and(|(k, _)| k == "schedule")
        || state.hovered_id.as_deref() == Some("scrollbarThumb-schedule");
    let sb_opt = crate::views::widgets::interactive_scrollbar_overlay(
        theme,
        "schedule",
        &state.schedule_state.scroll,
        list_h,
        total_h,
        width,
        sb_active,
        now_seconds,
        &mut state.activity_clock,
    );
    let mut sc_list = UiElement::column()
        .id("scheduleList")
        .width(width)
        .height(list_h)
        .bg(theme.surface)
        .clip()
        .scroll_offset(Point::new(0.0, eff_scroll_y))
        .a11y(A11ySpec::new(A11yRole::ScrollArea, "Scheduled Runs"))
        .child(agenda.id("scheduleContent"));
    if let Some(sb) = sb_opt {
        sc_list = sc_list.child(sb);
    }

    UiElement::column()
        .id("scheduleView")
        .width(width)
        .height(height)
        .bg(theme.surface)
        .clip()
        .a11y(A11ySpec::new(A11yRole::Group, "Schedule"))
        .child(hdr)
        .child(strip)
        .child(hairline_h(theme))
        .child(sc_list)
}
