//! 7-day `ScheduleView` day cells (`ScheduleDayDots` + filled Today circle) and 2-line `CalendarAgendaRow`s.

use jiff::tz::TimeZone;
use rota_core::schedule::{CalendarDay, CalendarEntry, ScheduleText};
use rota_ui::{
    A11yRole, A11ySpec, Color, Edges, FontWeight, IconKind, TextAlign, TextLayoutOpts, TextSpan, Theme,
    UiElement,
};

use crate::actions::AppAction;
use crate::app_state::AppState;
use crate::views::widgets::{harness_color, harness_icon, label_1line, label_semibold_1line, mono_text};

pub fn build_day_cell(
    state: &mut AppState,
    theme: &Theme,
    day: &CalendarDay,
    width: f32,
    tz: &TimeZone,
) -> UiElement {
    let z = day.date.to_zoned(tz.clone());
    let wds = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
    let wd = wds[z.weekday().to_sunday_zero_offset() as usize];
    let day_num = format!("{}", z.day());
    let selected = state.schedule_state.selected_day == Some(day.date);
    let cell_id = format!("scheduleDay-{}", day.id);
    let act = state
        .actions
        .register_named(&cell_id, AppAction::ScheduleSelectDay(day.date.as_second()));
    let hovered = state.is_hovered(&cell_id);

    let mut spec = A11ySpec::new(A11yRole::Button, format!("{wd} {day_num}"));
    spec.selected = selected;

    // Today's date number sits inside a crisp 26x26 filled accent circle (`CalendarComponents.swift`)!
    let badge_sz = theme.ui_px(26.0);
    let day_badge = UiElement::row()
        .width(badge_sz)
        .height(badge_sz)
        .align_center()
        .justify_center()
        .rounded(badge_sz * 0.5)
        .bg(if day.is_today {
            theme.selection_fill
        } else {
            Color::TRANSPARENT
        })
        .child(UiElement::text(
            vec![
                TextSpan::new(
                    day_num,
                    theme.body_size(),
                    if day.is_today {
                        Color::WHITE
                    } else {
                        theme.text_primary
                    },
                )
                .weight(FontWeight::Semibold),
            ],
            TextLayoutOpts {
                align: TextAlign::Center,
                ..Default::default()
            },
        ));

    let sched_n = day.scheduled_count();
    let skip_n = day.recorded_count();
    let dot_sz = theme.ui_px(5.0);
    let mut dots_row = UiElement::row()
        .height(theme.ui_px(8.0))
        .align_center()
        .justify_center()
        .gap(theme.ui_px(3.0));

    if sched_n == 0 && skip_n == 0 {
        dots_row = dots_row.child(
            UiElement::row()
                .width(dot_sz)
                .height(dot_sz)
                .rounded(dot_sz * 0.5)
                .bg(theme.text_muted.with_alpha(0.22)),
        );
    } else {
        for _ in 0..sched_n.min(4) {
            dots_row = dots_row.child(
                UiElement::row()
                    .width(dot_sz)
                    .height(dot_sz)
                    .rounded(dot_sz * 0.5)
                    .bg(theme.selection_fill),
            );
        }
        if sched_n > 4 {
            dots_row = dots_row.child(label_1line("+", theme.ui_px(9.5), theme.selection_fill, 10.0));
        }
        if skip_n > 0 {
            dots_row = dots_row.child(
                UiElement::row()
                    .width(dot_sz)
                    .height(dot_sz)
                    .rounded(dot_sz * 0.5)
                    .bg(theme.warning),
            );
        }
    }

    UiElement::column()
        .id(cell_id)
        .width(width)
        .height(theme.ui_px(64.0))
        .align_center()
        .justify_center()
        .gap(theme.ui_px(3.0))
        .padding(Edges::xy(theme.ui_px(4.0), theme.ui_px(6.0)))
        .rounded(theme.ui_px(10.0))
        .bg(if hovered {
            theme.subtle_hover
        } else {
            Color::TRANSPARENT
        })
        .border(
            if selected { 1.5 } else { 0.0 },
            if selected {
                theme.selection_fill
            } else {
                Color::TRANSPARENT
            },
        )
        .clip()
        .on_click(act)
        .a11y(spec)
        .child(UiElement::text(
            vec![TextSpan::new(
                wd,
                theme.ui_px(11.0),
                if day.is_today {
                    theme.selection_fill
                } else {
                    theme.text_secondary
                },
            )],
            TextLayoutOpts {
                align: TextAlign::Center,
                ..Default::default()
            },
        ))
        .child(day_badge)
        .child(dots_row)
}

pub fn build_agenda_row(
    state: &mut AppState,
    theme: &Theme,
    entry: &CalendarEntry,
    width: f32,
    tz: &TimeZone,
) -> UiElement {
    let time_str = ScheduleText::format_short_time(entry.start, tz);
    let (status_ic, status_lbl, status_col) = if entry.is_frequent() {
        (
            IconKind::Repeat,
            format!("{} runs", entry.count),
            theme.text_secondary,
        )
    } else if let Some(rec) = entry.record() {
        (IconKind::Clock, rec.compact_status_title(false), theme.warning)
    } else if entry.is_paused() {
        (IconKind::PauseCircle, "Paused".to_string(), theme.text_muted)
    } else {
        (IconKind::Clock, "Scheduled".to_string(), theme.text_secondary)
    };

    let cfg_label = state
        .routines
        .iter()
        .find(|r| r.id == entry.routine_id)
        .map_or_else(
            || entry.harness.title().to_string(),
            |r| state.settings.routine_config_label(r),
        );
    let sub_meta = match entry.schedule_summary.as_deref() {
        Some(s) if !s.is_empty() => format!("{cfg_label} · {s}"),
        _ => cfg_label,
    };

    let el_id = format!("scheduleEntry-{}", entry.id);
    let hovered = state.is_hovered(&el_id);
    let act = state
        .actions
        .register_named(&el_id, AppAction::SelectRoutine(entry.routine_id.clone()));

    let time_col_w = theme.ui_px(62.0);
    let mid_w = (width - time_col_w - theme.ui_px(104.0)).max(90.0);

    UiElement::row()
        .id(el_id)
        .width(width)
        .align_center()
        .justify_between()
        .padding(Edges::xy(theme.ui_px(8.0), theme.ui_px(9.0)))
        .rounded(theme.ui_px(8.0))
        .bg(if hovered {
            theme.subtle_hover
        } else {
            Color::TRANSPARENT
        })
        .clip()
        .on_click(act)
        .a11y(A11ySpec::new(A11yRole::Button, &entry.routine_name))
        .child(
            UiElement::row()
                .align_center()
                .gap(theme.ui_px(10.0))
                .clip()
                .child(mono_text(
                    time_str,
                    theme.caption_size(),
                    theme.text_secondary,
                    time_col_w,
                    Some(1),
                ))
                .child(
                    UiElement::column()
                        .width(mid_w)
                        .gap(theme.ui_px(2.5))
                        .clip()
                        .child(label_semibold_1line(
                            &entry.routine_name,
                            theme.body_size(),
                            theme.text_primary,
                            mid_w,
                        ))
                        .child(
                            UiElement::row()
                                .align_center()
                                .gap(theme.ui_px(5.0))
                                .clip()
                                .child(UiElement::icon(
                                    harness_icon(entry.harness),
                                    theme.ui_px(12.5),
                                    harness_color(theme, entry.harness),
                                ))
                                .child(label_1line(
                                    &sub_meta,
                                    theme.caption_size(),
                                    theme.text_secondary,
                                    (mid_w - theme.ui_px(18.0)).max(48.0),
                                )),
                        ),
                ),
        )
        .child(
            UiElement::row()
                .align_center()
                .gap(theme.ui_px(5.0))
                .flex_shrink(0.0)
                .child(UiElement::icon(status_ic, theme.ui_px(12.5), status_col))
                .child(label_1line(&status_lbl, theme.caption_size(), status_col, 108.0)),
        )
}
