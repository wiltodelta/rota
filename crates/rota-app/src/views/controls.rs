//! Interactive form controls: switches, live-caret text editors, and overlay scrollbars.

use rota_ui::{
    A11yRole, A11ySpec, ActivityClock, CursorKind, Edges, FontFamily, Point, Rect, TextEditState,
    TextLayoutOpts, TextSpan, Theme, UiActionId, UiElement, VirtualScrollState,
};

use crate::views::widgets::label_1line;

pub fn toggle_switch(
    theme: &Theme,
    id: impl Into<String>,
    title: &str,
    on: bool,
    enabled: bool,
    action: UiActionId,
) -> UiElement {
    let track =
        crate::views::form_rows::build_switch_track_animated(theme, enabled, if on { 1.0 } else { 0.0 });

    let mut spec = A11ySpec::new(A11yRole::CheckBox, title);
    spec.value = Some(if on { "1" } else { "0" }.to_string());
    spec.selected = on;
    spec.enabled = enabled;
    let mut row = UiElement::row()
        .id(id)
        .min_height(theme.ui_px(24.0))
        .align_center()
        .gap(theme.ui_px(8.0))
        .flex_shrink(0.0)
        .a11y(spec)
        .child(track);
    if !title.is_empty() {
        row = row.child(label_1line(title, theme.body_size(), theme.text_primary, 240.0));
    }
    if enabled {
        row = row.on_click(action);
    }
    row
}

/// Renders `"Scheduled [switch]"` with the text label on the LEFT of the switch track (`RoutineDetail`).
pub fn labeled_switch_leading(
    theme: &Theme,
    id: impl Into<String>,
    title: &str,
    on: bool,
    enabled: bool,
    action: UiActionId,
) -> UiElement {
    labeled_switch_leading_animated(theme, id, title, on, if on { 1.0 } else { 0.0 }, enabled, action)
}

pub fn labeled_switch_leading_animated(
    theme: &Theme,
    id: impl Into<String>,
    title: &str,
    on: bool,
    progress: f32,
    enabled: bool,
    action: UiActionId,
) -> UiElement {
    let track = crate::views::form_rows::build_switch_track_animated(theme, enabled, progress);
    let mut spec = A11ySpec::new(A11yRole::CheckBox, title);
    spec.value = Some(if on { "1" } else { "0" }.to_string());
    spec.selected = on;
    spec.enabled = enabled;
    let mut row = UiElement::row()
        .id(id)
        .min_height(theme.ui_px(28.0))
        .align_center()
        .gap(theme.ui_px(8.0))
        .flex_shrink(0.0)
        .a11y(spec);
    if !title.is_empty() {
        row = row.child(label_1line(
            title,
            theme.body_size(),
            if enabled {
                theme.text_primary
            } else {
                theme.text_muted
            },
            180.0,
        ));
    }
    row = row.child(track);
    if enabled {
        row = row.on_click(action);
    }
    row
}

#[allow(clippy::too_many_arguments)]
pub fn text_field_box(
    theme: &Theme,
    id: impl Into<String>,
    a11y_title: &str,
    placeholder: &str,
    state: &TextEditState,
    focused: bool,
    mono: bool,
    width: f32,
    min_height: f32,
    focus_action: UiActionId,
) -> UiElement {
    text_editor_internal_preedit(
        theme,
        id,
        a11y_title,
        placeholder,
        state,
        "",
        focused,
        mono,
        true,
        width,
        min_height,
        focus_action,
    )
}

#[allow(clippy::too_many_arguments)]
pub fn borderless_text_editor(
    theme: &Theme,
    id: impl Into<String>,
    a11y_title: &str,
    placeholder: &str,
    state: &TextEditState,
    focused: bool,
    mono: bool,
    width: f32,
    min_height: f32,
    focus_action: UiActionId,
) -> UiElement {
    borderless_text_editor_with_preedit(
        theme,
        id,
        a11y_title,
        placeholder,
        state,
        "",
        focused,
        mono,
        width,
        min_height,
        focus_action,
    )
}

#[allow(clippy::too_many_arguments)]
pub fn borderless_text_editor_with_preedit(
    theme: &Theme,
    id: impl Into<String>,
    a11y_title: &str,
    placeholder: &str,
    state: &TextEditState,
    preedit: &str,
    focused: bool,
    mono: bool,
    width: f32,
    min_height: f32,
    focus_action: UiActionId,
) -> UiElement {
    text_editor_internal_preedit(
        theme,
        id,
        a11y_title,
        placeholder,
        state,
        preedit,
        focused,
        mono,
        false,
        width,
        min_height,
        focus_action,
    )
}

#[allow(clippy::too_many_arguments)]
fn text_editor_internal_preedit(
    theme: &Theme,
    id: impl Into<String>,
    a11y_title: &str,
    placeholder: &str,
    state: &TextEditState,
    preedit: &str,
    focused: bool,
    mono: bool,
    framed: bool,
    width: f32,
    min_height: f32,
    focus_action: UiActionId,
) -> UiElement {
    let text = state.text();
    let font = if mono {
        FontFamily::Mono
    } else {
        FontFamily::UiSans
    };
    let (pad_x, pad_y) = if framed {
        (theme.ui_px(10.0), theme.ui_px(7.0))
    } else {
        (theme.ui_px(2.0), theme.ui_px(2.0))
    };
    let inner_w = (width - pad_x * 2.0).max(16.0);
    let font_sz = theme.body_size();

    let id_str: String = id.into();
    let text_node_id = format!("{id_str}-text");
    let spans = if text.is_empty() && (!focused || preedit.is_empty()) {
        vec![TextSpan::new(placeholder, font_sz, theme.text_muted).font(font)]
    } else if focused && !preedit.is_empty() {
        let cur = state.cursor().min(text.len());
        let mut pre_span = TextSpan::new(preedit, font_sz, theme.text_primary).font(font);
        pre_span.underline = true;
        vec![
            TextSpan::new(&text[..cur], font_sz, theme.text_primary).font(font),
            pre_span,
            TextSpan::new(&text[cur..], font_sz, theme.text_primary).font(font),
        ]
    } else if focused && state.has_selection() {
        let sel = state.selection_range();
        let s0 = sel.start.min(text.len());
        let s1 = sel.end.min(text.len());
        vec![
            TextSpan::new(&text[..s0], font_sz, theme.text_primary).font(font),
            TextSpan::new(&text[s0..s1], font_sz, theme.text_primary)
                .font(font)
                .background(theme.selection_fill.with_alpha(0.24)),
            TextSpan::new(&text[s1..], font_sz, theme.text_primary).font(font),
        ]
    } else {
        vec![TextSpan::new(text, font_sz, theme.text_primary).font(font)]
    };

    let role = if state.multiline {
        A11yRole::TextArea
    } else {
        A11yRole::TextField
    };
    let mut spec = A11ySpec::new(role, a11y_title);
    spec.value = Some(text.to_string());
    spec.focused = focused;

    let mut outer = UiElement::column()
        .id(id_str)
        .width(width)
        .padding(Edges::xy(pad_x, pad_y))
        .flex_shrink(0.0)
        .clip()
        .on_click(focus_action)
        .cursor(CursorKind::IBeam)
        .a11y(spec);
    if framed {
        outer = outer.rounded(theme.ui_px(8.0)).bg(theme.elevated).border(
            if focused { 1.5 } else { 1.0 },
            if focused {
                theme.selection_fill
            } else {
                theme.border
            },
        );
    }
    let single_focused = !state.multiline && focused && !text.is_empty();
    let max_text_w = if single_focused {
        Some(4096.0)
    } else {
        Some(inner_w)
    };
    let scroll_pt = if single_focused {
        Point::new(state.scroll_x, 0.0)
    } else {
        Point::ZERO
    };
    outer.child(
        UiElement::column()
            .width(inner_w)
            .height(min_height.max(theme.ui_px(20.0)))
            .clip()
            .scroll_offset(scroll_pt)
            .child(
                UiElement::text(
                    spans,
                    TextLayoutOpts {
                        max_width: max_text_w,
                        max_lines: if state.multiline { Some(8) } else { Some(1) },
                        line_height_factor: 1.44,
                        ..Default::default()
                    },
                )
                .id(text_node_id)
                .width(if single_focused { 4096.0 } else { inner_w }),
            ),
    )
}

#[allow(clippy::too_many_arguments)]
pub fn interactive_scrollbar_overlay(
    theme: &Theme,
    key: &str,
    scroll: &VirtualScrollState,
    viewport_h: f32,
    total_h: f32,
    right_x: f32,
    hovered_or_dragging: bool,
    now_seconds: f64,
    clock: &mut ActivityClock,
) -> Option<UiElement> {
    let alpha = scroll
        .physics
        .scrollbar_alpha(now_seconds, hovered_or_dragging, clock);
    let thumb_alpha = if hovered_or_dragging { 0.58 } else { 0.48 * alpha };
    scrollbar_overlay_styled(
        theme,
        Some(format!("scrollbarThumb-{key}")),
        scroll.effective_scroll_y(),
        viewport_h,
        total_h,
        right_x,
        hovered_or_dragging,
        thumb_alpha,
    )
}

#[allow(clippy::too_many_arguments)]
fn scrollbar_overlay_styled(
    theme: &Theme,
    id_opt: Option<String>,
    scroll_y: f32,
    viewport_h: f32,
    total_h: f32,
    right_x: f32,
    expanded: bool,
    alpha: f32,
) -> Option<UiElement> {
    if total_h <= viewport_h + 8.0 || viewport_h < 40.0 {
        return None;
    }
    let track_pad = 6.0;
    let track_h = (viewport_h - track_pad * 2.0).max(24.0);
    let ratio = (viewport_h / total_h).clamp(0.08, 0.92);
    let thumb_h = (track_h * ratio).max(24.0);
    let max_scroll = (total_h - viewport_h).max(1.0);
    let frac = (scroll_y / max_scroll).clamp(0.0, 1.0);
    let thumb_y = scroll_y + track_pad + (track_h - thumb_h) * frac;
    let w = if expanded { 7.5 } else { 5.0 };
    let hit_w = 14.0;
    let visual = UiElement::row()
        .width(w)
        .height(thumb_h)
        .rounded(w * 0.5)
        .bg(theme.text_muted.with_alpha(alpha));
    let mut el = UiElement::row()
        .absolute(Rect::new(right_x - hit_w - 2.0, thumb_y, hit_w, thumb_h))
        .justify_end()
        .padding(Edges::new(0.0, 2.5, 0.0, 0.0))
        .z_layer(1, false)
        .child(visual);
    if let Some(id) = id_opt {
        el = el.id(id).hit_box().cursor(CursorKind::PointingHand);
    }
    Some(el)
}
