//! Main Window empty-state `ContentUnavailableView` placeholders (`MainWindow.swift:165-206`) and Delete confirmation modal.

use rota_ui::{
    A11yRole, A11ySpec, Edges, FontWeight, IconKind, Size, TextAlign, TextLayoutOpts, TextSpan, Theme,
    UiElement,
};

use crate::actions::AppAction;
use crate::app_state::AppState;
use crate::views::widgets::{button, label_semibold_1line, label_wrapped, modal_card};

pub fn build_empty_placeholder(state: &mut AppState, theme: &Theme, width: f32, height: f32) -> UiElement {
    let content_w = (width - 80.0).clamp(240.0, 440.0);
    let filtered_empty = !state.sessions.is_empty() && state.visible_sessions().is_empty();

    let (icon, heading, body) = if state.routines.is_empty() {
        (
            IconKind::Calendar,
            "No routines yet",
            "A routine runs a prompt or a command on a schedule. Each run becomes a session here.",
        )
    } else if state.sessions.is_empty() {
        (
            IconKind::Bubbles,
            "No sessions yet",
            "Routines start a session when they run. Pick a routine and choose Run Now.",
        )
    } else if filtered_empty {
        (
            IconKind::Filter,
            "No matching sessions",
            "Try another session filter.",
        )
    } else {
        (
            IconKind::Bubbles,
            "Select a session",
            "Choose a routine or session in the sidebar.",
        )
    };

    let mut box_col = UiElement::column()
        .width(content_w)
        .align_center()
        .gap(theme.ui_px(10.0))
        .padding(Edges::all(theme.ui_px(16.0)))
        .clip()
        .child(UiElement::icon(icon, theme.ui_px(32.0), theme.text_muted))
        .child(UiElement::text(
            vec![TextSpan::new(heading, theme.ui_px(17.0), theme.text_primary).weight(FontWeight::Semibold)],
            TextLayoutOpts {
                max_width: Some(content_w - 32.0),
                align: TextAlign::Center,
                ..Default::default()
            },
        ))
        .child(UiElement::text(
            vec![TextSpan::new(body, theme.body_size(), theme.text_secondary)],
            TextLayoutOpts {
                max_width: Some(content_w - 32.0),
                max_lines: Some(3),
                line_height_factor: 1.45,
                align: TextAlign::Center,
            },
        ));

    let hov = state.hovered_id.clone();
    if state.routines.is_empty() {
        let imp_act = state.actions.register(AppAction::OpenImportSheet);
        let new_act = state.actions.register(AppAction::OpenNewRoutine);
        box_col = box_col.child(
            UiElement::row()
                .padding(Edges::new(theme.ui_px(6.0), 0.0, 0.0, 0.0))
                .gap(theme.ui_px(10.0))
                .child(button(
                    theme,
                    "emptyImport",
                    "Import Routines…",
                    Some(IconKind::Import),
                    imp_act,
                    false,
                    false,
                    true,
                    hov.as_deref() == Some("emptyImport"),
                ))
                .child(button(
                    theme,
                    "emptyNewRoutine",
                    "New Routine…",
                    Some(IconKind::Plus),
                    new_act,
                    true,
                    false,
                    true,
                    hov.as_deref() == Some("emptyNewRoutine"),
                )),
        );
    } else if filtered_empty {
        let rst_act = state.actions.register(AppAction::ResetSessionFilters);
        box_col = box_col.child(button(
            theme,
            "resetSessionFilter",
            "Show All Sessions",
            None,
            rst_act,
            false,
            false,
            true,
            hov.as_deref() == Some("resetSessionFilter"),
        ));
    }

    UiElement::column()
        .width(width)
        .height(height)
        .align_center()
        .padding(Edges::xy(0.0, (height * 0.24).max(28.0)))
        .bg(theme.surface)
        .clip()
        .child(box_col)
}

pub fn build_import_empty_box(theme: &Theme, inner_w: f32, query: &str, imported_count: usize) -> UiElement {
    let empty_heading = if !query.is_empty() {
        "No matching routines"
    } else {
        "No routines to import"
    };
    let empty_sub = if !query.is_empty() {
        "Try another search query."
    } else if imported_count > 0 {
        "Every found routine is already in Rota."
    } else {
        "No scheduled tasks were found in Claude Desktop or Codex."
    };
    UiElement::column()
        .id("importEmpty")
        .width(inner_w)
        .align_center()
        .padding(Edges::xy(0.0, theme.ui_px(34.0)))
        .gap(theme.ui_px(6.0))
        .a11y(A11ySpec::new(A11yRole::Group, empty_heading))
        .child(UiElement::icon(
            IconKind::Import,
            theme.ui_px(26.0),
            theme.text_muted,
        ))
        .child(UiElement::text(
            vec![
                TextSpan::new(empty_heading, theme.heading_size(), theme.text_primary)
                    .weight(FontWeight::Semibold),
            ],
            TextLayoutOpts {
                align: TextAlign::Center,
                ..Default::default()
            },
        ))
        .child(UiElement::text(
            vec![TextSpan::new(empty_sub, theme.body_size(), theme.text_secondary)],
            TextLayoutOpts {
                max_width: Some(inner_w - 40.0),
                align: TextAlign::Center,
                ..Default::default()
            },
        ))
}

pub fn build_delete_confirm_modal(state: &mut AppState, theme: &Theme, viewport: Size) -> UiElement {
    let w = (viewport.width - 80.0).clamp(320.0, 420.0);
    let h = theme.ui_px(176.0);
    let is_session = state.confirm_delete_session.is_some();
    let hov = state.hovered_id.clone();
    let (title, body, confirm_id, confirm_label, confirm_act) = if is_session {
        (
            "Delete Session?",
            "Permanently delete this session and its local log? The routine and agent history stay unchanged.",
            "confirmDeleteSession",
            "Delete Session",
            state
                .actions
                .register_named("confirmDeleteSession", AppAction::ConfirmDeleteSession),
        )
    } else {
        (
            "Delete Routine?",
            "Its sessions and logs are deleted too. Your project files stay untouched.",
            "confirmDeleteRoutine",
            "Delete Routine",
            state
                .actions
                .register_named("confirmDeleteRoutine", AppAction::ConfirmDeleteRoutine),
        )
    };
    let cancel_act = state
        .actions
        .register_named("Cancel", AppAction::CancelDeleteModal);

    modal_card(theme, "deleteConfirmModal", title, w, h)
        .padding(Edges::all(theme.ui_px(18.0)))
        .justify_between()
        .child(
            UiElement::column()
                .width(w - 36.0)
                .gap(theme.ui_px(8.0))
                .child(label_semibold_1line(
                    title,
                    theme.heading_size(),
                    theme.text_primary,
                    w - 36.0,
                ))
                .child(label_wrapped(
                    body,
                    theme.body_size(),
                    theme.text_secondary,
                    w - 36.0,
                    Some(3),
                )),
        )
        .child(
            UiElement::row()
                .width(w - 36.0)
                .align_center()
                .justify_between()
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
                    confirm_id,
                    confirm_label,
                    Some(IconKind::Trash),
                    confirm_act,
                    false,
                    true,
                    true,
                    hov.as_deref() == Some(confirm_id),
                )),
        )
}
