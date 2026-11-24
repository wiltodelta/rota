//! Virtualized 120 Hz `ChatTranscript` (`id: "chatTranscript"`): sticky follow, inline `TurnFooter`, flanked work rules, user bubbles, and circular `scrollToLatest`.

use rota_core::model::{RunOutcome, RunRecord};
use rota_core::transcript::{ChatRow, ToolStep, TranscriptItem, TranscriptItemKind, WorkRow};
use rota_ui::{
    A11yRole, A11ySpec, Edges, FontFamily, IconKind, Point, Rect, TextLayoutOpts, TextSpan, Theme, UiElement,
};

use crate::actions::AppAction;
use crate::app_state::AppState;
use crate::views::markdown_view::build_agent_markdown;
use crate::views::question_card;
use crate::views::transcript_tools::{
    build_completion_footer, build_disclosure_row, build_flanked_rule_row, build_plan_card,
    build_tool_or_output_item, build_tools_group, build_user_bubble,
};
use crate::views::widgets::{button, label_1line};

pub fn build_transcript(
    state: &mut AppState,
    theme: &Theme,
    record: &RunRecord,
    width: f32,
    height: f32,
    _now_seconds: f64,
) -> UiElement {
    let sid = record.id;
    state.transcripts.entry(sid).or_default();

    let pad_x = ((width - 720.0) * 0.5).max(theme.ui_px(24.0));
    let col_w = (width - pad_x * 2.0).clamp(180.0, 720.0);
    let chat_font = state.settings.chat_font_family();

    let (has_earlier, items, expanded, outbox) = {
        let tr = state.transcripts.get(&sid).expect("transcript initialized");
        let pending_out: Vec<String> = tr
            .outbox
            .iter()
            .filter(|o| !o.delivered(&tr.snapshot.items))
            .map(|o| o.text.clone())
            .collect();
        (
            tr.snapshot.has_earlier,
            tr.snapshot.items.clone(),
            tr.expanded_items.clone(),
            pending_out,
        )
    };

    let mut merged_items: Vec<TranscriptItem> = Vec::with_capacity(items.len());
    for item in items {
        if item.kind == TranscriptItemKind::Agent
            && let Some(prev) = merged_items.last_mut()
            && prev.kind == TranscriptItemKind::Agent
            && record.configuration_at(prev.id) == record.configuration_at(item.id)
        {
            prev.text.push_str("\n\n");
            prev.text.push_str(&item.text);
        } else {
            merged_items.push(item);
        }
    }

    let rows = ChatRow::group(&merged_items);
    let full_mode = rows.len() <= 80;
    let vis_range = if full_mode {
        {
            let tr = state.transcripts.get_mut(&sid).expect("transcript");
            if tr.scroll.item_count() == 0 {
                let est: f32 = rows
                    .iter()
                    .map(|r| estimate_row_height(r, &expanded, theme, col_w))
                    .sum::<f32>()
                    + 120.0;
                tr.scroll.set_heights(&[est], height);
            }
        }
        rota_ui::VirtualVisibleRange {
            indices: 0..rows.len(),
            top_spacer: 0.0,
            bottom_spacer: 0.0,
            first_item_top_y: 0.0,
        }
    } else {
        let row_heights: Vec<f32> = rows
            .iter()
            .map(|r| estimate_row_height(r, &expanded, theme, col_w))
            .collect();
        let mut all_heights = row_heights;
        if record.outcome != RunOutcome::Running && !merged_items.is_empty() {
            all_heights.push(theme.ui_px(28.0));
        }
        if let Some(q) = record.next_question() {
            let opt_count = q.fields.first().map_or(0, |f| f.options.len()) as f32;
            all_heights.push(theme.ui_px(290.0 + opt_count * 42.0));
        }
        all_heights.push(theme.ui_px(40.0));
        let tr = state.transcripts.get_mut(&sid).expect("transcript");
        if tr.scroll.item_count() != all_heights.len() {
            tr.scroll.set_heights(&all_heights, height);
        }
        let mut vr = tr.scroll.visible_range(height, 560.0);
        vr.indices.end = vr.indices.end.min(rows.len());
        vr.indices.start = vr.indices.start.min(vr.indices.end);
        vr
    };
    let total_est_h = state
        .transcripts
        .get(&sid)
        .map_or(height, |t| t.scroll.total_height());
    let sticky = state
        .transcripts
        .get(&sid)
        .is_none_or(|t| t.scroll.stick_to_bottom);

    let mut content = UiElement::column()
        .id(if full_mode {
            "transcriptContentFull"
        } else {
            "transcriptContentVirtual"
        })
        .width(width)
        .padding(Edges::new(theme.ui_px(18.0), pad_x, theme.ui_px(22.0), pad_x))
        .gap(theme.ui_px(16.0));

    if has_earlier {
        let load_act = state
            .actions
            .register_named("loadEarlierMessages", AppAction::LoadEarlierMessages(sid));
        let hovered = state.hovered_id.as_deref() == Some("loadEarlierMessages");
        content = content.child(UiElement::row().width(col_w).justify_center().child(button(
            theme,
            "loadEarlierMessages",
            "Load Earlier Messages",
            Some(IconKind::Refresh),
            load_act,
            false,
            false,
            true,
            hovered,
        )));
    }

    if vis_range.top_spacer > 1.0 {
        content = content.child(UiElement::row().width(col_w).height(vis_range.top_spacer));
    }

    for idx in vis_range.indices {
        let row_el = build_chat_row(state, theme, record, &rows[idx], col_w, chat_font);
        content = content.child(
            UiElement::column()
                .id(format!("chatRow-{idx}"))
                .width(col_w)
                .child(row_el),
        );
    }

    if vis_range.bottom_spacer > 1.0 {
        content = content.child(UiElement::row().width(col_w).height(vis_range.bottom_spacer));
    }

    if record.outcome != RunOutcome::Running && !merged_items.is_empty() {
        content = content.child(build_completion_footer(theme, record, col_w));
    }

    for pending_msg in outbox {
        content = content.child(build_user_bubble(
            state,
            theme,
            record.id,
            999_999,
            &pending_msg,
            col_w,
            chat_font,
        ));
    }

    if record.outcome == RunOutcome::Running && merged_items.is_empty() {
        state.activity_clock.mark_active();
        content = content.child(label_1line(
            "Working…",
            theme.chat_body_size(),
            theme.text_muted,
            col_w,
        ));
    }

    if let Some(q) = record.next_question() {
        content = content.child(question_card::build_question_card(
            state, theme, record.id, q, col_w,
        ));
    }

    let eff_scroll_y = state
        .transcripts
        .get(&sid)
        .map_or(0.0, |t| t.scroll.effective_scroll_y());
    let sb_active = state
        .dragging_scrollbar
        .as_ref()
        .is_some_and(|(k, _)| k == "transcript")
        || state.hovered_id.as_deref() == Some("scrollbarThumb-transcript");
    let sb_opt = state
        .transcripts
        .get(&sid)
        .map(|t| t.scroll.clone())
        .and_then(|scroll_snap| {
            crate::views::widgets::interactive_scrollbar_overlay(
                theme,
                "transcript",
                &scroll_snap,
                height,
                total_est_h,
                width,
                sb_active,
                _now_seconds,
                &mut state.activity_clock,
            )
        });

    let mut wrapper = UiElement::column()
        .id("chatTranscript")
        .width(width)
        .height(height)
        .bg(theme.surface)
        .clip()
        .scroll_offset(Point::new(0.0, eff_scroll_y))
        .a11y(A11ySpec::new(A11yRole::ScrollArea, "Chat Transcript"))
        .child(content);

    if let Some(sb_thumb) = sb_opt {
        wrapper = wrapper.child(sb_thumb);
    }

    // Authentic Swift `scrollToLatest` (`ChatTranscript.swift:189`): 30x30 circular glass downward arrow button!
    if !sticky && record.next_question().is_none() {
        let jump_act = state
            .actions
            .register_named("scrollToLatest", AppAction::ScrollToLatest(sid));
        let jump_hov = state.is_hovered("scrollToLatest");
        let sz = theme.ui_px(30.0);
        wrapper = wrapper.child(
            UiElement::row()
                .id("scrollToLatest")
                .absolute(Rect::new(
                    (width - sz) * 0.5,
                    eff_scroll_y + height - sz - theme.ui_px(12.0),
                    sz,
                    sz,
                ))
                .align_center()
                .justify_center()
                .rounded(sz * 0.5)
                .bg(if jump_hov {
                    theme.subtle_hover
                } else {
                    theme.elevated
                })
                .border(1.0, theme.border)
                .shadow(8.0, Point::new(0.0, 2.0), theme.shadow_color)
                .on_click(jump_act)
                .tooltip("Scroll to the latest")
                .z_layer(2, false)
                .a11y(A11ySpec::new(A11yRole::Button, "Scroll to the latest"))
                .child(UiElement::icon(
                    IconKind::ArrowDown,
                    theme.ui_px(13.5),
                    theme.text_primary,
                )),
        );
    }
    wrapper
}

fn estimate_row_height(
    row: &ChatRow,
    expanded: &std::collections::HashSet<usize>,
    theme: &Theme,
    col_w: f32,
) -> f32 {
    match row {
        ChatRow::WorkChain(chain) => {
            let id = chain.first().map_or(0, WorkRow::id);
            theme.ui_px(if expanded.contains(&id) {
                34.0 + (chain.len() as f32) * 30.0
            } else {
                26.0
            })
        }
        ChatRow::Single(WorkRow::Tools(calls)) => {
            let id = calls.first().map_or(0, |c| c.id);
            theme.ui_px(if expanded.contains(&id) {
                34.0 + (calls.len() as f32) * 28.0
            } else {
                26.0
            })
        }
        ChatRow::Single(WorkRow::Note(item)) => {
            let chars_per_line = ((col_w / theme.chat_px(7.4)).floor() as usize).max(28);
            let wrapped_lines: usize = item
                .text
                .split('\n')
                .map(|ln| (ln.chars().count() / chars_per_line) + 1)
                .sum();
            (wrapped_lines.max(1) as f32) * theme.chat_px(21.5) + theme.ui_px(34.0)
        }
    }
}

fn build_chat_row(
    state: &mut AppState,
    theme: &Theme,
    record: &RunRecord,
    row: &ChatRow,
    width: f32,
    chat_font: FontFamily,
) -> UiElement {
    match row {
        ChatRow::WorkChain(chain) => {
            let first_id = chain.first().map_or(0, WorkRow::id);
            let is_open = state
                .transcripts
                .get(&record.id)
                .is_some_and(|t| t.expanded_items.contains(&first_id));
            let tool_lines: Vec<String> = chain
                .iter()
                .flat_map(|w| w.items())
                .filter(|i| i.kind == TranscriptItemKind::Tool)
                .map(|i| ToolStep::call_title(&i.text))
                .collect();
            let summary = if tool_lines.is_empty() {
                format!("{} reasoning steps", chain.len())
            } else {
                format!("Worked: {}", ToolStep::summary(&tool_lines))
            };
            let children = if is_open {
                chain
                    .iter()
                    .map(|w| match w {
                        WorkRow::Note(item) => {
                            build_single_item(state, theme, record, item, width - 16.0, chat_font)
                        }
                        WorkRow::Tools(calls) => build_tools_group(state, theme, record, calls, width - 16.0),
                    })
                    .collect()
            } else {
                Vec::new()
            };
            build_flanked_rule_row(
                state,
                theme,
                record.id,
                "workToggle".to_string(),
                first_id,
                &summary,
                is_open,
                width,
                children,
            )
        }
        ChatRow::Single(WorkRow::Tools(calls)) => build_tools_group(state, theme, record, calls, width),
        ChatRow::Single(WorkRow::Note(item)) => {
            build_single_item(state, theme, record, item, width, chat_font)
        }
    }
}

fn build_single_item(
    state: &mut AppState,
    theme: &Theme,
    record: &RunRecord,
    item: &TranscriptItem,
    width: f32,
    chat_font: FontFamily,
) -> UiElement {
    let inner = match item.kind {
        TranscriptItemKind::User => {
            build_user_bubble(state, theme, record.id, item.id, &item.text, width, chat_font)
        }
        TranscriptItemKind::Reasoning => {
            let is_open = state
                .transcripts
                .get(&record.id)
                .is_some_and(|t| t.expanded_items.contains(&item.id));
            let body = if is_open {
                vec![
                    UiElement::text(
                        vec![TextSpan::new(&item.text, theme.chat_px(12.5), theme.text_secondary).italic()],
                        TextLayoutOpts {
                            max_width: Some(width - 28.0),
                            line_height_factor: 1.45,
                            ..Default::default()
                        },
                    )
                    .id("reasoningBody")
                    .a11y(A11ySpec::new(A11yRole::StaticText, &item.text)),
                ]
            } else {
                Vec::new()
            };
            build_disclosure_row(
                state,
                theme,
                record.id,
                "reasoningDetails".to_string(),
                item.id,
                None,
                "Reasoning",
                is_open,
                width,
                body,
            )
        }
        TranscriptItemKind::Plan => build_plan_card(theme, &item.text, width),
        TranscriptItemKind::Output | TranscriptItemKind::Tool => {
            build_tool_or_output_item(state, theme, record, item, width).id(format!("toolCall-{}", item.id))
        }
        TranscriptItemKind::Error => UiElement::row()
            .width(width)
            .align_center()
            .gap(theme.ui_px(8.0))
            .padding(Edges::xy(theme.ui_px(12.0), theme.ui_px(9.0)))
            .rounded(theme.ui_px(10.0))
            .bg(theme.danger.with_alpha(0.09))
            .border(1.0, theme.danger.with_alpha(0.32))
            .clip()
            .child(UiElement::icon(
                IconKind::Warning,
                theme.ui_px(15.0),
                theme.danger,
            ))
            .child(
                UiElement::text(
                    vec![TextSpan::new(
                        &item.text,
                        theme.chat_body_size(),
                        theme.text_primary,
                    )],
                    TextLayoutOpts {
                        max_width: Some(width - 44.0),
                        line_height_factor: 1.42,
                        ..Default::default()
                    },
                )
                .a11y(A11ySpec::new(A11yRole::StaticText, &item.text)),
            ),
        TranscriptItemKind::Status => UiElement::row()
            .width(width)
            .align_center()
            .gap(theme.ui_px(10.0))
            .padding(Edges::xy(0.0, theme.ui_px(2.0)))
            .clip()
            .child(
                UiElement::row()
                    .flex_grow(1.0)
                    .height(1.0)
                    .bg(theme.subtle_border),
            )
            .child(
                label_1line(&item.text, theme.caption_size(), theme.text_muted, width * 0.72)
                    .flex_shrink(0.0)
                    .a11y(A11ySpec::new(A11yRole::StaticText, &item.text)),
            )
            .child(
                UiElement::row()
                    .flex_grow(1.0)
                    .height(1.0)
                    .bg(theme.subtle_border),
            ),
        TranscriptItemKind::Agent => build_agent_markdown(state, theme, record, item, width, chat_font),
    };

    UiElement::column()
        .id(format!("transcriptItem-{}", item.id))
        .width(width)
        .hit_box()
        .clip()
        .a11y(A11ySpec::new(A11yRole::Group, item.kind.as_str()))
        .child(inner)
}
