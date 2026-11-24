//! `SettingsView` mode inside Main Window (`General` and `Chat` grouped-form panes; `Agents` + sidebar in `settings_agents`).

use rota_platform::{KnownTerminal, SystemUpdater, abbreviate_tilde};
use rota_ui::{
    A11yRole, A11ySpec, Edges, FontFamily, IconKind, Point, TextLayoutOpts, TextSpan, Theme, UiElement,
};

use crate::actions::{AppAction, FocusTarget, MenuId, SettingsPane};
use crate::app_state::AppState;
use crate::views::form_rows::{form_page_bg, form_row, form_section, form_toggle_row, slider_control};
use crate::views::settings_agents::build_agents_pane;
use crate::views::widgets::{button, icon_button, mono_text, popup_button, text_field_box};

pub fn build_settings_detail(
    state: &mut AppState,
    theme: &Theme,
    pane: SettingsPane,
    width: f32,
    height: f32,
    now_seconds: f64,
) -> UiElement {
    let pad_x = ((width - 600.0) * 0.5).max(theme.ui_px(24.0));
    let card_w = (width - pad_x * 2.0).clamp(220.0, 600.0);

    let (body_col, est_h) = match pane {
        SettingsPane::General => (build_general_pane(state, theme, card_w), 560.0),
        SettingsPane::Chat => (build_chat_pane(state, theme, card_w), 640.0),
        SettingsPane::Agents => (build_agents_pane(state, theme, card_w), 720.0),
    };

    if state.settings_scroll.item_count() == 0 {
        state.settings_scroll.set_heights(&[theme.ui_px(est_h)], height);
    }
    let total_h = state.settings_scroll.total_height();
    let eff_scroll_y = state.settings_scroll.effective_scroll_y();
    let sb_key = format!("settings-{}", pane.as_str());
    let sb_active = state
        .dragging_scrollbar
        .as_ref()
        .is_some_and(|(k, _)| k == &sb_key)
        || state.hovered_id.as_deref() == Some(&format!("scrollbarThumb-{sb_key}"));
    let sb_opt = crate::views::widgets::interactive_scrollbar_overlay(
        theme,
        &sb_key,
        &state.settings_scroll,
        height,
        total_h,
        width,
        sb_active,
        now_seconds,
        &mut state.activity_clock,
    );
    let bg = form_page_bg(theme);

    let mut sc = UiElement::column()
        .id(format!("settingsScroll-{}", pane.as_str()))
        .width(width)
        .height(height)
        .bg(bg)
        .clip()
        .scroll_offset(Point::new(0.0, eff_scroll_y))
        .a11y(A11ySpec::new(A11yRole::ScrollArea, pane.title()))
        .child(
            UiElement::column()
                .id("settingsContent")
                .width(width)
                .padding(Edges::new(theme.ui_px(14.0), pad_x, theme.ui_px(24.0), pad_x))
                .child(body_col),
        );
    if let Some(sb) = sb_opt {
        sc = sc.child(sb);
    }
    sc
}

fn build_general_pane(state: &mut AppState, theme: &Theme, width: f32) -> UiElement {
    let hov = state.hovered_id.clone();

    // 1. Appearance
    let scale_pct = format!("{}%", (state.settings.interface_scale * 100.0).round() as i32);
    let scale_act = state
        .actions
        .register_named("interfaceScale", AppAction::OpenMenu(MenuId::InterfaceScale));
    let appearance_sec = form_section(
        theme,
        Some(("Appearance", None)),
        width,
        vec![form_row(
            theme,
            "Interface scale",
            width,
            popup_button(
                theme,
                "interfaceScale",
                &scale_pct,
                None,
                scale_act,
                true,
                hov.as_deref() == Some("interfaceScale"),
            ),
        )],
        None,
    );

    // 2. Notifications
    let notif_act = state
        .actions
        .register_named("notifyOnSuccessToggle", AppAction::ToggleCompletionNotifications);
    let notif_sec = form_section(
        theme,
        Some(("Notifications", None)),
        width,
        vec![form_toggle_row(
            theme,
            "notifyOnSuccessToggle",
            "Notify on normal completion",
            width,
            state.settings.completion_notifications,
            true,
            notif_act,
        )],
        Some((
            "Failed runs and missed slots notify. Slots skipped while a run is still going stay quiet.",
            None,
        )),
    );

    // 3. Sessions (Preferred Terminal)
    let term_label = match state.settings.preferred_terminal.as_deref() {
        None => "Default (Terminal)".to_string(),
        Some(b) => KnownTerminal::ALL
            .into_iter()
            .find(|k| k.bundle_id() == b)
            .map_or_else(|| abbreviate_tilde(b), |k| k.title().to_string()),
    };
    let term_act = state
        .actions
        .register_named("terminalApp", AppAction::OpenMenu(MenuId::PreferredTerminal));
    let sessions_sec = form_section(
        theme,
        Some(("Sessions", None)),
        width,
        vec![form_row(
            theme,
            "Terminal",
            width,
            popup_button(
                theme,
                "terminalApp",
                &term_label,
                Some(IconKind::Terminal),
                term_act,
                true,
                hov.as_deref() == Some("terminalApp"),
            ),
        )],
        Some((
            "Open in Terminal and Continue in Terminal open sessions in this app.",
            None,
        )),
    );

    // 4. Startup
    let login_act = state
        .actions
        .register_named("launchAtLoginToggle", AppAction::ToggleLaunchAtLogin);
    let startup_ftr = state
        .settings
        .login_error
        .as_deref()
        .unwrap_or("Start Rota automatically when you log in to your Mac.");
    let startup_sec = form_section(
        theme,
        Some(("Startup", None)),
        width,
        vec![form_toggle_row(
            theme,
            "launchAtLoginToggle",
            "Launch at login",
            width,
            state.settings.launch_at_login,
            true,
            login_act,
        )],
        Some((startup_ftr, None)),
    );

    // 5. Updates
    let ver = SystemUpdater::version();
    let auto_checks = SystemUpdater::automatically_checks();
    let toggle_upd = state
        .actions
        .register_named("autoCheckUpdatesToggle", AppAction::ToggleAutoCheckUpdates);
    let check_now = state
        .actions
        .register_named("checkForUpdatesBtn", AppAction::CheckForUpdatesNow);
    let updates_sec = form_section(
        theme,
        Some(("Updates", None)),
        width,
        vec![
            form_row(
                theme,
                "Version",
                width,
                mono_text(&ver, theme.body_size(), theme.text_secondary, 140.0, Some(1)),
            ),
            form_toggle_row(
                theme,
                "autoCheckUpdatesToggle",
                "Check for updates automatically",
                width,
                auto_checks,
                true,
                toggle_upd,
            ),
            form_row(
                theme,
                "Software update",
                width,
                button(
                    theme,
                    "checkForUpdatesBtn",
                    "Check for Updates…",
                    None,
                    check_now,
                    false,
                    false,
                    true,
                    hov.as_deref() == Some("checkForUpdatesBtn"),
                ),
            ),
        ],
        Some((
            "Checks once a day and installs a new version when you choose to.",
            None,
        )),
    );

    UiElement::column()
        .width(width)
        .gap(theme.ui_px(18.0))
        .child(appearance_sec)
        .child(notif_sec)
        .child(sessions_sec)
        .child(startup_sec)
        .child(updates_sec)
}

fn build_chat_pane(state: &mut AppState, theme: &Theme, width: f32) -> UiElement {
    let hov = state.hovered_id.clone();
    let font_lbl = if state.settings.chat_font_mono {
        "JetBrains Mono"
    } else {
        "IBM Plex Sans"
    };
    let font_act = state
        .actions
        .register_named("chatFont", AppAction::OpenMenu(MenuId::ChatFont));
    let rst_act = state
        .actions
        .register_named("chatScaleReset", AppAction::ResetChatScale);
    let pct_str = format!("{}%", (state.settings.chat_scale * 100.0).round() as i32);

    let mut scale_trailing = UiElement::row().align_center().gap(theme.ui_px(10.0));
    if (state.settings.chat_scale - 1.0).abs() > 0.01 {
        scale_trailing = scale_trailing.child(button(
            theme,
            "chatScaleReset",
            "Reset",
            None,
            rst_act,
            false,
            false,
            true,
            hov.as_deref() == Some("chatScaleReset"),
        ));
    }
    scale_trailing = scale_trailing
        .child(slider_control(
            theme,
            "chatTextScale",
            "Text scale",
            state.settings.chat_scale,
            0.7,
            2.0,
            theme.ui_px(156.0),
        ))
        .child(
            mono_text(&pct_str, theme.body_size(), theme.text_secondary, 44.0, Some(1))
                .id("chatTextScaleValue")
                .width(theme.ui_px(44.0))
                .a11y(A11ySpec::new(A11yRole::StaticText, &pct_str)),
        );

    let sample_font = if state.settings.chat_font_mono {
        FontFamily::Mono
    } else {
        FontFamily::UiSans
    };
    let pad_x = theme.ui_px(14.0);
    let sample_w = (width - pad_x * 2.0).max(140.0);
    let sample_row = UiElement::column()
        .width(width)
        .gap(theme.ui_px(6.0))
        .padding(Edges::xy(pad_x, theme.ui_px(10.0)))
        .clip()
        .child(UiElement::text(
            vec![
                TextSpan::new(
                    "Clicks are down 8% week over week.",
                    theme.chat_body_size(),
                    theme.text_primary,
                )
                .font(sample_font),
            ],
            TextLayoutOpts {
                max_width: Some(sample_w),
                max_lines: Some(2),
                ..Default::default()
            },
        ))
        .child(
            UiElement::row()
                .width(sample_w)
                .padding(Edges::xy(theme.ui_px(10.0), theme.ui_px(6.0)))
                .rounded(theme.ui_px(7.0))
                .bg(theme.code_bg)
                .border(1.0, theme.subtle_border)
                .child(mono_text(
                    "$ git log --oneline -5",
                    theme.chat_code_size(),
                    theme.text_primary,
                    sample_w - 20.0,
                    Some(1),
                )),
        );

    let chat_text_sec = form_section(
        theme,
        Some(("Chat text", None)),
        width,
        vec![
            form_row(
                theme,
                "Font",
                width,
                popup_button(
                    theme,
                    "chatFont",
                    font_lbl,
                    None,
                    font_act,
                    true,
                    hov.as_deref() == Some("chatFont"),
                ),
            ),
            form_row(
                theme,
                "Code font",
                width,
                mono_text(
                    "JetBrains Mono",
                    theme.body_size(),
                    theme.text_secondary,
                    160.0,
                    Some(1),
                )
                .id("chatCodeFont")
                .a11y(A11ySpec::new(A11yRole::StaticText, "JetBrains Mono")),
            ),
            form_row(theme, "Text scale", width, scale_trailing),
            sample_row,
        ],
        Some((
            "Text scale multiplies the interface scale. 100% uses the default chat sizes.",
            None,
        )),
    );

    // Quick Replies grouped section
    let edits_snapshot: Vec<_> = state
        .quick_reply_edits
        .iter()
        .map(|(_, t, m)| (t.clone(), m.clone()))
        .collect();
    let row_inner = (width - pad_x * 2.0).max(160.0);
    let title_w = theme.ui_px(148.0).min(row_inner * 0.34);
    let msg_w = (row_inner - title_w - theme.ui_px(42.0)).max(90.0);

    let mut qr_rows = Vec::with_capacity(edits_snapshot.len() + 2);
    if !edits_snapshot.is_empty() {
        qr_rows.push(crate::views::settings_agents::build_quick_replies_header_row(
            theme, width, pad_x, title_w, msg_w,
        ));
    }
    for (idx, (t_ed, m_ed)) in edits_snapshot.iter().enumerate() {
        let f_t = state
            .actions
            .register(AppAction::FocusField(FocusTarget::QuickReplyTitle(idx)));
        let f_m = state
            .actions
            .register(AppAction::FocusField(FocusTarget::QuickReplyMessage(idx)));
        let rm_id = if idx == 0 {
            "removeQuickReply".to_string()
        } else {
            format!("removeQuickReply-{idx}")
        };
        let rm_act = state
            .actions
            .register_named(&rm_id, AppAction::RemoveQuickReply(idx));
        let rm_hov = hov.as_deref() == Some(rm_id.as_str());

        qr_rows.push(
            UiElement::row()
                .width(width)
                .align_center()
                .gap(theme.ui_px(6.0))
                .padding(Edges::xy(pad_x, theme.ui_px(7.0)))
                .clip()
                .child(text_field_box(
                    theme,
                    format!("quickReplyTitle-{idx}"),
                    "Title",
                    "Title",
                    t_ed,
                    state.focus == Some(FocusTarget::QuickReplyTitle(idx)),
                    false,
                    title_w,
                    theme.ui_px(18.0),
                    f_t,
                ))
                .child(text_field_box(
                    theme,
                    format!("quickReplyMsg-{idx}"),
                    "Message",
                    "Message to send",
                    m_ed,
                    state.focus == Some(FocusTarget::QuickReplyMessage(idx)),
                    false,
                    msg_w,
                    theme.ui_px(18.0),
                    f_m,
                ))
                .child(icon_button(
                    theme,
                    rm_id,
                    "Remove Reply",
                    IconKind::MinusCircle,
                    rm_act,
                    false,
                    true,
                    rm_hov,
                )),
        );
    }

    qr_rows.push(crate::views::settings_agents::build_quick_replies_footer_row(
        state,
        theme,
        width,
        pad_x,
        hov.as_deref(),
    ));

    let qr_sec = form_section(
        theme,
        Some(("Quick replies", None)),
        width,
        qr_rows,
        Some((
            "Buttons above the message field send these at once, the first nine also with Option-Command-1 to 9.",
            None,
        )),
    );

    UiElement::column()
        .width(width)
        .gap(theme.ui_px(18.0))
        .child(chat_text_sec)
        .child(qr_sec)
}
