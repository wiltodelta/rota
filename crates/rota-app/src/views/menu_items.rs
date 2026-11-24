//! Menu item specifications for every `MenuId` dropdown across Rota.

use rota_core::model::{Harness, SessionFilter};
use rota_core::schedule::ScheduleText;
use rota_platform::{abbreviate_tilde, installed_terminals};
use rota_ui::Theme;

use crate::actions::{AppAction, MenuId, SchedulePreset};
use crate::app_state::AppState;
use crate::settings_store::{INTERFACE_SCALE_LEVELS, effort_title};
use crate::views::menu_overlay::{MenuEntry, default_model_label, model_efforts_for};
use crate::views::widgets::{harness_color, harness_icon};

pub fn entries_for_menu(state: &AppState, theme: &Theme, menu_id: &MenuId) -> Vec<MenuEntry> {
    match menu_id {
        MenuId::SessionFilter => {
            let mut out = vec![
                MenuEntry::item(
                    "filterItem-all",
                    "All Sessions",
                    state.session_filters.selected().is_empty(),
                    true,
                    AppAction::ToggleSessionFilter(SessionFilter::All),
                ),
                MenuEntry::sep(),
            ];
            for f in [
                SessionFilter::Running,
                SessionFilter::NeedsAttention,
                SessionFilter::Unread,
                SessionFilter::Failed,
                SessionFilter::Completed,
            ] {
                out.push(MenuEntry::item(
                    format!("filterItem-{}", f.as_str()),
                    f.title(),
                    state.session_filters.contains(f),
                    true,
                    AppAction::ToggleSessionFilter(f),
                ));
            }
            out
        }
        MenuId::RestartSession { sid, .. } => Harness::AGENTS
            .into_iter()
            .map(|h| {
                MenuEntry::item(
                    format!("restartWith-{}", h.as_str()),
                    h.title(),
                    false,
                    true,
                    AppAction::RestartSessionWith {
                        session_id: *sid,
                        harness: h,
                    },
                )
                .with_icon(harness_icon(h), harness_color(theme, h))
            })
            .collect(),
        MenuId::SessionModel(sid) => {
            let Some(rec) = state.scheduler.current_record(*sid) else {
                return Vec::new();
            };
            let cur = rec.model.as_deref();
            let mut out = vec![MenuEntry::item(
                "composerModel-default",
                default_model_label(&state.settings, rec.harness),
                cur.is_none(),
                true,
                AppAction::SetSessionModel {
                    session_id: *sid,
                    model: None,
                },
            )];
            if let Some(opts) = state.settings.models.get(&rec.harness)
                && !opts.is_empty()
            {
                out.push(MenuEntry::sep());
                for m in opts {
                    out.push(MenuEntry::item(
                        format!("composerModel-{}", m.id),
                        &m.title,
                        cur == Some(m.id.as_str()),
                        true,
                        AppAction::SetSessionModel {
                            session_id: *sid,
                            model: Some(m.id.clone()),
                        },
                    ));
                }
            }
            out
        }
        MenuId::SessionEffort(sid) => {
            let Some(rec) = state.scheduler.current_record(*sid) else {
                return Vec::new();
            };
            let cur = rec.effort.as_deref();
            let (_, efforts) = model_efforts_for(
                &state.settings,
                rec.harness,
                rec.reported_model.as_deref().or(rec.model.as_deref()),
            );
            let mut out = vec![MenuEntry::item(
                "composerEffort-default",
                "Default",
                cur.is_none(),
                true,
                AppAction::SetSessionEffort {
                    session_id: *sid,
                    effort: None,
                },
            )];
            if !efforts.is_empty() {
                out.push(MenuEntry::sep());
                for e in efforts {
                    out.push(MenuEntry::item(
                        format!("composerEffort-{e}"),
                        effort_title(&e),
                        cur == Some(e.as_str()),
                        true,
                        AppAction::SetSessionEffort {
                            session_id: *sid,
                            effort: Some(e),
                        },
                    ));
                }
            }
            out
        }
        MenuId::DiscussionAgent => {
            let cur = state.settings.discussion_agent;
            Harness::AGENTS
                .into_iter()
                .map(|h| {
                    MenuEntry::item(
                        format!("discussWith-{}", h.as_str()),
                        h.title(),
                        h == cur,
                        true,
                        AppAction::SelectDiscussionAgent(h),
                    )
                    .with_icon(harness_icon(h), harness_color(theme, h))
                })
                .collect()
        }
        MenuId::DiscussionModel => {
            let agent = state.settings.discussion_agent;
            let cur = state.settings.discussion_models.get(&agent).map(String::as_str);
            let mut out = vec![MenuEntry::item(
                "discussionModel-default",
                default_model_label(&state.settings, agent),
                cur.is_none(),
                true,
                AppAction::SetDiscussionModel(None),
            )];
            if let Some(opts) = state.settings.models.get(&agent)
                && !opts.is_empty()
            {
                out.push(MenuEntry::sep());
                for m in opts {
                    out.push(MenuEntry::item(
                        format!("discussionModel-{}", m.id),
                        &m.title,
                        cur == Some(m.id.as_str()),
                        true,
                        AppAction::SetDiscussionModel(Some(m.id.clone())),
                    ));
                }
            }
            out
        }
        MenuId::DiscussionEffort => {
            let agent = state.settings.discussion_agent;
            let model = state.settings.discussion_models.get(&agent).map(String::as_str);
            let cur = state.settings.discussion_efforts.get(&agent).map(String::as_str);
            let (_, efforts) = model_efforts_for(&state.settings, agent, model);
            let mut out = vec![MenuEntry::item(
                "discussionEffort-default",
                "Default",
                cur.is_none(),
                true,
                AppAction::SetDiscussionEffort(None),
            )];
            if !efforts.is_empty() {
                out.push(MenuEntry::sep());
                for e in efforts {
                    out.push(MenuEntry::item(
                        format!("discussionEffort-{e}"),
                        effort_title(&e),
                        cur == Some(e.as_str()),
                        true,
                        AppAction::SetDiscussionEffort(Some(e)),
                    ));
                }
            }
            out
        }
        other => entries_for_form_and_settings(state, theme, other),
    }
}

fn entries_for_form_and_settings(state: &AppState, theme: &Theme, menu_id: &MenuId) -> Vec<MenuEntry> {
    match menu_id {
        MenuId::FormHarness => {
            let cur = state.routine_modal.as_ref().map(|f| f.harness);
            Harness::ALL
                .into_iter()
                .map(|h| {
                    MenuEntry::item(
                        format!("routineHarness-{}", h.as_str()),
                        h.title(),
                        cur == Some(h),
                        true,
                        AppAction::FormSetHarness(h),
                    )
                    .with_icon(harness_icon(h), harness_color(theme, h))
                })
                .collect()
        }
        MenuId::FormModel => {
            let Some(form) = state.routine_modal.as_ref() else {
                return Vec::new();
            };
            let cur = form.model.as_deref();
            let mut out = vec![MenuEntry::item(
                "routineModel-default",
                default_model_label(&state.settings, form.harness),
                cur.is_none(),
                true,
                AppAction::FormSetModel(None),
            )];
            if let Some(opts) = state.settings.models.get(&form.harness)
                && !opts.is_empty()
            {
                out.push(MenuEntry::sep());
                for m in opts {
                    out.push(MenuEntry::item(
                        format!("routineModel-{}", m.id),
                        &m.title,
                        cur == Some(m.id.as_str()),
                        true,
                        AppAction::FormSetModel(Some(m.id.clone())),
                    ));
                }
            }
            out
        }
        MenuId::FormEffort => {
            let Some(form) = state.routine_modal.as_ref() else {
                return Vec::new();
            };
            let cur = form.effort.as_deref();
            let (_, efforts) = model_efforts_for(&state.settings, form.harness, form.model.as_deref());
            let mut out = vec![MenuEntry::item(
                "routineEffort-default",
                "Default",
                cur.is_none(),
                true,
                AppAction::FormSetEffort(None),
            )];
            if !efforts.is_empty() {
                out.push(MenuEntry::sep());
                for e in efforts {
                    out.push(MenuEntry::item(
                        format!("routineEffort-{e}"),
                        effort_title(&e),
                        cur == Some(e.as_str()),
                        true,
                        AppAction::FormSetEffort(Some(e)),
                    ));
                }
            }
            out
        }
        MenuId::FormRepeat => {
            let cur = state.routine_modal.as_ref().map(|f| f.preset);
            SchedulePreset::ALL
                .into_iter()
                .map(|p| {
                    MenuEntry::item(
                        format!("routineRepeat-{p:?}"),
                        p.title(),
                        cur == Some(p),
                        true,
                        AppAction::FormSetPreset(p),
                    )
                })
                .collect()
        }
        MenuId::FormCronPresets => ["0 * * * *", "0 9 * * *", "0 9 * * 1-5", "0 9 * * 1", "0 9 1 * *"]
            .into_iter()
            .enumerate()
            .map(|(i, cron)| {
                let lbl = ScheduleText::describe(cron).unwrap_or_else(|| cron.to_string());
                MenuEntry::item(
                    format!("cronPreset-{i}"),
                    lbl,
                    false,
                    true,
                    AppAction::FormApplyCron(cron.to_string()),
                )
            })
            .collect(),
        MenuId::FormEnds => {
            let has_limit = state
                .routine_modal
                .as_ref()
                .is_some_and(|f| f.run_limit.is_some());
            vec![
                MenuEntry::item(
                    "routineEnds-never",
                    "Never",
                    !has_limit,
                    true,
                    AppAction::FormSetRunLimitEnabled(false),
                ),
                MenuEntry::item(
                    "routineEnds-runs",
                    "After a Number of Runs",
                    has_limit,
                    true,
                    AppAction::FormSetRunLimitEnabled(true),
                ),
            ]
        }
        MenuId::ImportAgent => {
            let cur = state.import_modal.as_ref().and_then(|m| m.target_harness);
            let mut out = vec![
                MenuEntry::item(
                    "importAgent-original",
                    "Original agent",
                    cur.is_none(),
                    true,
                    AppAction::ImportSetTargetHarness(None),
                ),
                MenuEntry::sep(),
            ];
            for h in Harness::AGENTS {
                out.push(
                    MenuEntry::item(
                        format!("importAgent-{}", h.as_str()),
                        h.title(),
                        cur == Some(h),
                        true,
                        AppAction::ImportSetTargetHarness(Some(h)),
                    )
                    .with_icon(harness_icon(h), harness_color(theme, h)),
                );
            }
            out
        }
        MenuId::ScheduleOptions => vec![MenuEntry::item(
            "scheduleShowPausedMenuItem",
            "Show Paused Routines",
            state.settings.show_paused_in_schedule,
            true,
            AppAction::ToggleShowPausedInSchedule,
        )],
        MenuId::InterfaceScale => INTERFACE_SCALE_LEVELS
            .iter()
            .enumerate()
            .map(|(idx, &lvl)| {
                let pct = format!("{}%", (lvl * 100.0).round() as i32);
                let checked = (state.settings.interface_scale - lvl).abs() < 0.02;
                MenuEntry::item(
                    format!("scaleItem-{idx}"),
                    pct,
                    checked,
                    true,
                    AppAction::SetInterfaceScale(idx as u8),
                )
            })
            .collect(),
        MenuId::PreferredTerminal => {
            let cur = state.settings.preferred_terminal.as_deref();
            let mut out = vec![MenuEntry::item(
                "termItem-default",
                "Default (Terminal)",
                cur.is_none(),
                true,
                AppAction::SetPreferredTerminal(None),
            )];
            let terms = installed_terminals();
            if !terms.is_empty() {
                out.push(MenuEntry::sep());
                for t in terms {
                    out.push(MenuEntry::item(
                        format!("termItem-{}", t.bundle_id()),
                        t.title(),
                        cur == Some(t.bundle_id()),
                        true,
                        AppAction::SetPreferredTerminal(Some(t.bundle_id().to_string())),
                    ));
                }
            }
            out.push(MenuEntry::sep());
            out.push(MenuEntry::item(
                "termItem-choose",
                "Choose Other…",
                false,
                true,
                AppAction::ChooseCustomTerminal,
            ));
            out
        }
        MenuId::ChatFont => vec![
            MenuEntry::item(
                "chatFont-sans",
                "IBM Plex Sans",
                !state.settings.chat_font_mono,
                true,
                AppAction::SetChatFontMono(false),
            ),
            MenuEntry::item(
                "chatFont-mono",
                "JetBrains Mono",
                state.settings.chat_font_mono,
                true,
                AppAction::SetChatFontMono(true),
            ),
        ],
        MenuId::AgentCli(h) => {
            let chosen = state.settings.chosen_executable(*h);
            let auto_disp = state
                .settings
                .installed
                .get(h)
                .and_then(|v| v.first())
                .map_or_else(
                    || format!("Automatic ({})", abbreviate_tilde(&h.default_executable())),
                    |i| format!("Automatic ({})", abbreviate_tilde(&i.path)),
                );
            let mut out = vec![MenuEntry::item(
                format!("agentCli-{}-auto", h.as_str()),
                auto_disp,
                chosen.is_none(),
                true,
                AppAction::SetAgentExecutable {
                    harness: *h,
                    path: None,
                },
            )];
            if let Some(discovered) = state.settings.installed.get(h)
                && !discovered.is_empty()
            {
                out.push(MenuEntry::sep());
                for (i, inst) in discovered.iter().enumerate() {
                    let disp = abbreviate_tilde(&inst.path);
                    out.push(MenuEntry::item(
                        format!("agentCli-{}-{i}", h.as_str()),
                        disp,
                        chosen == Some(inst.path.as_str()),
                        true,
                        AppAction::SetAgentExecutable {
                            harness: *h,
                            path: Some(inst.path.clone()),
                        },
                    ));
                }
            }
            out.push(MenuEntry::sep());
            out.push(MenuEntry::item(
                format!("agentCli-{}-choose", h.as_str()),
                "Choose Other…",
                false,
                true,
                AppAction::ChooseAgentExecutable(*h),
            ));
            out
        }
        _ => Vec::new(),
    }
}
