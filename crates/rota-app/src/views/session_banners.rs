//! Session compatibility notices, usage-limit banners (`sessionUsageLimit`), and attention banners.

use rota_core::model::RunRecord;
use rota_ui::{A11yRole, A11ySpec, Color, Edges, IconKind, Theme, UiElement};

use crate::actions::{AppAction, MenuId, SettingsPane};
use crate::app_state::AppState;
use crate::settings_store::effort_title;
use crate::views::menu_overlay::model_efforts_for;
use crate::views::widgets::{
    button, harness_color, harness_icon, label_1line, label_semibold_1line, label_wrapped, popup_button,
};

pub fn build_error_banner(state: &mut AppState, theme: &Theme, text: &str, width: f32) -> UiElement {
    let pad_x = ((width - 720.0) * 0.5).max(theme.ui_px(16.0));
    let box_w = (width - pad_x * 2.0).clamp(180.0, 720.0);
    let dismiss_act = state
        .actions
        .register_named("dismissErrorBanner", AppAction::DismissErrorBanner);
    let hov = state.is_hovered("dismissErrorBanner");
    UiElement::row()
        .width(width)
        .padding(Edges::xy(pad_x, theme.ui_px(6.0)))
        .bg(theme.surface)
        .clip()
        .child(
            UiElement::row()
                .id("appErrorBanner")
                .width(box_w)
                .align_center()
                .justify_between()
                .gap(theme.ui_px(10.0))
                .padding(Edges::xy(theme.ui_px(12.0), theme.ui_px(6.0)))
                .rounded(theme.ui_px(10.0))
                .bg(theme.danger.with_alpha(0.10))
                .border(1.0, theme.danger.with_alpha(0.32))
                .clip()
                .a11y(A11ySpec::new(A11yRole::Group, text))
                .child(
                    UiElement::row()
                        .align_center()
                        .gap(theme.ui_px(8.0))
                        .clip()
                        .child(UiElement::icon(
                            IconKind::Warning,
                            theme.ui_px(14.0),
                            theme.danger,
                        ))
                        .child(label_1line(
                            text,
                            theme.caption_size(),
                            theme.danger,
                            (box_w - theme.ui_px(110.0)).max(80.0),
                        )),
                )
                .child(button(
                    theme,
                    "dismissErrorBanner",
                    "Dismiss",
                    None,
                    dismiss_act,
                    false,
                    false,
                    true,
                    hov,
                )),
        )
}

pub fn build_usage_limit_banner(
    state: &mut AppState,
    theme: &Theme,
    record: &RunRecord,
    width: f32,
) -> UiElement {
    let pad_x = ((width - 720.0) * 0.5).max(theme.ui_px(24.0));
    let box_w = (width - pad_x * 2.0).clamp(200.0, 720.0);
    let restart_act = state.actions.register_named(
        "restartSessionAfterLimit",
        AppAction::OpenMenu(MenuId::RestartSession {
            sid: record.id,
            after_limit: true,
        }),
    );
    let hov = state.is_hovered("restartSessionAfterLimit");

    UiElement::row()
        .width(width)
        .padding(Edges::new(theme.ui_px(10.0), pad_x, theme.ui_px(4.0), pad_x))
        .clip()
        .child(
            UiElement::column()
                .id("sessionUsageLimit")
                .width(box_w)
                .gap(theme.ui_px(6.0))
                .padding(Edges::all(theme.ui_px(14.0)))
                .rounded(theme.ui_px(10.0))
                .bg(theme.warning.with_alpha(0.11))
                .border(1.0, theme.warning.with_alpha(0.32))
                .clip()
                .a11y(A11ySpec::new(A11yRole::Group, "Usage limit reached"))
                .child(label_semibold_1line(
                    "Usage limit reached",
                    theme.body_size(),
                    theme.text_primary,
                    box_w - 28.0,
                ))
                .child(label_wrapped(
                    "Continue in another harness. This routine's scheduled harness stays the same.",
                    theme.caption_size(),
                    theme.text_secondary,
                    box_w - 28.0,
                    Some(2),
                ))
                .child(UiElement::row().child(popup_button(
                    theme,
                    "restartSessionAfterLimit",
                    "Restart with…",
                    Some(IconKind::Refresh),
                    restart_act,
                    true,
                    hov,
                ))),
        )
}

pub fn build_notice_banner(theme: &Theme, id: &str, text: &str, width: f32) -> UiElement {
    let pad_x = ((width - 720.0) * 0.5).max(theme.ui_px(24.0));
    let box_w = (width - pad_x * 2.0).clamp(180.0, 720.0);
    UiElement::row()
        .width(width)
        .padding(Edges::xy(pad_x, theme.ui_px(6.0)))
        .clip()
        .child(
            UiElement::row()
                .id(id)
                .width(box_w)
                .align_center()
                .gap(theme.ui_px(8.0))
                .padding(Edges::xy(theme.ui_px(12.0), theme.ui_px(8.0)))
                .rounded(theme.ui_px(10.0))
                .bg(theme.warning.with_alpha(0.10))
                .border(1.0, theme.warning.with_alpha(0.32))
                .clip()
                .a11y(A11ySpec::new(A11yRole::Group, text))
                .child(UiElement::icon(
                    IconKind::Warning,
                    theme.ui_px(14.0),
                    theme.warning,
                ))
                .child(label_wrapped(
                    text,
                    theme.caption_size(),
                    theme.text_primary,
                    box_w - 44.0,
                    Some(2),
                )),
        )
}

pub fn build_attention_banner(
    state: &mut AppState,
    theme: &Theme,
    record: &RunRecord,
    text: &str,
    width: f32,
) -> UiElement {
    let can_reply = record.harness.takes_messages();
    let heading = if can_reply {
        "Needs your reply"
    } else {
        "Needs your attention"
    };
    let pad_x = ((width - 720.0) * 0.5).max(theme.ui_px(24.0));
    let box_w = (width - pad_x * 2.0).clamp(200.0, 720.0);
    let dismiss_act = state
        .actions
        .register_named("dismissAttention", AppAction::DismissAttention(record.id));
    let hovered = state.is_hovered("dismissAttention");

    UiElement::row()
        .width(width)
        .padding(Edges::xy(pad_x, theme.ui_px(6.0)))
        .clip()
        .child(
            UiElement::row()
                .width(box_w)
                .align_center()
                .justify_between()
                .gap(theme.ui_px(10.0))
                .padding(Edges::xy(theme.ui_px(14.0), theme.ui_px(8.0)))
                .rounded(theme.ui_px(10.0))
                .bg(theme.warning.with_alpha(0.11))
                .border(1.0, theme.warning.with_alpha(0.35))
                .clip()
                .child(
                    UiElement::column()
                        .width((box_w - theme.ui_px(110.0)).max(80.0))
                        .gap(theme.ui_px(2.0))
                        .clip()
                        .child(
                            label_semibold_1line(heading, theme.caption_size(), theme.warning, box_w - 110.0)
                                .id("attentionBanner")
                                .a11y(A11ySpec {
                                    role: A11yRole::StaticText,
                                    title: heading.to_string(),
                                    value: Some(heading.to_string()),
                                    selected: false,
                                    enabled: true,
                                    focused: false,
                                }),
                        )
                        .child(label_wrapped(
                            text,
                            theme.caption_size(),
                            theme.text_primary,
                            box_w - 110.0,
                            Some(2),
                        )),
                )
                .child(button(
                    theme,
                    "dismissAttention",
                    if can_reply { "Dismiss" } else { "Done" },
                    None,
                    dismiss_act,
                    false,
                    false,
                    true,
                    hovered,
                )),
        )
}

pub fn build_agent_composer_footer(
    state: &mut AppState,
    theme: &Theme,
    record: &RunRecord,
    max_w: f32,
) -> UiElement {
    let sid = record.id;
    let model_id = record.reported_model.as_deref().or(record.model.as_deref());
    let model_label = record
        .reported_model_title
        .clone()
        .or_else(|| model_id.map(|m| state.settings.model_title(m, record.harness, None)))
        .or_else(|| {
            state
                .settings
                .models
                .get(&record.harness)
                .and_then(|opts| opts.iter().find(|o| o.is_default).or_else(|| opts.first()))
                .map(|o| o.title.clone())
        })
        .unwrap_or_else(|| "Default model".to_string());

    let (effort_fixed, _) = model_efforts_for(&state.settings, record.harness, model_id);
    let effort_opt = record
        .reported_effort
        .as_deref()
        .or(record.effort.as_deref())
        .map(effort_title);

    let compact = max_w < theme.ui_px(280.0);
    let model_disp = if compact && model_label == "Default model" {
        "Model"
    } else {
        model_label.as_str()
    };
    let mut row = UiElement::row()
        .align_center()
        .gap(theme.ui_px(6.0))
        .clip()
        .child(UiElement::icon(
            harness_icon(record.harness),
            theme.ui_px(14.0),
            harness_color(theme, record.harness),
        ))
        .child(footer_menu_pill(
            state,
            theme,
            "composerModel",
            "Model",
            model_disp,
            &model_label,
            None,
            Some(MenuId::SessionModel(sid)),
            max_w * 0.56,
        ));

    if !effort_fixed || effort_opt.is_some() {
        let eff_lbl = effort_opt.unwrap_or_else(|| "Default effort".to_string());
        let eff_disp = if compact && eff_lbl == "Default effort" {
            "Effort"
        } else {
            eff_lbl.as_str()
        };
        row = row.child(footer_menu_pill(
            state,
            theme,
            "composerEffort",
            "Reasoning Effort",
            eff_disp,
            &eff_lbl,
            None,
            (!effort_fixed).then_some(MenuId::SessionEffort(sid)),
            100.0,
        ));
    }
    row
}

pub fn build_shell_discussion_footer(state: &mut AppState, theme: &Theme, max_w: f32) -> UiElement {
    let cur_agent = state.settings.discussion_agent;
    let model_id = state
        .settings
        .discussion_models
        .get(&cur_agent)
        .map(String::as_str);
    let model_lbl = model_id
        .map(|m| state.settings.model_title(m, cur_agent, None))
        .or_else(|| {
            state
                .settings
                .models
                .get(&cur_agent)
                .and_then(|opts| opts.iter().find(|o| o.is_default).or_else(|| opts.first()))
                .map(|o| o.title.clone())
        })
        .unwrap_or_else(|| "Default model".to_string());
    let (effort_fixed, _) = model_efforts_for(&state.settings, cur_agent, model_id);
    let eff_lbl = state
        .settings
        .discussion_efforts
        .get(&cur_agent)
        .map(|e| effort_title(e))
        .unwrap_or_else(|| "Default effort".to_string());

    let compact = max_w < theme.ui_px(320.0);
    let model_disp = if compact && model_lbl == "Default model" {
        "Model"
    } else {
        model_lbl.as_str()
    };
    let eff_disp = if compact && eff_lbl == "Default effort" {
        "Effort"
    } else {
        eff_lbl.as_str()
    };

    let mut row = UiElement::row()
        .align_center()
        .gap(theme.ui_px(6.0))
        .clip()
        .child(footer_menu_pill(
            state,
            theme,
            "discussionAgent",
            "Agent",
            cur_agent.title(),
            cur_agent.title(),
            Some((harness_icon(cur_agent), harness_color(theme, cur_agent))),
            Some(MenuId::DiscussionAgent),
            120.0,
        ))
        .child(footer_menu_pill(
            state,
            theme,
            "discussionModel",
            "Model",
            model_disp,
            &model_lbl,
            None,
            Some(MenuId::DiscussionModel),
            max_w * 0.44,
        ));

    if !effort_fixed {
        row = row.child(footer_menu_pill(
            state,
            theme,
            "discussionEffort",
            "Reasoning Effort",
            eff_disp,
            &eff_lbl,
            None,
            Some(MenuId::DiscussionEffort),
            96.0,
        ));
    }

    let exe = state.settings.effective_executable(cur_agent);
    if !std::path::Path::new(&exe).is_file() {
        let open_ag = state.actions.register_named(
            "discussionAgentSettings",
            AppAction::OpenSettings(Some(SettingsPane::Agents)),
        );
        let hov = state.is_hovered("discussionAgentSettings");
        row = row.child(button(
            theme,
            "discussionAgentSettings",
            "Agent Settings…",
            None,
            open_ag,
            false,
            false,
            true,
            hov,
        ));
    }
    row
}

#[allow(clippy::too_many_arguments)]
fn footer_menu_pill(
    state: &mut AppState,
    theme: &Theme,
    id: &str,
    a11y_title: &str,
    display_label: &str,
    a11y_value: &str,
    lead_icon: Option<(IconKind, Color)>,
    menu: Option<MenuId>,
    max_w: f32,
) -> UiElement {
    let hov = state.is_hovered(id);
    let enabled = menu.is_some();
    let mut spec = A11ySpec::new(A11yRole::PopUpButton, a11y_title);
    spec.value = Some(a11y_value.to_string());
    spec.enabled = enabled;

    let mut pill = UiElement::row()
        .id(id.to_string())
        .min_height(theme.ui_px(24.0))
        .align_center()
        .gap(theme.ui_px(4.5))
        .padding(Edges::xy(theme.ui_px(6.0), theme.ui_px(2.5)))
        .rounded(theme.ui_px(6.0))
        .bg(if hov && enabled {
            theme.subtle_hover
        } else {
            Color::TRANSPARENT
        })
        .clip()
        .a11y(spec);
    if let Some((ic, col)) = lead_icon {
        pill = pill.child(UiElement::icon(ic, theme.ui_px(13.5), col));
    }
    pill = pill.child(label_1line(
        display_label,
        theme.caption_size(),
        theme.text_secondary,
        max_w,
    ));
    if let Some(m) = menu {
        let act = state.actions.register_named(id, AppAction::OpenMenu(m));
        pill = pill.on_click(act).child(UiElement::icon(
            IconKind::ChevronDown,
            theme.ui_px(9.5),
            theme.text_muted,
        ));
    }
    pill
}
