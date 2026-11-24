//! Native macOS Tahoe grouped-form sections, labeled rows, trailing switches, and horizontal sliders.

use rota_ui::{
    A11yRole, A11ySpec, Appearance, Color, CursorKind, Edges, IconKind, Point, Rect, Theme, UiActionId,
    UiElement, lerp_color,
};

use crate::views::widgets::{hairline_h, label_1line, label_semibold_1line, label_wrapped};

pub fn form_card_surface(theme: &Theme) -> Color {
    match theme.appearance {
        Appearance::Light => theme.elevated,
        Appearance::Dark => theme.elevated,
    }
}

pub fn form_page_bg(theme: &Theme) -> Color {
    match theme.appearance {
        Appearance::Light => theme.canvas,
        Appearance::Dark => theme.surface,
    }
}

/// Builds a native macOS `.formStyle(.grouped)` section: optional heading above a rounded card,
/// inset hairline-divided rows inside the card, and an optional explanatory footer caption below.
pub fn form_section(
    theme: &Theme,
    heading: Option<(&str, Option<&str>)>,
    width: f32,
    rows: Vec<UiElement>,
    footer: Option<(&str, Option<&str>)>,
) -> UiElement {
    let mut col = UiElement::column().width(width).gap(theme.ui_px(6.0)).clip();

    if let Some((title, id_opt)) = heading {
        let mut h = label_semibold_1line(title, theme.body_size(), theme.text_primary, width - 8.0)
            .a11y(A11ySpec::new(A11yRole::Heading, title));
        if let Some(hid) = id_opt {
            h = h.id(hid);
        }
        col = col.child(
            UiElement::row()
                .width(width)
                .padding(Edges::new(
                    theme.ui_px(2.0),
                    theme.ui_px(4.0),
                    0.0,
                    theme.ui_px(4.0),
                ))
                .child(h),
        );
    }

    let mut box_el = UiElement::column()
        .width(width)
        .rounded(theme.ui_px(11.0))
        .bg(form_card_surface(theme))
        .border(1.0, theme.border)
        .clip();

    for (idx, row) in rows.into_iter().enumerate() {
        if idx > 0 {
            box_el = box_el.child(
                UiElement::row()
                    .width(width)
                    .padding(Edges::xy(theme.ui_px(14.0), 0.0))
                    .child(hairline_h(theme)),
            );
        }
        box_el = box_el.child(row);
    }
    col = col.child(box_el);

    if let Some((ftr, fid_opt)) = footer {
        let mut f = label_wrapped(
            ftr,
            theme.caption_size(),
            theme.text_secondary,
            width - 8.0,
            Some(3),
        )
        .a11y(A11ySpec::new(A11yRole::StaticText, ftr));
        if let Some(fid) = fid_opt {
            f = f.id(fid);
        }
        col = col.child(
            UiElement::row()
                .width(width)
                .padding(Edges::xy(theme.ui_px(4.0), 0.0))
                .child(f),
        );
    }

    col
}

/// Standard grouped-form row: `label` on the left, `trailing` control on the right.
pub fn form_row(theme: &Theme, label: &str, width: f32, trailing: UiElement) -> UiElement {
    let pad_x = theme.ui_px(14.0);
    let inner_w = (width - pad_x * 2.0).max(120.0);
    UiElement::row()
        .width(width)
        .min_height(theme.ui_px(38.0))
        .align_center()
        .justify_between()
        .gap(theme.ui_px(12.0))
        .padding(Edges::xy(pad_x, theme.ui_px(7.0)))
        .clip()
        .child(
            label_1line(label, theme.body_size(), theme.text_primary, inner_w * 0.52)
                .a11y(A11ySpec::new(A11yRole::StaticText, label)),
        )
        .child(trailing)
}

/// Two-line grouped-form row: primary label + optional icon/status caption on the left, control on the right.
pub fn form_row_with_status(
    theme: &Theme,
    label: &str,
    lead_icon: Option<(IconKind, Color)>,
    status: Option<(&str, IconKind, Color)>,
    width: f32,
    trailing: UiElement,
) -> UiElement {
    let pad_x = theme.ui_px(14.0);
    let left_w = ((width - pad_x * 2.0) * 0.54).max(110.0);

    let mut title_row = UiElement::row().align_center().gap(theme.ui_px(6.0)).clip();
    if let Some((ic, col)) = lead_icon {
        title_row = title_row.child(UiElement::icon(ic, theme.ui_px(14.0), col));
    }
    title_row = title_row.child(
        label_1line(label, theme.body_size(), theme.text_primary, left_w - 22.0)
            .a11y(A11ySpec::new(A11yRole::StaticText, label)),
    );

    let mut left_col = UiElement::column()
        .width(left_w)
        .gap(theme.ui_px(2.5))
        .clip()
        .child(title_row);

    if let Some((st_txt, st_ic, st_col)) = status {
        left_col = left_col.child(
            UiElement::row()
                .align_center()
                .gap(theme.ui_px(4.5))
                .clip()
                .child(UiElement::icon(st_ic, theme.ui_px(11.5), st_col))
                .child(label_1line(st_txt, theme.caption_size(), st_col, left_w - 18.0)),
        );
    }

    UiElement::row()
        .width(width)
        .min_height(theme.ui_px(44.0))
        .align_center()
        .justify_between()
        .gap(theme.ui_px(10.0))
        .padding(Edges::xy(pad_x, theme.ui_px(8.0)))
        .clip()
        .child(left_col)
        .child(trailing)
}

#[allow(clippy::too_many_arguments)]
pub fn form_toggle_row_animated(
    theme: &Theme,
    id: impl Into<String>,
    label: &str,
    width: f32,
    on: bool,
    progress: f32,
    enabled: bool,
    action: UiActionId,
) -> UiElement {
    let pad_x = theme.ui_px(14.0);
    let inner_w = (width - pad_x * 2.0).max(120.0);
    let switch_track = build_switch_track_animated(theme, enabled, progress);

    let mut spec = A11ySpec::new(A11yRole::CheckBox, label);
    spec.value = Some(if on { "1" } else { "0" }.to_string());
    spec.selected = on;
    spec.enabled = enabled;

    let mut row = UiElement::row()
        .id(id)
        .width(width)
        .min_height(theme.ui_px(38.0))
        .align_center()
        .justify_between()
        .gap(theme.ui_px(12.0))
        .padding(Edges::xy(pad_x, theme.ui_px(7.0)))
        .clip()
        .a11y(spec)
        .child(label_1line(
            label,
            theme.body_size(),
            if enabled {
                theme.text_primary
            } else {
                theme.text_muted
            },
            inner_w - theme.ui_px(52.0),
        ))
        .child(switch_track);
    if enabled {
        row = row.on_click(action);
    }
    row
}

/// Full-width grouped-form toggle row (`InterfaceFormToggleStyle`): label on the left, switch on the right.
pub fn form_toggle_row(
    theme: &Theme,
    id: impl Into<String>,
    label: &str,
    width: f32,
    on: bool,
    enabled: bool,
    action: UiActionId,
) -> UiElement {
    form_toggle_row_animated(
        theme,
        id,
        label,
        width,
        on,
        if on { 1.0 } else { 0.0 },
        enabled,
        action,
    )
}

pub(crate) fn build_switch_track_animated(theme: &Theme, enabled: bool, progress: f32) -> UiElement {
    let p = progress.clamp(0.0, 1.0);
    let (track_w, track_h, knob) = (theme.ui_px(36.0), theme.ui_px(20.0), theme.ui_px(16.0));
    let track_bg = if !enabled {
        theme.subtle_hover
    } else {
        lerp_color(theme.control_track, theme.selection_fill, p)
    };
    let min_pad = theme.ui_px(2.0);
    let max_pad = track_w - knob - min_pad;
    let left_pad = min_pad + (max_pad - min_pad) * p;
    UiElement::row()
        .width(track_w)
        .height(track_h)
        .align_center()
        .padding(Edges::new(0.0, 0.0, 0.0, left_pad))
        .rounded(track_h * 0.5)
        .bg(track_bg)
        .flex_shrink(0.0)
        .child(
            UiElement::row()
                .width(knob)
                .height(knob)
                .rounded(knob * 0.5)
                .bg(Color::WHITE)
                .shadow(2.5, Point::new(0.0, 1.0), Color::BLACK.with_alpha(0.20)),
        )
}

/// Interactive horizontal `AXSlider` (`min..=max`) with accent fill bar and elevated circular thumb.
pub fn slider_control(
    theme: &Theme,
    id: impl Into<String>,
    title: &str,
    value: f32,
    min: f32,
    max: f32,
    width: f32,
) -> UiElement {
    let h = theme.ui_px(24.0);
    let track_h = theme.ui_px(4.5);
    let thumb = theme.ui_px(16.0);
    let frac = ((value - min) / (max - min).max(0.001)).clamp(0.0, 1.0);
    let usable_w = (width - thumb).max(8.0);
    let thumb_x = usable_w * frac;
    let fill_w = (thumb_x + thumb * 0.5).clamp(track_h, width);

    let mut spec = A11ySpec::new(A11yRole::Slider, title);
    spec.value = Some(format!("{value:.2}"));

    UiElement::row()
        .id(id)
        .width(width)
        .height(h)
        .align_center()
        .flex_shrink(0.0)
        .hit_box()
        .cursor(CursorKind::PointingHand)
        .a11y(spec)
        .child(
            // Unfilled track (>= 3.0:1 WCAG 1.4.11 non-text contrast)
            UiElement::row()
                .absolute(Rect::new(0.0, (h - track_h) * 0.5, width, track_h))
                .rounded(track_h * 0.5)
                .bg(theme.control_track),
        )
        .child(
            // Accent filled track
            UiElement::row()
                .absolute(Rect::new(0.0, (h - track_h) * 0.5, fill_w, track_h))
                .rounded(track_h * 0.5)
                .bg(theme.selection_fill),
        )
        .child(
            // Elevated Tahoe thumb (>= 3.0:1 border contrast)
            UiElement::row()
                .absolute(Rect::new(thumb_x, (h - thumb) * 0.5, thumb, thumb))
                .rounded(thumb * 0.5)
                .bg(Color::WHITE)
                .border(1.0, theme.control_thumb_border)
                .shadow(3.0, Point::new(0.0, 1.0), Color::BLACK.with_alpha(0.24)),
        )
}
