//! User message bubbles (`QuestionReceipt`), inline `TurnFooter`, flanked work rules, and quiet inline disclosures.

use jiff::tz::TimeZone;
use rota_core::model::{ChatMessage, QuestionReceipt, RunOutcome, RunRecord};
use rota_core::schedule::ScheduleText;
use rota_ui::{A11yRole, A11ySpec, Color, Edges, IconKind, TextLayoutOpts, TextSpan, Theme, UiElement};
use uuid::Uuid;

use crate::actions::AppAction;
use crate::app_state::AppState;
use crate::views::widgets::label_1line;

pub fn build_user_bubble(
    state: &mut AppState,
    theme: &Theme,
    session_id: Uuid,
    item_id: usize,
    raw_text: &str,
    width: f32,
    chat_font: rota_ui::FontFamily,
) -> UiElement {
    let msg = ChatMessage::decode(raw_text);
    let receipt = QuestionReceipt::decode(&msg.text);
    let body_text = receipt
        .as_ref()
        .map_or_else(|| msg.text.clone(), QuestionReceipt::summary);

    let bubble_w = (width * 0.78).max(180.0);
    let pad_x = theme.ui_px(14.0);
    let bubble_id = format!("userBubble-{item_id}");
    let copy_id = format!("copyUser-{item_id}");
    let hovered = state
        .hovered_id
        .as_deref()
        .is_some_and(|h| h == bubble_id || h == copy_id || h == format!("selBlock-{item_id}-0"));

    let mut bubble = UiElement::column()
        .id(bubble_id)
        .max_width(bubble_w)
        .padding(Edges::xy(pad_x, theme.ui_px(10.0)))
        .gap(theme.ui_px(6.0))
        .rounded(theme.ui_px(16.0))
        .bg(theme.text_primary.with_alpha(0.06))
        .border(1.0, theme.text_primary.with_alpha(0.06))
        .hit_box()
        .clip()
        .child(
            UiElement::text(
                vec![TextSpan::new(&body_text, theme.chat_body_size(), theme.text_primary).font(chat_font)],
                TextLayoutOpts {
                    max_width: Some((bubble_w - pad_x * 2.0).max(60.0)),
                    line_height_factor: 1.45,
                    ..Default::default()
                },
            )
            .id(format!("selBlock-{item_id}-0"))
            .cursor(rota_ui::CursorKind::IBeam),
        );

    if let Some(rcpt) = receipt
        && !rcpt.questions.is_empty()
    {
        let rcpt_key = item_id.saturating_mul(1000) + 901;
        let open = state
            .transcripts
            .get(&session_id)
            .is_some_and(|t| t.expanded_items.contains(&rcpt_key));
        let children = if open {
            rcpt.questions
                .iter()
                .map(|qf| {
                    label_1line(
                        format!("{}: {}", qf.question, qf.answers.join(", ")),
                        theme.caption_size(),
                        theme.text_secondary,
                        bubble_w - pad_x * 2.0 - 16.0,
                    )
                })
                .collect()
        } else {
            Vec::new()
        };
        bubble = bubble.child(build_disclosure_row(
            state,
            theme,
            session_id,
            "questionReceipt".to_string(),
            rcpt_key,
            None,
            "Answered Question",
            open,
            (bubble_w - pad_x * 2.0).max(80.0),
            children,
        ));
    }

    if !msg.attachments.is_empty() {
        let mut att_row = UiElement::row().gap(theme.ui_px(6.0)).clip();
        for att in msg.attachments {
            let att_id = format!("attachment-{}", att.name);
            let hov = state.is_hovered(&att_id);
            let open_act = state
                .actions
                .register_named(&att_id, AppAction::OpenUrlOrPath(att.path));
            att_row = att_row.child(
                UiElement::row()
                    .id(att_id)
                    .min_height(theme.ui_px(24.0))
                    .align_center()
                    .gap(theme.ui_px(4.0))
                    .padding(Edges::xy(theme.ui_px(8.0), theme.ui_px(3.0)))
                    .rounded(theme.ui_px(6.0))
                    .bg(if hov { theme.subtle_hover } else { theme.elevated })
                    .border(1.0, theme.border)
                    .on_click(open_act)
                    .a11y(A11ySpec::new(A11yRole::Button, &att.name))
                    .child(UiElement::icon(
                        IconKind::Paperclip,
                        theme.ui_px(12.0),
                        theme.accent,
                    ))
                    .child(label_1line(
                        &att.name,
                        theme.caption_size(),
                        theme.text_primary,
                        160.0,
                    )),
            );
        }
        bubble = bubble.child(att_row);
    }

    let copied = state
        .copied_feedback
        .as_ref()
        .is_some_and(|(id, _)| id == &copy_id);
    let copy_act = state.actions.register_named(
        &copy_id,
        AppAction::CopyTextWithId {
            id: copy_id.clone(),
            text: body_text,
        },
    );
    let copy_btn = UiElement::row()
        .id(copy_id)
        .width(theme.ui_px(24.0))
        .height(theme.ui_px(24.0))
        .align_center()
        .justify_center()
        .rounded(theme.ui_px(6.0))
        .on_click(copy_act)
        .tooltip(if copied { "Copied" } else { "Copy message" })
        .a11y(A11ySpec::new(
            A11yRole::Button,
            if copied { "Copied" } else { "Copy Message" },
        ))
        .child(if copied {
            UiElement::icon(IconKind::Check, theme.ui_px(12.5), theme.success)
        } else if hovered {
            UiElement::icon(IconKind::Copy, theme.ui_px(12.5), theme.text_muted)
        } else {
            UiElement::row()
        });

    UiElement::row()
        .width(width)
        .align_center()
        .justify_end()
        .gap(theme.ui_px(6.0))
        .child(copy_btn)
        .child(bubble)
}

/// Authentic Swift `TurnFooter` (`ChatTranscript.swift:434-466`): `10:08 AM · Completed ────────` on a single inline row.
pub fn build_completion_footer(theme: &Theme, record: &RunRecord, width: f32) -> UiElement {
    let tz = TimeZone::system();
    let ended = record.ended_at.unwrap_or(record.started_at);
    let time_s = ScheduleText::format_short_time(ended, &tz);
    let outcome_s = match &record.outcome {
        RunOutcome::Succeeded => "Completed".to_string(),
        RunOutcome::Cancelled => "Stopped".to_string(),
        _ => record.status_title(),
    };
    let text = format!("{time_s} · {outcome_s}");

    UiElement::row()
        .id("transcriptCompletion")
        .width(width)
        .align_center()
        .gap(theme.ui_px(10.0))
        .padding(Edges::new(theme.ui_px(2.0), 0.0, 0.0, 0.0))
        .clip()
        .a11y(A11ySpec::new(A11yRole::StaticText, &text))
        .child(
            label_1line(
                &text,
                theme.caption_size(),
                if record.outcome.is_failure() {
                    theme.danger
                } else {
                    theme.text_muted
                },
                width * 0.65,
            )
            .flex_shrink(0.0),
        )
        .child(
            UiElement::row()
                .flex_grow(1.0)
                .height(1.0)
                .bg(theme.subtle_border),
        )
}

/// Flanked rule disclosure (`──────── Worked: ... > ────────`, `TurnWork.swift:23-54`).
#[allow(clippy::too_many_arguments)]
pub fn build_flanked_rule_row(
    state: &mut AppState,
    theme: &Theme,
    session_id: Uuid,
    el_id: String,
    item_id: usize,
    title: &str,
    expanded: bool,
    width: f32,
    body_children: Vec<UiElement>,
) -> UiElement {
    let act = state.actions.register_named(
        &el_id,
        AppAction::ToggleTranscriptDisclosure { session_id, item_id },
    );
    let hov = state.is_hovered(&el_id);
    let mut dspec = A11ySpec::new(A11yRole::Button, title);
    dspec.selected = expanded;
    dspec.value = Some(if expanded { "Expanded" } else { "Collapsed" }.to_string());

    let btn = UiElement::row()
        .id(el_id)
        .align_center()
        .gap(theme.ui_px(5.0))
        .padding(Edges::xy(theme.ui_px(6.0), theme.ui_px(2.5)))
        .rounded(theme.ui_px(6.0))
        .bg(if hov {
            theme.subtle_hover
        } else {
            Color::TRANSPARENT
        })
        .flex_shrink(0.0)
        .on_click(act)
        .a11y(dspec)
        .child(label_1line(
            title,
            theme.caption_size(),
            theme.text_secondary,
            width * 0.68,
        ))
        .child(UiElement::icon(
            if expanded {
                IconKind::ChevronDown
            } else {
                IconKind::ChevronRight
            },
            theme.ui_px(10.0),
            theme.text_muted,
        ));

    let rule_row = UiElement::row()
        .width(width)
        .align_center()
        .gap(theme.ui_px(10.0))
        .clip()
        .child(
            UiElement::row()
                .flex_grow(1.0)
                .height(1.0)
                .bg(theme.subtle_border),
        )
        .child(btn)
        .child(
            UiElement::row()
                .flex_grow(1.0)
                .height(1.0)
                .bg(theme.subtle_border),
        );

    if !expanded || body_children.is_empty() {
        return rule_row;
    }
    UiElement::column()
        .width(width)
        .gap(theme.ui_px(6.0))
        .clip()
        .child(rule_row)
        .child(
            UiElement::column()
                .width(width)
                .padding(Edges::new(2.0, 0.0, 4.0, theme.ui_px(6.0)))
                .gap(theme.ui_px(6.0))
                .clip()
                .children(body_children),
        )
}

/// Quiet borderless inline `StepDisclosureButton` (`ToolCallsView.swift:56-85`).
#[allow(clippy::too_many_arguments)]
pub fn build_disclosure_row(
    state: &mut AppState,
    theme: &Theme,
    session_id: Uuid,
    el_id: String,
    item_id: usize,
    icon: Option<IconKind>,
    title: &str,
    expanded: bool,
    width: f32,
    body_children: Vec<UiElement>,
) -> UiElement {
    let act = state.actions.register_named(
        &el_id,
        AppAction::ToggleTranscriptDisclosure { session_id, item_id },
    );
    let hov = state.hovered_id.as_deref() == Some(el_id.as_str());
    let mut dspec = A11ySpec::new(A11yRole::Button, title);
    dspec.selected = expanded;
    dspec.value = Some(if expanded { "Expanded" } else { "Collapsed" }.to_string());

    let mut header = UiElement::row()
        .id(el_id)
        .width(width)
        .align_center()
        .min_height(theme.ui_px(26.0))
        .gap(theme.ui_px(6.0))
        .padding(Edges::xy(theme.ui_px(6.0), theme.ui_px(3.0)))
        .rounded(theme.ui_px(6.0))
        .bg(if hov {
            theme.subtle_hover
        } else {
            Color::TRANSPARENT
        })
        .clip()
        .on_click(act)
        .a11y(dspec)
        .child(UiElement::icon(
            if expanded {
                IconKind::ChevronDown
            } else {
                IconKind::ChevronRight
            },
            theme.ui_px(10.5),
            theme.text_muted,
        ));
    if let Some(ic) = icon {
        header = header.child(UiElement::icon(ic, theme.ui_px(12.5), theme.text_secondary));
    }
    header = header.child(label_1line(
        title,
        theme.caption_size(),
        theme.text_secondary,
        width - 42.0,
    ));

    if !expanded || body_children.is_empty() {
        return header;
    }
    UiElement::column()
        .width(width)
        .gap(theme.ui_px(6.0))
        .clip()
        .child(header)
        .child(
            UiElement::column()
                .width(width)
                .padding(Edges::new(2.0, 0.0, 4.0, theme.ui_px(16.0)))
                .gap(theme.ui_px(6.0))
                .clip()
                .children(body_children),
        )
}
