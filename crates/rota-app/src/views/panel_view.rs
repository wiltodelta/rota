//! Menu bar status panel (`340x420`) UI element tree builder (`MenuBarContent.swift` parity).

use jiff::Timestamp;
use rota_ui::{
    A11yRole, A11ySpec, Color, Edges, FontWeight, IconKind, TextLayoutOpts, TextSpan, Theme, UiElement,
};

use crate::actions::{ActionRegistry, AppAction, PanelInput};
use crate::app_state::AppState;
use crate::views::widgets::{
    hairline_h, harness_status_icon, label_1line, label_semibold_1line, routine_next_subtitle,
};

pub fn build_panel_tree(
    state: &AppState,
    theme: &Theme,
    height: f32,
    reg: &mut ActionRegistry,
    map: &mut Vec<(String, PanelInput)>,
) -> UiElement {
    let w = 340.0f32;
    let now = Timestamp::now();
    let mut rows_col = UiElement::column()
        .width(w)
        .padding(Edges::all(8.0))
        .gap(2.0)
        .flex_grow(1.0)
        .clip();

    if state.routines.is_empty() {
        let new_act = reg.register(AppAction::Noop);
        let new_hov = state.panel_hovered_id.as_deref() == Some("panelNewRoutine");
        map.push(("panelNewRoutine".to_string(), PanelInput::OpenNew));
        rows_col = rows_col.child(
            UiElement::column()
                .width(324.0)
                .align_center()
                .justify_center()
                .gap(8.0)
                .padding(Edges::xy(12.0, 14.0))
                .child(label_1line("No routines yet", 13.0, theme.text_secondary, 280.0))
                .child(
                    UiElement::row()
                        .id("panelNewRoutine")
                        .height(26.0)
                        .align_center()
                        .gap(5.0)
                        .padding(Edges::xy(11.0, 4.0))
                        .rounded(13.0)
                        .bg(if new_hov {
                            theme.accent_hover
                        } else {
                            theme.selection_fill
                        })
                        .on_click(new_act)
                        .a11y(A11ySpec::new(A11yRole::Button, "New Routine…"))
                        .child(UiElement::icon(IconKind::Plus, 12.0, Color::WHITE))
                        .child(UiElement::text(
                            vec![
                                TextSpan::new("New Routine…", 12.0, Color::WHITE).weight(FontWeight::Medium),
                            ],
                            TextLayoutOpts {
                                max_lines: Some(1),
                                ..Default::default()
                            },
                        )),
                ),
        );
    } else {
        for r in state.routines.iter().take(8) {
            let hi = state.panel_highlighted.as_deref() == Some(r.id.as_str());
            let running = state.scheduler.is_running(&r.id);
            let sub = routine_next_subtitle(r, running, now);
            let row_id = format!("panelRow-{}", r.id);
            let run_id = format!("panelRun-{}", r.id);
            let run_hov = state.panel_hovered_id.as_deref() == Some(run_id.as_str());
            let act = reg.register(AppAction::Noop);
            map.push((row_id.clone(), PanelInput::OpenRoutine(r.id.clone())));

            let dot_col = if running {
                theme.accent
            } else if r.enabled {
                theme.success
            } else {
                theme.text_muted.with_alpha(0.6)
            };
            let row_bg = if hi {
                theme.text_primary.with_alpha(0.08)
            } else {
                Color::TRANSPARENT
            };
            let cutout = if hi { theme.subtle_hover } else { theme.elevated };

            let lead = UiElement::row()
                .align_center()
                .gap(9.0)
                .clip()
                .child(harness_status_icon(theme, r.harness, dot_col, false, cutout))
                .child(
                    UiElement::column()
                        .width(if hi { 222.0 } else { 254.0 })
                        .gap(1.5)
                        .clip()
                        .child(label_semibold_1line(
                            &r.name,
                            13.0,
                            theme.text_primary,
                            if hi { 222.0 } else { 254.0 },
                        ))
                        .child(label_1line(
                            &sub,
                            11.5,
                            theme.text_secondary,
                            if hi { 222.0 } else { 254.0 },
                        )),
                );

            let mut row_el = UiElement::row()
                .id(row_id)
                .width(324.0)
                .align_center()
                .justify_between()
                .padding(Edges::xy(8.0, 6.0))
                .rounded(6.0)
                .bg(row_bg)
                .clip()
                .on_click(act)
                .a11y(A11ySpec::new(A11yRole::Button, &r.name))
                .child(lead);

            // Calm Swift `MenuBarContent.swift`: reveal Play/Stop button ONLY when row is highlighted/hovered!
            if hi {
                let run_act = reg.register(AppAction::Noop);
                map.push((run_id.clone(), PanelInput::ToggleRun(r.id.clone())));
                row_el = row_el.child(
                    UiElement::row()
                        .id(run_id)
                        .width(26.0)
                        .height(26.0)
                        .align_center()
                        .justify_center()
                        .rounded(13.0)
                        .bg(if run_hov {
                            theme.text_primary.with_alpha(0.12)
                        } else {
                            Color::TRANSPARENT
                        })
                        .on_click(run_act)
                        .a11y(A11ySpec::new(
                            A11yRole::Button,
                            if running { "Stop" } else { "Run Now" },
                        ))
                        .child(UiElement::icon(
                            if running { IconKind::Stop } else { IconKind::Play },
                            13.0,
                            if running {
                                theme.danger
                            } else {
                                theme.text_secondary
                            },
                        )),
                );
            }

            rows_col = rows_col.child(row_el);
        }
        if state.routines.len() > 8 {
            let rem = state.routines.len() - 8;
            let more_act = reg.register(AppAction::Noop);
            let more_hov = state.panel_hovered_id.as_deref() == Some("panelShowAll");
            map.push(("panelShowAll".to_string(), PanelInput::OpenMain));
            rows_col = rows_col.child(
                UiElement::row()
                    .id("panelShowAll")
                    .width(324.0)
                    .height(26.0)
                    .min_height(26.0)
                    .flex_shrink(0.0)
                    .align_center()
                    .padding(Edges::xy(10.0, 3.0))
                    .rounded(6.0)
                    .bg(if more_hov {
                        theme.subtle_hover
                    } else {
                        Color::TRANSPARENT
                    })
                    .on_click(more_act)
                    .a11y(A11ySpec::new(A11yRole::Button, "Show all routines"))
                    .child(label_1line(
                        format!("{rem} more in Rota…"),
                        11.5,
                        theme.accent,
                        280.0,
                    )),
            );
        }
    }

    let mut root = UiElement::column()
        .width(w)
        .height(height)
        .rounded(14.0)
        .bg(theme.elevated)
        .border(1.0, theme.border)
        .clip()
        .child(rows_col);

    if let Some(waiting) = state.sessions.iter().find(|s| s.needs_attention()) {
        let act = reg.register(AppAction::Noop);
        let nr_hov = state.panel_hovered_id.as_deref() == Some("panelNeedsReply");
        map.push(("panelNeedsReply".to_string(), PanelInput::OpenSession(waiting.id)));
        let n = state.attention_count.max(1);
        let msg = if n == 1 {
            "1 session needs your reply".to_string()
        } else {
            format!("{n} sessions need your reply")
        };
        root = root.child(hairline_h(theme)).child(
            UiElement::row()
                .id("panelNeedsReply")
                .width(w)
                .height(34.0)
                .align_center()
                .gap(8.0)
                .padding(Edges::xy(14.0, 6.0))
                .bg(if nr_hov {
                    theme.subtle_hover
                } else {
                    Color::TRANSPARENT
                })
                .on_click(act)
                .a11y(A11ySpec::new(A11yRole::Button, &msg))
                .child(UiElement::icon(IconKind::BubbleAlert, 14.0, theme.warning))
                .child(label_semibold_1line(&msg, 11.5, theme.text_primary, 286.0)),
        );
    }

    if let Some(unread) = state.sessions.iter().find(|s| s.is_unread()) {
        let act = reg.register(AppAction::Noop);
        let ur_hov = state.panel_hovered_id.as_deref() == Some("panelUnread");
        map.push(("panelUnread".to_string(), PanelInput::OpenSession(unread.id)));
        let n = state.unread_count.max(1);
        let msg = if n == 1 {
            "1 unread session".to_string()
        } else {
            format!("{n} unread sessions")
        };
        root = root.child(hairline_h(theme)).child(
            UiElement::row()
                .id("panelUnread")
                .width(w)
                .height(34.0)
                .align_center()
                .gap(8.0)
                .padding(Edges::xy(14.0, 6.0))
                .bg(if ur_hov {
                    theme.subtle_hover
                } else {
                    Color::TRANSPARENT
                })
                .on_click(act)
                .a11y(A11ySpec::new(A11yRole::Button, &msg))
                .child(UiElement::icon(IconKind::TrayFull, 14.0, theme.selection_fill))
                .child(label_1line(&msg, 11.5, theme.text_primary, 286.0)),
        );
    }

    let fbtn = |id: &str,
                lbl: &str,
                icon: Option<IconKind>,
                secondary: bool,
                pa: PanelInput,
                reg: &mut ActionRegistry,
                map: &mut Vec<(String, PanelInput)>| {
        let act = reg.register(AppAction::Noop);
        let hov = state.panel_hovered_id.as_deref() == Some(id);
        let fg = if secondary {
            theme.text_secondary
        } else {
            theme.text_primary
        };
        map.push((id.to_string(), pa));
        let mut row = UiElement::row()
            .id(id.to_string())
            .height(28.0)
            .align_center()
            .gap(5.0)
            .padding(Edges::xy(8.0, 4.0))
            .rounded(6.0)
            .bg(if hov {
                theme.subtle_hover
            } else {
                Color::TRANSPARENT
            })
            .on_click(act)
            .a11y(A11ySpec::new(A11yRole::Button, lbl));
        if let Some(ic) = icon {
            row = row.child(UiElement::icon(ic, 13.0, fg));
        }
        row.child(UiElement::text(
            vec![TextSpan::new(lbl, 11.5, fg).weight(if secondary {
                FontWeight::Regular
            } else {
                FontWeight::Medium
            })],
            TextLayoutOpts {
                max_lines: Some(1),
                ..Default::default()
            },
        ))
    };

    let ftr = UiElement::row()
        .width(w)
        .height(38.0)
        .align_center()
        .justify_between()
        .padding(Edges::xy(8.0, 5.0))
        .child(
            UiElement::row()
                .align_center()
                .gap(4.0)
                .child(fbtn(
                    "panelSettings",
                    "Settings…",
                    Some(IconKind::Settings),
                    false,
                    PanelInput::OpenSettings,
                    reg,
                    map,
                ))
                .child(fbtn(
                    "panelOpenRota",
                    "Open Rota",
                    None,
                    false,
                    PanelInput::OpenMain,
                    reg,
                    map,
                )),
        )
        .child(fbtn("panelQuit", "Quit", None, true, PanelInput::Quit, reg, map));

    root.child(hairline_h(theme)).child(ftr)
}
