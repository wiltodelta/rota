//! Unified Tahoe `ChatComposer` (`id: "chatComposer"`): Liquid Glass QuickReply chips, borderless-interior composer card, model/effort menus, and Shell discussion controls.

use jiff::Timestamp;
use jiff::tz::TimeZone;
use rota_core::model::serde_ext::uppercase_uuid;
use rota_core::model::{Harness, RunOutcome, RunRecord};
use rota_core::schedule::ScheduleText;
use rota_ui::{
    A11yRole, A11ySpec, Appearance, Color, Edges, IconKind, Point, ReturnBehavior, TextEditState, Theme,
    UiElement,
};

use crate::actions::{AppAction, FocusTarget};
use crate::app_state::AppState;
use crate::views::session_banners::{build_agent_composer_footer, build_shell_discussion_footer};
use crate::views::widgets::{
    borderless_text_editor_with_preedit, button, circle_action_button, harness_icon, label_1line, mono_text,
};
use uuid::Uuid;

/// Estimates wrapped line count beyond line 1 (`0..=5` extra lines) so multi-line prompts smoothly expand the composer.
pub fn extra_draft_lines(state: &AppState, session_id: Uuid, width: f32, theme: &Theme) -> usize {
    let Some(ed) = state.composer_drafts.get(&session_id) else {
        return 0;
    };
    let txt = ed.text();
    if txt.is_empty() {
        return 0;
    }
    let pad_x = ((width - 720.0) * 0.5).max(theme.ui_px(24.0));
    let inner_w = ((width - pad_x * 2.0).clamp(180.0, 720.0) - theme.ui_px(34.0)).max(120.0);
    let chars_per_line = (inner_w / theme.ui_px(7.4)).floor().max(18.0) as usize;
    let total_lines: usize = txt
        .split('\n')
        .map(|line| {
            let n = line.chars().count().max(1);
            n.div_ceil(chars_per_line)
        })
        .sum();
    total_lines.saturating_sub(1).min(5)
}

pub fn build_composer(
    state: &mut AppState,
    theme: &Theme,
    record: &RunRecord,
    width: f32,
    height: f32,
    now_seconds: f64,
) -> UiElement {
    let _ = now_seconds;
    let running = record.outcome == RunOutcome::Running;
    let is_shell = record.harness == Harness::Shell;

    let pad_x = ((width - 720.0) * 0.5).max(theme.ui_px(24.0));
    let box_w = (width - pad_x * 2.0).clamp(180.0, 720.0);

    if is_shell && running {
        return UiElement::column()
            .id("chatComposer")
            .width(width)
            .height(height)
            .align_center()
            .padding(Edges::xy(pad_x, theme.ui_px(24.0)))
            .bg(theme.surface)
            .clip()
            .a11y(A11ySpec::new(A11yRole::Group, "Composer"))
            .child(label_1line(
                "Open in Terminal to interact with this running command.",
                theme.body_size(),
                theme.text_muted,
                box_w,
            ));
    }

    let sid = record.id;
    let draft_state = state
        .composer_drafts
        .entry(sid)
        .or_insert_with(|| TextEditState::multi_line("", ReturnBehavior::SubmitOnReturn))
        .clone();
    let attachments = state.composer_attachments.get(&sid).cloned().unwrap_or_default();
    let has_question = record.next_question().is_some();
    let has_blocking_q = record.has_blocking_question();
    let focused = state.focus == Some(FocusTarget::Composer);

    let mut outer = UiElement::column()
        .id("chatComposer")
        .width(width)
        .height(height)
        .padding(Edges::new(theme.ui_px(4.0), pad_x, theme.ui_px(12.0), pad_x))
        .gap(theme.ui_px(8.0))
        .bg(theme.surface)
        .clip()
        .a11y(A11ySpec::new(A11yRole::Group, "Composer"));

    if is_shell {
        let tz = TimeZone::system();
        let discussions: Vec<RunRecord> = state
            .sessions
            .iter()
            .filter(|s| s.discussed_session_id == Some(sid))
            .cloned()
            .collect();
        if !discussions.is_empty() {
            let mut d_row = UiElement::row()
                .width(box_w)
                .align_center()
                .padding(Edges::xy(0.0, theme.ui_px(2.0)))
                .gap(theme.ui_px(6.0));
            for d in discussions.iter().take(4) {
                let d_uuid = uppercase_uuid(d.id);
                let d_id = format!("shellDiscussion-{d_uuid}");
                let d_hov = state.is_hovered(&d_id);
                let act = state
                    .actions
                    .register_named(&d_id, AppAction::SelectSession(d.id));
                let lbl = format!(
                    "{}, {}",
                    d.harness.title(),
                    ScheduleText::format_short_time(d.started_at, &tz)
                );
                d_row = d_row.child(button(
                    theme,
                    d_id,
                    &lbl,
                    Some(harness_icon(d.harness)),
                    act,
                    false,
                    false,
                    true,
                    d_hov,
                ));
            }
            outer = outer.child(d_row);
        }
    } else if !has_question && record.attention.is_none() {
        let replies = state.settings.sendable_replies();
        if !replies.is_empty() {
            let mut qr_row = UiElement::row()
                .id("quickReplies")
                .width(box_w)
                .align_center()
                .padding(Edges::xy(0.0, theme.ui_px(2.0)))
                .gap(theme.ui_px(8.0))
                .a11y(A11ySpec::new(A11yRole::Group, "Quick Replies"));
            for (idx, qr) in replies.iter().enumerate().take(5) {
                let qr_id = format!("quickReply-{}", idx + 1);
                let act = state.actions.register_named(
                    &qr_id,
                    AppAction::SendQuickReply {
                        session_id: sid,
                        index: idx,
                    },
                );
                let hovered = state.is_hovered(&qr_id);
                qr_row = qr_row.child(
                    UiElement::row()
                        .id(qr_id)
                        .align_center()
                        .height(theme.ui_px(28.0))
                        .padding(Edges::xy(theme.ui_px(12.0), theme.ui_px(4.0)))
                        .rounded(theme.ui_px(14.0))
                        .bg(if hovered {
                            theme.subtle_hover
                        } else {
                            theme.elevated
                        })
                        .border(1.0, theme.border)
                        .shadow(6.0, Point::new(0.0, 1.5), theme.shadow_color)
                        .flex_shrink(0.0)
                        .on_click(act)
                        .a11y(A11ySpec::new(A11yRole::Button, qr.label()))
                        .child(
                            label_1line(qr.label(), theme.body_size(), theme.text_primary, 180.0)
                                .flex_shrink(0.0),
                        ),
                );
            }
            outer = outer.child(qr_row);
        }
    }

    let box_fill = match theme.appearance {
        Appearance::Light => Color::rgb_hex(0xFAFAFC),
        Appearance::Dark => Color::rgb_hex(0x232326),
    };
    let inner_pad_x = theme.ui_px(15.0);
    let inner_w = (box_w - inner_pad_x * 2.0).max(120.0);
    let mut box_card = UiElement::column()
        .width(box_w)
        .padding(Edges::new(
            theme.ui_px(12.0),
            inner_pad_x,
            theme.ui_px(10.0),
            inner_pad_x,
        ))
        .gap(theme.ui_px(6.0))
        .rounded(theme.ui_px(20.0))
        .bg(box_fill)
        .border(
            if state.file_drop_hovered { 1.5 } else { 1.0 },
            if state.file_drop_hovered {
                theme.selection_fill
            } else if focused {
                theme.selection_fill.with_alpha(0.55)
            } else {
                theme.border
            },
        )
        .shadow(8.0, Point::new(0.0, 2.0), theme.shadow_color)
        .clip();

    if !attachments.is_empty() {
        let mut att_row = UiElement::row()
            .width(inner_w)
            .align_center()
            .gap(theme.ui_px(6.0))
            .clip();
        for (idx, att) in attachments.iter().enumerate() {
            let att_id = format!("stagedAttachment-{idx}");
            let att_hov = state.is_hovered(&att_id);
            let rm_act = state.actions.register(AppAction::RemoveAttachment {
                session_id: sid,
                index: idx,
            });
            att_row = att_row.child(
                UiElement::row()
                    .id(att_id)
                    .min_height(theme.ui_px(24.0))
                    .align_center()
                    .gap(theme.ui_px(4.0))
                    .padding(Edges::xy(theme.ui_px(8.0), theme.ui_px(2.5)))
                    .rounded(theme.ui_px(8.0))
                    .bg(if att_hov {
                        theme.subtle_hover
                    } else {
                        theme.elevated
                    })
                    .border(1.0, theme.border)
                    .on_click(rm_act)
                    .a11y(A11ySpec::new(A11yRole::Button, format!("Remove {}", att.name)))
                    .child(UiElement::icon(
                        IconKind::Paperclip,
                        theme.ui_px(11.0),
                        theme.selection_fill,
                    ))
                    .child(label_1line(
                        &att.name,
                        theme.caption_size(),
                        theme.text_primary,
                        140.0,
                    ))
                    .child(UiElement::icon(
                        IconKind::Close,
                        theme.ui_px(10.0),
                        theme.text_muted,
                    )),
            );
        }
        box_card = box_card.child(att_row);
    }

    let placeholder = if is_shell {
        "Ask an agent about this run…"
    } else if running {
        "Message the running session…"
    } else {
        "Continue this session"
    };
    let extra_lines = extra_draft_lines(state, sid, width, theme);
    let focus_act = state
        .actions
        .register(AppAction::FocusField(FocusTarget::Composer));
    let editor = borderless_text_editor_with_preedit(
        theme,
        "composer",
        "Message",
        placeholder,
        &draft_state,
        &state.ime_preedit,
        focused,
        state.settings.chat_font_mono,
        inner_w,
        theme.ui_px((if has_question { 22.0 } else { 26.0 }) + (extra_lines as f32) * 19.5),
        focus_act,
    );
    box_card = box_card.child(editor);

    let can_send = !has_blocking_q && (!draft_state.text().trim().is_empty() || !attachments.is_empty());
    let left_meta = if is_shell {
        build_shell_discussion_footer(state, theme, inner_w * 0.72)
    } else {
        build_agent_composer_footer(state, theme, record, inner_w * 0.72)
    };

    let hovered = state.hovered_id.clone();
    let mut right_btns = UiElement::row().align_center().gap(theme.ui_px(6.0));
    if !is_shell {
        let att_act = state
            .actions
            .register_named("attachFiles", AppAction::AttachFiles(sid));
        right_btns = right_btns.child(circle_action_button(
            theme,
            "attachFiles",
            "Attach Files…",
            IconKind::Paperclip,
            att_act,
            false,
            false,
            true,
            hovered.as_deref() == Some("attachFiles"),
        ));
    }

    if running {
        let elapsed = (Timestamp::now().as_second() - record.started_at.as_second()).max(0);
        let clock_str = format!("{}:{:02}", elapsed / 60, elapsed % 60);
        right_btns = right_btns.child(mono_text(
            clock_str,
            theme.caption_size(),
            theme.text_muted,
            56.0,
            Some(1),
        ));
    }

    if running && !can_send {
        let stop_act = state
            .actions
            .register_named("composerStop", AppAction::StopSession(sid));
        right_btns = right_btns.child(circle_action_button(
            theme,
            "composerStop",
            "Stop",
            IconKind::Stop,
            stop_act,
            false,
            true,
            true,
            hovered.as_deref() == Some("composerStop"),
        ));
    } else {
        let send_act = state.actions.register_named("send", AppAction::SendComposer(sid));
        right_btns = right_btns.child(circle_action_button(
            theme,
            "send",
            "Send",
            IconKind::ArrowUp,
            send_act,
            true,
            false,
            can_send,
            hovered.as_deref() == Some("send"),
        ));
    }

    box_card = box_card.child(
        UiElement::row()
            .width(inner_w)
            .align_center()
            .justify_between()
            .child(left_meta)
            .child(right_btns),
    );

    if has_blocking_q {
        box_card = box_card.child(
            label_1line(
                "Answer the question above to send. Your draft is kept.",
                theme.ui_px(11.0),
                theme.text_muted,
                inner_w,
            )
            .id("composerBlockingNote")
            .a11y(A11ySpec::new(
                A11yRole::StaticText,
                "Answer the question above to send. Your draft is kept.",
            )),
        );
    } else if let Some(err) = &state.composer_error {
        box_card =
            box_card.child(label_1line(err, theme.ui_px(11.0), theme.danger, inner_w).id("attachmentError"));
    }

    outer.child(box_card)
}
