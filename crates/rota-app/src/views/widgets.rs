//! Tahoe-grade UI widgets: real `HarnessStatusIcon`, tactile pill buttons, cards, and date formatting.

use jiff::Timestamp;
use jiff::tz::TimeZone;
use rota_core::model::{Harness, Routine, RunOutcome, RunRecord};
use rota_core::schedule::ScheduleText;
use rota_ui::{
    A11yRole, A11ySpec, Color, Edges, FontFamily, FontWeight, IconKind, Point, Rect, TextLayoutOpts,
    TextSpan, Theme, UiActionId, UiElement,
};

pub use crate::views::controls::{
    borderless_text_editor, borderless_text_editor_with_preedit, interactive_scrollbar_overlay,
    labeled_switch_leading, labeled_switch_leading_animated, text_field_box, toggle_switch,
};

pub fn harness_icon(harness: Harness) -> IconKind {
    match harness {
        Harness::Claude => IconKind::Claude,
        Harness::Codex => IconKind::Codex,
        Harness::Grok => IconKind::Grok,
        Harness::Antigravity => IconKind::Antigravity,
        Harness::Shell => IconKind::Shell,
    }
}

pub fn harness_color(theme: &Theme, harness: Harness) -> Color {
    match harness {
        Harness::Claude => theme.badge_claude,
        Harness::Codex => theme.badge_codex,
        Harness::Grok => theme.badge_grok,
        Harness::Antigravity => theme.badge_antigravity,
        Harness::Shell => theme.badge_shell,
    }
}

/// Renders a 20 pt official harness mark inside a 26x26 slot with an overlapping bottom-right status dot and cutout ring.
pub fn harness_status_icon(
    theme: &Theme,
    harness: Harness,
    status_color: Color,
    row_selected: bool,
    cutout_bg: Color,
) -> UiElement {
    let slot = theme.ui_px(28.0);
    let icon_sz = theme.ui_px(20.0);
    let ring_sz = theme.ui_px(11.5);
    let dot_sz = theme.ui_px(7.5);
    let icon_col = if row_selected {
        theme.selection_text
    } else {
        theme.text_primary
    };
    let ring_pad = (ring_sz - dot_sz) * 0.5;

    UiElement::row()
        .width(slot)
        .height(slot)
        .align_center()
        .padding(Edges::all(theme.ui_px(2.5)))
        .flex_shrink(0.0)
        .child(UiElement::icon(harness_icon(harness), icon_sz, icon_col))
        .child(
            UiElement::row()
                .absolute(Rect::new(slot - ring_sz, slot - ring_sz, ring_sz, ring_sz))
                .align_center()
                .padding(Edges::all(ring_pad))
                .rounded(ring_sz * 0.5)
                .bg(cutout_bg)
                .child(
                    UiElement::row()
                        .width(dot_sz)
                        .height(dot_sz)
                        .rounded(dot_sz * 0.5)
                        .bg(status_color),
                ),
        )
}

pub fn label_1line(text: impl Into<String>, size: f32, color: Color, max_w: f32) -> UiElement {
    UiElement::text(
        vec![TextSpan::new(text, size, color)],
        TextLayoutOpts {
            max_width: Some(max_w.max(8.0)),
            max_lines: Some(1),
            ..Default::default()
        },
    )
}

pub fn label_semibold_1line(text: impl Into<String>, size: f32, color: Color, max_w: f32) -> UiElement {
    UiElement::text(
        vec![TextSpan::new(text, size, color).weight(FontWeight::Semibold)],
        TextLayoutOpts {
            max_width: Some(max_w.max(8.0)),
            max_lines: Some(1),
            ..Default::default()
        },
    )
}

pub fn label_wrapped(
    text: impl Into<String>,
    size: f32,
    color: Color,
    max_w: f32,
    max_lines: Option<usize>,
) -> UiElement {
    UiElement::text(
        vec![TextSpan::new(text, size, color)],
        TextLayoutOpts {
            max_width: Some(max_w.max(8.0)),
            max_lines,
            line_height_factor: 1.42,
            ..Default::default()
        },
    )
}

pub fn mono_text(
    text: impl Into<String>,
    size: f32,
    color: Color,
    max_w: f32,
    max_lines: Option<usize>,
) -> UiElement {
    UiElement::text(
        vec![TextSpan::new(text, size, color).font(FontFamily::Mono)],
        TextLayoutOpts {
            max_width: Some(max_w.max(8.0)),
            max_lines,
            line_height_factor: 1.45,
            ..Default::default()
        },
    )
}

pub fn hairline_h(theme: &Theme) -> UiElement {
    let mut el = UiElement::row()
        .height(1.0)
        .bg(theme.subtle_border)
        .flex_shrink(0.0);
    el.style.size.width = UiElement::default().fill_size().style.size.width;
    el
}

pub fn status_pill(theme: &Theme, record: &RunRecord, pulse_alpha: Option<f32>) -> UiElement {
    let (label, color) = if record.needs_attention() {
        ("Needs your reply".to_string(), theme.warning)
    } else {
        match &record.outcome {
            RunOutcome::Running => (record.status_title(), theme.accent),
            RunOutcome::Succeeded => ("Completed".to_string(), theme.success),
            RunOutcome::Cancelled => ("Stopped".to_string(), theme.text_muted),
            _ => (record.status_title(), theme.danger),
        }
    };
    let dot = UiElement::row()
        .width(theme.ui_px(6.5))
        .height(theme.ui_px(6.5))
        .rounded(theme.ui_px(3.25))
        .bg(color.with_alpha(pulse_alpha.unwrap_or(1.0)))
        .flex_shrink(0.0);

    UiElement::row()
        .align_center()
        .gap(theme.ui_px(5.0))
        .flex_shrink(0.0)
        .child(dot)
        .child(label_semibold_1line(label, theme.caption_size(), color, 150.0))
}

#[allow(clippy::too_many_arguments)]
pub fn button(
    theme: &Theme,
    id: impl Into<String>,
    label: &str,
    icon: Option<IconKind>,
    action: UiActionId,
    primary: bool,
    danger: bool,
    enabled: bool,
    hovered: bool,
) -> UiElement {
    let h = theme.ui_px(28.0);
    let (bg, fg, border, has_shadow) = if !enabled {
        (
            theme.subtle_hover.with_alpha(0.55),
            theme.text_muted,
            Color::TRANSPARENT,
            false,
        )
    } else if primary {
        let fill = if hovered {
            theme.accent_hover
        } else {
            theme.selection_fill
        };
        (fill, Color::WHITE, fill, true)
    } else if danger {
        let fill = theme.danger.with_alpha(if hovered { 0.18 } else { 0.11 });
        (fill, theme.danger, theme.danger.with_alpha(0.32), false)
    } else {
        (
            if hovered {
                theme.subtle_hover
            } else {
                theme.elevated
            },
            theme.text_primary,
            theme.border,
            true,
        )
    };

    let mut spec = A11ySpec::new(A11yRole::Button, label);
    spec.enabled = enabled;
    let mut row = UiElement::row()
        .id(id.into())
        .align_center()
        .justify_center()
        .gap(theme.ui_px(6.0))
        .height(h)
        .padding(Edges::xy(theme.ui_px(12.0), theme.ui_px(4.0)))
        .rounded(h * 0.5)
        .bg(bg)
        .border(1.0, border)
        .flex_shrink(0.0)
        .a11y(spec);
    if has_shadow {
        row = row.shadow(6.0, Point::new(0.0, 1.5), theme.shadow_color);
    }
    if enabled {
        row = row.on_click(action);
    }
    if let Some(ic) = icon {
        row = row.child(UiElement::icon(ic, theme.ui_px(13.5), fg));
    }
    row.child(
        UiElement::text(
            vec![TextSpan::new(label, theme.body_size(), fg).weight(FontWeight::Medium)],
            TextLayoutOpts {
                max_lines: Some(1),
                ..Default::default()
            },
        )
        .flex_shrink(0.0),
    )
}

#[allow(clippy::too_many_arguments)]
pub fn popup_button(
    theme: &Theme,
    id: impl Into<String>,
    label: &str,
    icon: Option<IconKind>,
    action: UiActionId,
    enabled: bool,
    hovered: bool,
) -> UiElement {
    popup_button_with_value(theme, id, label, label, icon, action, enabled, hovered)
}

#[allow(clippy::too_many_arguments)]
pub fn popup_button_with_value(
    theme: &Theme,
    id: impl Into<String>,
    label: &str,
    a11y_value: &str,
    icon: Option<IconKind>,
    action: UiActionId,
    enabled: bool,
    hovered: bool,
) -> UiElement {
    let mut btn = button(theme, id, label, icon, action, false, false, enabled, hovered);
    if let Some(spec) = btn.a11y.as_mut() {
        spec.role = A11yRole::PopUpButton;
        spec.value = Some(a11y_value.to_string());
    }
    if enabled {
        btn = btn.child(UiElement::icon(
            IconKind::ChevronDown,
            theme.ui_px(10.5),
            theme.text_secondary,
        ));
    }
    btn
}

#[allow(clippy::too_many_arguments)]
pub fn icon_button(
    theme: &Theme,
    id: impl Into<String>,
    title: &str,
    icon: IconKind,
    action: UiActionId,
    selected: bool,
    enabled: bool,
    hovered: bool,
) -> UiElement {
    let fg = if !enabled {
        theme.text_muted.with_alpha(0.55)
    } else if selected {
        theme.selection_fill
    } else {
        theme.text_primary
    };
    let bg = if selected {
        theme.selection_fill.with_alpha(0.14)
    } else if hovered && enabled {
        theme.subtle_hover
    } else {
        Color::TRANSPARENT
    };
    let sz = theme.ui_px(28.0);
    let mut spec = A11ySpec::new(A11yRole::Button, title);
    spec.selected = selected;
    spec.enabled = enabled;
    let mut btn = UiElement::row()
        .id(id)
        .width(sz)
        .height(sz)
        .align_center()
        .justify_center()
        .rounded(sz * 0.5)
        .bg(bg)
        .flex_shrink(0.0)
        .tooltip(title)
        .a11y(spec)
        .child(UiElement::icon(icon, theme.ui_px(15.0), fg));
    if enabled {
        btn = btn.on_click(action);
    }
    btn
}

#[allow(clippy::too_many_arguments)]
pub fn circle_action_button(
    theme: &Theme,
    id: impl Into<String>,
    title: &str,
    icon: IconKind,
    action: UiActionId,
    primary: bool,
    danger: bool,
    enabled: bool,
    hovered: bool,
) -> UiElement {
    let sz = theme.ui_px(28.0);
    let (bg, fg, border) = if !enabled {
        (
            theme.subtle_hover.with_alpha(0.75),
            theme.text_muted.with_alpha(0.65),
            Color::TRANSPARENT,
        )
    } else if danger {
        (
            theme.danger.with_alpha(if hovered { 0.22 } else { 0.14 }),
            theme.danger,
            theme.danger.with_alpha(0.30),
        )
    } else if primary {
        (
            if hovered {
                theme.accent_hover
            } else {
                theme.selection_fill
            },
            Color::WHITE,
            Color::TRANSPARENT,
        )
    } else {
        (
            if hovered {
                theme.subtle_hover
            } else {
                theme.elevated
            },
            theme.text_secondary,
            theme.border,
        )
    };
    let mut spec = A11ySpec::new(A11yRole::Button, title);
    spec.enabled = enabled;
    let mut btn = UiElement::row()
        .id(id)
        .width(sz)
        .height(sz)
        .align_center()
        .justify_center()
        .rounded(sz * 0.5)
        .bg(bg)
        .border(1.0, border)
        .flex_shrink(0.0)
        .tooltip(title)
        .a11y(spec)
        .child(UiElement::icon(icon, theme.ui_px(15.0), fg));
    if enabled {
        btn = btn.on_click(action);
    }
    btn
}

pub fn card(theme: &Theme, width: f32) -> UiElement {
    UiElement::column()
        .width(width)
        .padding(Edges::all(theme.ui_px(16.0)))
        .gap(theme.ui_px(12.0))
        .rounded(theme.ui_px(12.0))
        .bg(theme.elevated)
        .border(1.0, theme.border)
        .shadow(4.0, Point::new(0.0, 1.0), theme.shadow_color.with_alpha(0.04))
        .clip()
}

pub fn modal_card(theme: &Theme, id: &str, title: &str, width: f32, height: f32) -> UiElement {
    UiElement::column()
        .id(id)
        .width(width)
        .height(height)
        .rounded(theme.ui_px(16.0))
        .bg(theme.elevated)
        .border(1.0, theme.border)
        .shadow(24.0, Point::new(0.0, 10.0), theme.shadow_color)
        .clip()
        .a11y(A11ySpec::new(A11yRole::Group, title))
}

pub fn routine_next_subtitle(routine: &Routine, running: bool, now: Timestamp) -> String {
    if running {
        return format!("Running on {}", routine.harness.title());
    }
    if routine.is_schedule_complete() {
        return format!("{}, schedule complete", routine.harness.title());
    }
    let Some(next) = routine.next_fire.filter(|_| routine.enabled) else {
        return format!("{}, paused", routine.harness.title());
    };
    format!(
        "{}, next {}",
        routine.harness.title(),
        format_relative_or_short(next, now)
    )
}

pub fn format_relative_or_short(target: Timestamp, now: Timestamp) -> String {
    let diff = target.as_second() - now.as_second();
    if (0..3600).contains(&diff) {
        return format!("in {}m", (diff / 60).max(1));
    }
    if (3600..86400).contains(&diff) {
        return format!("in {}h", diff / 3600);
    }
    let tz = TimeZone::system();
    let z = target.to_zoned(tz.clone());
    let months = [
        "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    ];
    let mon = months[(z.month() as usize).saturating_sub(1)];
    format!(
        "{mon} {}, {}",
        z.day(),
        ScheduleText::format_short_time(target, &tz)
    )
}

pub fn day_group_title(ts: Timestamp, now: Timestamp) -> String {
    let tz = TimeZone::system();
    let d = ts.to_zoned(tz.clone()).date();
    let today = now.to_zoned(tz).date();
    if d == today {
        return "Today".to_string();
    }
    if today.yesterday().ok() == Some(d) {
        return "Yesterday".to_string();
    }
    let months = [
        "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    ];
    let days = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
    format!(
        "{}, {} {}",
        days[d.weekday().to_sunday_zero_offset() as usize],
        months[(d.month() as usize).saturating_sub(1)],
        d.day()
    )
}
