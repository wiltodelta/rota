//! Sidebar `Sessions` header, `sessionFilter` pop-up button (`AXMenu`), and active filter tokens.

use rota_ui::{A11yRole, A11ySpec, Color, Edges, IconKind, Theme, UiElement};

use crate::actions::{AppAction, MenuId};
use crate::app_state::AppState;
use crate::views::widgets::{icon_button, label_1line, label_semibold_1line};

pub fn build_sessions_filter_header(state: &mut AppState, theme: &Theme, width: f32) -> UiElement {
    let active_tokens = state.session_filters.selected();
    let filtering = !active_tokens.is_empty();
    let open_menu_act = state
        .actions
        .register_named("sessionFilter", AppAction::OpenMenu(MenuId::SessionFilter));
    let hov = state.hovered_id.as_deref() == Some("sessionFilter");
    let menu_open = state
        .open_menu
        .as_ref()
        .is_some_and(|(m, _)| *m == MenuId::SessionFilter);

    let mut f_btn = icon_button(
        theme,
        "sessionFilter",
        "Filter Sessions",
        IconKind::Filter,
        open_menu_act,
        filtering || menu_open,
        true,
        hov,
    );
    if let Some(meta) = f_btn.a11y.as_mut() {
        meta.role = A11yRole::PopUpButton;
        meta.value = Some(state.session_filters.title());
    }

    let hdr_row = UiElement::row()
        .width(width)
        .align_center()
        .justify_between()
        .padding(Edges::new(
            theme.ui_px(2.0),
            0.0,
            theme.ui_px(2.0),
            theme.ui_px(8.0),
        ))
        .child(
            label_semibold_1line("Sessions", theme.caption_size(), theme.text_muted, width - 44.0)
                .a11y(A11ySpec::new(A11yRole::Heading, "Sessions")),
        )
        .child(f_btn);

    let mut sec = UiElement::column()
        .id("sessionsSection")
        .width(width)
        .gap(theme.ui_px(6.0))
        .clip()
        .a11y(A11ySpec::new(A11yRole::Group, "Sessions"))
        .child(hdr_row);

    if !active_tokens.is_empty() {
        let mut token_row = UiElement::row()
            .width(width)
            .padding(Edges::xy(theme.ui_px(6.0), 0.0))
            .gap(theme.ui_px(4.0))
            .clip();
        for f in active_tokens.iter().take(2) {
            let tok_id = format!("clearSessionFilter-{}", f.as_str());
            let tok_hov = state.is_hovered(&tok_id);
            let rm_act = state
                .actions
                .register_named(&tok_id, AppAction::ToggleSessionFilter(*f));
            token_row = token_row.child(
                UiElement::row()
                    .id(tok_id)
                    .align_center()
                    .height(theme.ui_px(24.0))
                    .gap(theme.ui_px(4.0))
                    .padding(Edges::xy(theme.ui_px(8.0), theme.ui_px(3.0)))
                    .rounded(theme.ui_px(12.0))
                    .bg(if tok_hov { theme.border } else { theme.subtle_hover })
                    .on_click(rm_act)
                    .a11y(A11ySpec::new(
                        A11yRole::Button,
                        format!("Remove {} Filter", f.title()),
                    ))
                    .child(label_1line(
                        f.title(),
                        theme.ui_px(11.0),
                        theme.text_primary,
                        84.0,
                    ))
                    .child(UiElement::icon(
                        IconKind::Close,
                        theme.ui_px(10.0),
                        theme.text_muted,
                    )),
            );
        }
        let reset_act = state
            .actions
            .register_named("resetSessionFilter", AppAction::ResetSessionFilters);
        let rst_hov = state.is_hovered("resetSessionFilter");
        token_row = token_row.child(
            UiElement::row()
                .id("resetSessionFilter")
                .align_center()
                .height(theme.ui_px(24.0))
                .padding(Edges::xy(theme.ui_px(8.0), theme.ui_px(3.0)))
                .rounded(theme.ui_px(12.0))
                .bg(if rst_hov {
                    theme.subtle_hover
                } else {
                    Color::TRANSPARENT
                })
                .on_click(reset_act)
                .a11y(A11ySpec::new(A11yRole::Button, "Show All Sessions"))
                .child(label_1line("Reset", theme.ui_px(11.0), theme.accent, 50.0)),
        );
        sec = sec.child(token_row);
    }
    sec
}
