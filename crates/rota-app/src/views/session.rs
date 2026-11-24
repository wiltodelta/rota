//! `SessionView`: adaptive Tahoe `SessionHeader` (1-row / 2-row / icon-only), banners, `ChatTranscript`, `showQuestion` bar, and `ChatComposer`.

use jiff::tz::TimeZone;
use rota_core::SessionRestart;
use rota_core::model::{Routine, RunOutcome, RunRecord, RunTrigger};
use rota_core::schedule::ScheduleText;
use rota_ui::{A11yRole, A11ySpec, Color, Edges, IconKind, Theme, UiElement};

use crate::actions::{AppAction, MenuId};
use crate::app_state::AppState;
use crate::views::session_banners::{build_attention_banner, build_notice_banner, build_usage_limit_banner};
use crate::views::widgets::{button, circle_action_button, hairline_h, label_1line, popup_button};
use crate::views::{composer, transcript_view};

pub fn build_session_view(
    state: &mut AppState,
    theme: &Theme,
    record: &RunRecord,
    routine: &Routine,
    width: f32,
    height: f32,
    now_seconds: f64,
) -> UiElement {
    let running = record.outcome == RunOutcome::Running;
    let _ = running.then(|| state.activity_clock.pulse_opacity(now_seconds));

    let single_row_hdr = (width - theme.ui_px(32.0)) >= theme.ui_px(460.0);
    let header = build_session_header(state, theme, record, routine, width, running, single_row_hdr);
    let base_hdr_h = if single_row_hdr { 50.0 } else { 80.0 };
    let header_est_h = theme.ui_px(
        base_hdr_h
            + if record.discussed_session_id.is_some() {
                24.0
            } else {
                0.0
            },
    );

    let hit_limit = !running
        && record.harness.is_agent()
        && state
            .transcripts
            .get(&record.id)
            .is_some_and(|t| SessionRestart::hit_usage_limit(&t.snapshot.items));

    let mut top_banners = Vec::new();
    let mut banners_h = 0.0f32;
    if hit_limit {
        banners_h += theme.ui_px(96.0);
        top_banners.push(build_usage_limit_banner(state, theme, record, width));
    }
    if let Some(compat) = record.compatibility_notice() {
        banners_h += theme.ui_px(46.0);
        top_banners.push(build_notice_banner(
            theme,
            "harnessCompatibilityNotice",
            &compat,
            width,
        ));
    }
    if let Some(attn) = &record.attention
        && record.questions.as_ref().is_none_or(Vec::is_empty)
    {
        banners_h += theme.ui_px(58.0);
        top_banners.push(build_attention_banner(state, theme, record, attn, width));
    }

    let has_question = record.next_question().is_some();
    let q_fully_visible = state
        .transcripts
        .get(&record.id)
        .is_some_and(|t| t.question_fully_visible);
    let show_q_bar = has_question && !q_fully_visible;
    let show_q_h = if show_q_bar { theme.ui_px(38.0) } else { 0.0 };
    let has_atts = state
        .composer_attachments
        .get(&record.id)
        .is_some_and(|v| !v.is_empty());
    let extra_lines = composer::extra_draft_lines(state, record.id, width, theme);
    let extra_comp = (if has_atts { 30.0 } else { 0.0 })
        + (extra_lines as f32) * 19.5
        + (if record.has_blocking_question() || state.composer_error.is_some() {
            20.0
        } else {
            0.0
        });
    let composer_h = theme.ui_px((if has_question { 106.0 } else { 142.0 }) + extra_comp);
    let transcript_h = (height - header_est_h - banners_h - show_q_h - composer_h - 1.0).max(120.0);

    let transcript =
        transcript_view::build_transcript(state, theme, record, width, transcript_h, now_seconds);

    let mut col = UiElement::column()
        .width(width)
        .height(height)
        .bg(theme.surface)
        .clip()
        .child(header)
        .child(hairline_h(theme));

    for b in top_banners {
        col = col.child(b);
    }

    col = col.child(transcript);

    if show_q_bar {
        let rev_act = state
            .actions
            .register_named("showQuestion", AppAction::RevealQuestion(record.id));
        let hovered = state.is_hovered("showQuestion");
        let pad_x = ((width - 720.0) * 0.5).max(theme.ui_px(24.0));
        col = col.child(
            UiElement::row()
                .width(width)
                .height(show_q_h)
                .align_center()
                .justify_between()
                .padding(Edges::xy(pad_x, theme.ui_px(4.0)))
                .bg(theme.surface)
                .clip()
                .child(label_1line(
                    "Needs your reply",
                    theme.body_size(),
                    theme.text_secondary,
                    width * 0.45,
                ))
                .child(button(
                    theme,
                    "showQuestion",
                    "Show Question",
                    None,
                    rev_act,
                    false,
                    false,
                    true,
                    hovered,
                )),
        );
    }

    let comp = composer::build_composer(state, theme, record, width, composer_h, now_seconds);
    col.child(comp)
}

fn build_session_header(
    state: &mut AppState,
    theme: &Theme,
    record: &RunRecord,
    routine: &Routine,
    width: f32,
    running: bool,
    single_row: bool,
) -> UiElement {
    let pad_x = theme.ui_px(16.0);
    let inner_w = (width - pad_x * 2.0).max(200.0);
    let tz = TimeZone::system();
    let started_str = ScheduleText::format_abbreviated_date_time(record.started_at, &tz);

    let status_word = if record.needs_attention() {
        if record.harness.takes_messages() {
            "Needs your reply".to_string()
        } else {
            "Needs your attention".to_string()
        }
    } else {
        record.status_title()
    };
    let sub_meta = if record.trigger == RunTrigger::CatchUp {
        format!(
            "{} · missed slot, run late · {status_word}",
            record.harness.title()
        )
    } else {
        format!("{} · {status_word}", record.harness.title())
    };

    let hovered = state.hovered_id.clone();
    let show_routine_act = state.actions.register_named(
        "showSessionRoutine",
        AppAction::ShowSessionRoutine(routine.id.clone()),
    );

    let icon_only_actions = inner_w < theme.ui_px(670.0);
    let sum_max_w = if single_row {
        let actions_w = if icon_only_actions { 276.0 } else { 496.0 };
        (inner_w - theme.ui_px(actions_w)).max(120.0)
    } else {
        (inner_w - theme.ui_px(148.0)).max(120.0)
    };

    // Regular weight for started timestamp (`SessionHeader.swift:41`)
    let mut summary_col = UiElement::column()
        .width(sum_max_w)
        .gap(theme.ui_px(2.0))
        .clip()
        .child(label_1line(
            &started_str,
            theme.body_size(),
            theme.text_primary,
            sum_max_w,
        ))
        .child(label_1line(
            &sub_meta,
            theme.caption_size(),
            if record.needs_attention() {
                theme.warning
            } else if record.outcome.is_failure() {
                theme.danger
            } else {
                theme.text_secondary
            },
            sum_max_w,
        ));

    if let Some(disc_id) = record.discussed_session_id {
        let open_src = state
            .actions
            .register_named("discussedSession", AppAction::SelectSession(disc_id));
        let disc_hov = state.is_hovered("discussedSession");
        summary_col = summary_col.child(
            UiElement::row()
                .id("discussedSession")
                .min_height(theme.ui_px(24.0))
                .align_center()
                .gap(theme.ui_px(4.0))
                .padding(Edges::xy(theme.ui_px(4.0), theme.ui_px(2.0)))
                .rounded(theme.ui_px(6.0))
                .bg(if disc_hov {
                    theme.subtle_hover
                } else {
                    Color::TRANSPARENT
                })
                .on_click(open_src)
                .a11y(A11ySpec::new(A11yRole::Button, "Open discussed Shell session"))
                .child(UiElement::icon(
                    IconKind::Terminal,
                    theme.ui_px(11.5),
                    theme.accent,
                ))
                .child(label_1line(
                    "Shell run",
                    theme.caption_size(),
                    theme.accent,
                    sum_max_w - 24.0,
                )),
        );
    }

    let show_routine_btn = button(
        theme,
        "showSessionRoutine",
        "Show Routine",
        Some(IconKind::Calendar),
        show_routine_act,
        false,
        false,
        true,
        hovered.as_deref() == Some("showSessionRoutine"),
    );

    let actions_row = build_header_actions(state, theme, record, running, icon_only_actions);

    if single_row {
        UiElement::row()
            .width(width)
            .align_center()
            .justify_between()
            .padding(Edges::xy(pad_x, theme.ui_px(10.0)))
            .bg(theme.surface)
            .clip()
            .child(summary_col)
            .child(
                UiElement::row()
                    .align_center()
                    .gap(theme.ui_px(8.0))
                    .flex_shrink(0.0)
                    .child(show_routine_btn)
                    .child(actions_row),
            )
    } else {
        let top_row = UiElement::row()
            .width(inner_w)
            .align_center()
            .justify_between()
            .clip()
            .child(summary_col)
            .child(show_routine_btn);

        UiElement::column()
            .width(width)
            .padding(Edges::new(theme.ui_px(8.0), pad_x, theme.ui_px(10.0), pad_x))
            .gap(theme.ui_px(8.0))
            .bg(theme.surface)
            .clip()
            .child(top_row)
            .child(
                UiElement::row()
                    .width(inner_w)
                    .align_center()
                    .justify_end()
                    .clip()
                    .child(actions_row),
            )
    }
}

fn build_header_actions(
    state: &mut AppState,
    theme: &Theme,
    record: &RunRecord,
    running: bool,
    icon_only: bool,
) -> UiElement {
    let hovered = state.hovered_id.clone();
    let term_act = state
        .actions
        .register_named("openTerminal", AppAction::OpenInTerminal(record.id));
    let log_act = state
        .actions
        .register_named("showSessionLog", AppAction::RevealSessionLog(record.id));
    let restart_act = state.actions.register_named(
        "restartSession",
        AppAction::OpenMenu(MenuId::RestartSession {
            sid: record.id,
            after_limit: false,
        }),
    );
    let del_act = state
        .actions
        .register_named("deleteSession", AppAction::PromptDeleteSession(record.id));
    let can_open_terminal = running
        || record
            .session_id
            .as_deref()
            .is_some_and(|sid| record.harness.terminal(sid, running).is_some());

    let mut actions_row = UiElement::row()
        .align_center()
        .gap(theme.ui_px(8.0))
        .flex_shrink(0.0);

    if record.harness.is_agent() && !running {
        if icon_only {
            actions_row = actions_row.child(circle_action_button(
                theme,
                "restartSession",
                "Restart with…",
                IconKind::Refresh,
                restart_act,
                false,
                false,
                true,
                hovered.as_deref() == Some("restartSession"),
            ));
        } else {
            actions_row = actions_row.child(popup_button(
                theme,
                "restartSession",
                "Restart with…",
                Some(IconKind::Refresh),
                restart_act,
                true,
                hovered.as_deref() == Some("restartSession"),
            ));
        }
    }

    if running && !record.harness.takes_messages() {
        let stop_act = state
            .actions
            .register_named("stopSession", AppAction::StopSession(record.id));
        actions_row = actions_row.child(button(
            theme,
            "stopSession",
            "Stop",
            Some(IconKind::Stop),
            stop_act,
            false,
            true,
            true,
            hovered.as_deref() == Some("stopSession"),
        ));
    }

    if can_open_terminal {
        let term_title = if running {
            "Open in Terminal"
        } else {
            "Continue in Terminal"
        };
        if icon_only {
            actions_row = actions_row.child(circle_action_button(
                theme,
                "openTerminal",
                term_title,
                IconKind::Terminal,
                term_act,
                false,
                false,
                true,
                hovered.as_deref() == Some("openTerminal"),
            ));
        } else {
            actions_row = actions_row.child(button(
                theme,
                "openTerminal",
                term_title,
                Some(IconKind::Terminal),
                term_act,
                false,
                false,
                true,
                hovered.as_deref() == Some("openTerminal"),
            ));
        }
    }

    if record.log_path.is_some() {
        actions_row = actions_row.child(circle_action_button(
            theme,
            "showSessionLog",
            "Show Log in Finder",
            IconKind::FileText,
            log_act,
            false,
            false,
            true,
            hovered.as_deref() == Some("showSessionLog"),
        ));
    }

    actions_row.child(circle_action_button(
        theme,
        "deleteSession",
        "Delete Session…",
        IconKind::Trash,
        del_act,
        false,
        false,
        !running,
        hovered.as_deref() == Some("deleteSession"),
    ))
}
