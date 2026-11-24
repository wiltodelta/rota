//! Settings sidebar (`settingsSidebar`) and `Agents` grouped-form pane (CLIs, Claude Interactive permissions, and MCP access).

use std::path::Path;

use rota_core::model::Harness;
use rota_core::runners::AgentAccess;
use rota_platform::{ComputerUseAccess, abbreviate_tilde};
use rota_ui::{A11yRole, A11ySpec, Color, Edges, IconKind, Theme, UiElement};

use crate::actions::{AppAction, MenuId, SettingsPane};
use crate::app_state::AppState;
use crate::views::form_rows::{form_row, form_row_with_status, form_section, form_toggle_row};
use crate::views::widgets::{
    button, hairline_h, harness_color, harness_icon, label_1line, label_semibold_1line, popup_button,
};

pub fn build_settings_sidebar(
    state: &mut AppState,
    theme: &Theme,
    active_pane: SettingsPane,
    width: f32,
    height: f32,
) -> UiElement {
    let inner_w = (width - theme.ui_px(20.0)).max(140.0);
    let back_act = state
        .actions
        .register_named("settingsBack", AppAction::CloseSettings);

    let back_btn = UiElement::row()
        .id("settingsBack")
        .width(inner_w)
        .height(theme.ui_px(30.0))
        .align_center()
        .gap(theme.ui_px(8.0))
        .padding(Edges::xy(theme.ui_px(8.0), theme.ui_px(4.0)))
        .rounded(theme.ui_px(7.0))
        .bg(if state.is_hovered("settingsBack") {
            theme.subtle_hover
        } else {
            Color::TRANSPARENT
        })
        .on_click(back_act)
        .a11y(A11ySpec::new(A11yRole::Button, "Back"))
        .child(UiElement::icon(
            IconKind::Back,
            theme.ui_px(13.5),
            theme.text_secondary,
        ))
        .child(label_1line(
            "Back",
            theme.body_size(),
            theme.text_secondary,
            inner_w - 36.0,
        ));

    let mut col = UiElement::column()
        .id("settingsSidebar")
        .width(width)
        .height(height)
        .padding(Edges::new(
            theme.ui_px(40.0),
            theme.ui_px(10.0),
            theme.ui_px(10.0),
            theme.ui_px(10.0),
        ))
        .gap(theme.ui_px(4.0))
        .bg(if state.window_vibrant {
            Color::TRANSPARENT
        } else {
            theme.sidebar
        })
        .clip()
        .a11y(A11ySpec::new(A11yRole::ScrollArea, "Settings"))
        .child(back_btn)
        .child(
            UiElement::row()
                .width(inner_w)
                .padding(Edges::xy(theme.ui_px(4.0), theme.ui_px(3.0)))
                .child(hairline_h(theme)),
        )
        .child(
            UiElement::row()
                .padding(Edges::xy(theme.ui_px(8.0), theme.ui_px(2.0)))
                .child(label_semibold_1line(
                    "Settings",
                    theme.caption_size(),
                    theme.text_muted,
                    inner_w - 16.0,
                )),
        );

    for (pane, icon) in [
        (SettingsPane::General, IconKind::Settings),
        (SettingsPane::Chat, IconKind::TextFormatSize),
        (SettingsPane::Agents, IconKind::Terminal),
    ] {
        let row_id = format!("settingsPane-{}", pane.as_str());
        let sel = active_pane == pane;
        let hov = state.is_hovered(&row_id);
        let act = state
            .actions
            .register_named(&row_id, AppAction::OpenSettings(Some(pane)));
        let mut rspec = A11ySpec::new(A11yRole::Row, pane.title());
        rspec.selected = sel;
        col = col.child(
            UiElement::row()
                .id(row_id)
                .width(inner_w)
                .height(theme.ui_px(32.0))
                .align_center()
                .gap(theme.ui_px(9.0))
                .padding(Edges::xy(theme.ui_px(8.0), theme.ui_px(5.0)))
                .rounded(theme.ui_px(8.0))
                .bg(if sel {
                    theme.selection_fill
                } else if hov {
                    theme.subtle_hover
                } else {
                    Color::TRANSPARENT
                })
                .on_click(act)
                .a11y(rspec)
                .child(UiElement::icon(
                    icon,
                    theme.ui_px(15.0),
                    if sel { Color::WHITE } else { theme.selection_fill },
                ))
                .child(
                    label_1line(
                        pane.title(),
                        theme.body_size(),
                        if sel { Color::WHITE } else { theme.text_primary },
                        inner_w - 40.0,
                    )
                    .a11y(A11ySpec::new(A11yRole::StaticText, pane.title())),
                ),
        );
    }
    col
}

pub fn build_agents_pane(state: &mut AppState, theme: &Theme, width: f32) -> UiElement {
    let hov = state.hovered_id.clone();

    // 1. Agent CLIs grouped section
    let mut cli_rows = Vec::with_capacity(Harness::AGENTS.len());
    for h in Harness::AGENTS {
        let chosen = state.settings.chosen_executable(h);
        let eff_exe = state.settings.effective_executable(h);
        let exe_exists = Path::new(&eff_exe).is_file();
        let ver_opt = state
            .settings
            .installed
            .get(&h)
            .and_then(|list| list.iter().find(|i| i.path == eff_exe).or_else(|| list.first()))
            .and_then(|i| i.version.clone());

        let used_by_routine = state.routines.iter().any(|r| r.harness == h);
        let (st_txt, st_ic, st_col) = if exe_exists {
            (
                ver_opt.unwrap_or_else(|| abbreviate_tilde(&eff_exe)),
                IconKind::CheckCircle,
                theme.success,
            )
        } else if chosen.is_some() || used_by_routine {
            (
                format!("Not found at {}", abbreviate_tilde(&eff_exe)),
                IconKind::Warning,
                theme.warning,
            )
        } else {
            ("Not installed".to_string(), IconKind::Info, theme.text_muted)
        };

        let picker_lbl = match chosen {
            Some(c) => abbreviate_tilde(c),
            None => format!("Automatic ({})", abbreviate_tilde(&eff_exe)),
        };
        let btn_id = format!("agentCli-{}", h.as_str());
        let open_act = state
            .actions
            .register_named(&btn_id, AppAction::OpenMenu(MenuId::AgentCli(h)));

        cli_rows.push(form_row_with_status(
            theme,
            h.title(),
            Some((harness_icon(h), harness_color(theme, h))),
            Some((&st_txt, st_ic, st_col)),
            width,
            popup_button(
                theme,
                btn_id.clone(),
                &picker_lbl,
                None,
                open_act,
                true,
                hov.as_deref() == Some(btn_id.as_str()),
            ),
        ));
    }

    let cli_sec = form_section(
        theme,
        Some(("Agent CLIs", Some("agentCLIsHeading"))),
        width,
        cli_rows,
        Some((
            "Automatic uses the newest supported CLI found on your Mac. Choose another copy to pin a specific version.",
            None,
        )),
    );

    // 2. Claude Code section
    let access = ComputerUseAccess::current();
    let claude_act = state
        .actions
        .register_named("claudeInteractive", AppAction::ToggleClaudeInteractive);
    let ax_act = state
        .actions
        .register_named("permAccessibility", AppAction::RequestAccessibilityPermission);
    let sr_act = state
        .actions
        .register_named("permScreenRecording", AppAction::RequestScreenRecordingPermission);

    let perm_trailing = |id: &str, allowed: bool, act, hov_id: Option<&str>| {
        if allowed {
            UiElement::row()
                .align_center()
                .gap(theme.ui_px(5.0))
                .child(UiElement::icon(
                    IconKind::CheckCircle,
                    theme.ui_px(13.5),
                    theme.success,
                ))
                .child(label_1line(
                    "Allowed",
                    theme.body_size(),
                    theme.text_secondary,
                    90.0,
                ))
        } else {
            button(
                theme,
                id,
                "Allow…",
                None,
                act,
                false,
                false,
                true,
                hov_id == Some(id),
            )
        }
    };

    let mut claude_rows = vec![form_toggle_row(
        theme,
        "claudeInteractive",
        "Run Claude Code interactively",
        width,
        state.settings.claude_interactive,
        true,
        claude_act,
    )];
    if state.settings.claude_interactive {
        claude_rows.push(form_row(
            theme,
            "Accessibility",
            width,
            perm_trailing("permAccessibility", access.accessibility, ax_act, hov.as_deref()),
        ));
        claude_rows.push(form_row(
            theme,
            "Screen Recording",
            width,
            perm_trailing(
                "permScreenRecording",
                access.screen_recording,
                sr_act,
                hov.as_deref(),
            ),
        ));
    }

    let claude_sec = form_section(
        theme,
        Some(("Claude Code", None)),
        width,
        claude_rows,
        Some((
            "Interactive mode runs a detached Claude Code TUI session with full computer-use and permission prompts.",
            None,
        )),
    );

    // 3. Routines from agents (MCP) section
    let link_disp = abbreviate_tilde(&AgentAccess::command_link().to_string_lossy());
    let install_act = state
        .actions
        .register_named("installRotaCli", AppAction::InstallCliCommand);
    let cli_trailing = if state.settings.command_installed {
        UiElement::row()
            .align_center()
            .gap(theme.ui_px(5.0))
            .child(UiElement::icon(
                IconKind::CheckCircle,
                theme.ui_px(13.5),
                theme.success,
            ))
            .child(label_1line(
                "Installed",
                theme.body_size(),
                theme.text_secondary,
                96.0,
            ))
    } else {
        button(
            theme,
            "installRotaCli",
            "Install",
            None,
            install_act,
            false,
            false,
            true,
            hov.as_deref() == Some("installRotaCli"),
        )
    };

    let mut mcp_rows = vec![form_row_with_status(
        theme,
        "rota command",
        None,
        Some((&link_disp, IconKind::Terminal, theme.text_muted)),
        width,
        cli_trailing,
    )];

    for h in Harness::AGENTS {
        let is_added = state.settings.mcp_added.get(&h).copied().unwrap_or(false);
        let is_busy = state.settings.mcp_busy == Some(h);
        let acc_id = format!("agentAccess-{}", h.as_str());
        let acc_hov = hov.as_deref() == Some(acc_id.as_str());
        let act = state
            .actions
            .register_named(&acc_id, AppAction::ToggleAgentMcp(h));
        let lbl = if is_busy {
            "Working…"
        } else if is_added {
            "Remove"
        } else {
            "Add"
        };
        mcp_rows.push(form_row(
            theme,
            h.title(),
            width,
            button(theme, acc_id, lbl, None, act, false, false, !is_busy, acc_hov),
        ));
    }

    let mcp_footer = state
        .settings
        .mcp_error
        .as_deref()
        .unwrap_or("Agents with Rota added can create, update, run, and inspect routines via MCP.");
    let mcp_sec = form_section(
        theme,
        Some(("Routines from agents", None)),
        width,
        mcp_rows,
        Some((mcp_footer, Some("agentAccessFooter"))),
    );

    UiElement::column()
        .width(width)
        .gap(theme.ui_px(14.0))
        .child(cli_sec)
        .child(claude_sec)
        .child(mcp_sec)
}

pub fn build_quick_replies_header_row(
    theme: &Theme,
    width: f32,
    pad_x: f32,
    title_w: f32,
    msg_w: f32,
) -> UiElement {
    UiElement::row()
        .width(width)
        .align_center()
        .gap(theme.ui_px(6.0))
        .padding(Edges::new(theme.ui_px(8.0), pad_x, theme.ui_px(2.0), pad_x))
        .clip()
        .child(
            label_1line(
                "Button label",
                theme.caption_size(),
                theme.text_secondary,
                title_w,
            )
            .width(title_w),
        )
        .child(
            label_1line(
                "Message to send",
                theme.caption_size(),
                theme.text_secondary,
                msg_w,
            )
            .width(msg_w),
        )
}

pub fn build_quick_replies_footer_row(
    state: &mut AppState,
    theme: &Theme,
    width: f32,
    pad_x: f32,
    hov: Option<&str>,
) -> UiElement {
    let add_act = state
        .actions
        .register_named("addQuickReply", AppAction::AddQuickReply);
    let mut qr_btns = UiElement::row()
        .width(width)
        .align_center()
        .gap(theme.ui_px(8.0))
        .padding(Edges::xy(pad_x, theme.ui_px(8.0)))
        .child(button(
            theme,
            "addQuickReply",
            "Add Reply",
            Some(IconKind::Plus),
            add_act,
            false,
            false,
            true,
            hov == Some("addQuickReply"),
        ));
    if !state.settings.missing_default_replies().is_empty() {
        let restore_act = state
            .actions
            .register_named("restoreQuickReplies", AppAction::RestoreDefaultQuickReplies);
        qr_btns = qr_btns.child(button(
            theme,
            "restoreQuickReplies",
            "Restore Default Replies",
            None,
            restore_act,
            false,
            false,
            true,
            hov == Some("restoreQuickReplies"),
        ));
    }
    qr_btns
}
