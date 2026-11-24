//! Plan cards, structured tool/diff/image output blocks, tool groups, and multi-block `TranscriptSelection` highlights.

use std::path::PathBuf;

use rota_core::model::RunRecord;
use rota_core::storage::SessionImageStore;
use rota_core::transcript::{
    PlanStep, PlanStepStatus, ToolOutput, ToolOutputKind, ToolStep, TranscriptItem, TranscriptItemKind,
};
use rota_ui::{
    A11yRole, A11ySpec, Color, ComputedUiTree, Corners, Edges, IconKind, QuadSpec, Scene, SelectableBlock,
    Size, TextLayoutOpts, TextSpan, TextSystem, Theme, UiContent, UiElement,
};
use uuid::Uuid;

use crate::app_state::AppState;
pub use crate::views::transcript_bubbles::{
    build_completion_footer, build_disclosure_row, build_flanked_rule_row, build_user_bubble,
};
use crate::views::widgets::{label_1line, label_semibold_1line, mono_text};

pub(crate) fn resolve_session_image(
    record: &RunRecord,
    url: &str,
    item_id: Option<usize>,
) -> Option<PathBuf> {
    if let Some(log) = &record.log_path {
        let store = SessionImageStore::new(std::path::Path::new(log), None);
        if let Some(arch) = store.archived(url, item_id) {
            return Some(arch);
        }
    }
    let clean = url.strip_prefix("file://").unwrap_or(url);
    let p = PathBuf::from(clean);
    p.is_file().then_some(p)
}

pub fn build_plan_card(theme: &Theme, text: &str, width: f32) -> UiElement {
    let steps = PlanStep::parse(text);
    let mut card = UiElement::column()
        .width(width)
        .padding(Edges::all(theme.ui_px(12.0)))
        .gap(theme.ui_px(6.0))
        .rounded(theme.ui_px(10.0))
        .bg(theme.text_primary.with_alpha(0.03))
        .border(1.0, theme.border)
        .clip()
        .child(label_semibold_1line(
            "Plan",
            theme.caption_size(),
            theme.accent,
            width - 24.0,
        ));
    for step in steps {
        let (ic, col) = match step.status {
            PlanStepStatus::Completed => (IconKind::CheckCircle, theme.success),
            PlanStepStatus::InProgress => (IconKind::Play, theme.accent),
            PlanStepStatus::Pending => (IconKind::Clock, theme.text_muted),
        };
        card = card.child(
            UiElement::row()
                .width(width - 24.0)
                .align_center()
                .gap(theme.ui_px(6.0))
                .clip()
                .child(UiElement::icon(ic, theme.ui_px(12.5), col))
                .child(label_1line(
                    &step.text,
                    theme.caption_size(),
                    theme.text_primary,
                    width - 48.0,
                )),
        );
    }
    card
}

pub fn build_tools_group(
    state: &mut AppState,
    theme: &Theme,
    record: &RunRecord,
    calls: &[TranscriptItem],
    width: f32,
) -> UiElement {
    let first_id = calls.first().map_or(0, |c| c.id);
    let is_open = state
        .transcripts
        .get(&record.id)
        .is_some_and(|t| t.expanded_items.contains(&first_id));
    let titles: Vec<String> = calls
        .iter()
        .filter(|i| i.kind == TranscriptItemKind::Tool)
        .map(|i| ToolStep::call_title(&i.text))
        .collect();
    let label = if titles.len() == 1 {
        titles[0].clone()
    } else if !titles.is_empty() {
        ToolStep::summary(&titles)
    } else {
        "Tool output".to_string()
    };
    let children = if is_open {
        calls
            .iter()
            .map(|c| {
                build_tool_or_output_item(state, theme, record, c, width - 20.0)
                    .id(format!("toolCall-{}", c.id))
            })
            .collect()
    } else {
        Vec::new()
    };
    build_disclosure_row(
        state,
        theme,
        record.id,
        format!("toolCalls-{first_id}"),
        first_id,
        Some(IconKind::Wrench),
        &label,
        is_open,
        width,
        children,
    )
}

pub fn build_tool_or_output_item(
    state: &mut AppState,
    theme: &Theme,
    record: &RunRecord,
    item: &TranscriptItem,
    width: f32,
) -> UiElement {
    if let Some(decoded) = ToolOutput::decode(&item.text) {
        let mut col = UiElement::column().width(width).gap(theme.ui_px(6.0)).clip();
        for (p_idx, part) in decoded.parts.into_iter().enumerate() {
            match part.kind {
                ToolOutputKind::Text => {
                    col = col.child(
                        UiElement::column()
                            .width(width)
                            .padding(Edges::all(theme.ui_px(10.0)))
                            .rounded(theme.ui_px(8.0))
                            .bg(theme.code_bg)
                            .border(1.0, theme.subtle_border)
                            .clip()
                            .child(
                                mono_text(
                                    &part.text,
                                    theme.chat_code_size(),
                                    theme.text_secondary,
                                    width - 20.0,
                                    Some(16),
                                )
                                .a11y(A11ySpec::new(A11yRole::StaticText, &part.text)),
                            ),
                    );
                }
                ToolOutputKind::Diff => {
                    let diff_key = item.id.saturating_mul(1000) + 500 + p_idx;
                    let diff_open = state
                        .transcripts
                        .get(&record.id)
                        .is_some_and(|t| t.expanded_items.contains(&diff_key));
                    let diff_id = format!("toolDiff-{}-{p_idx}", item.id);
                    let path_lbl = part.path.as_deref().unwrap_or("File changes");
                    let body = if diff_open {
                        let mut dcol = UiElement::column()
                            .id(format!("{diff_id}-body"))
                            .width(width)
                            .padding(Edges::all(8.0))
                            .rounded(6.0)
                            .bg(theme.code_bg)
                            .border(1.0, theme.subtle_border)
                            .clip()
                            .a11y(A11ySpec::new(A11yRole::Group, path_lbl));
                        for line in part.text.lines().take(32) {
                            let fg = if line.starts_with('+') {
                                theme.success
                            } else if line.starts_with('-') {
                                theme.danger
                            } else {
                                theme.text_secondary
                            };
                            dcol = dcol.child(mono_text(
                                line,
                                theme.chat_code_size(),
                                fg,
                                width - 16.0,
                                Some(1),
                            ));
                        }
                        vec![dcol]
                    } else {
                        Vec::new()
                    };
                    col = col.child(build_disclosure_row(
                        state, theme, record.id, diff_id, diff_key, None, path_lbl, diff_open, width, body,
                    ));
                }
                ToolOutputKind::Image => {
                    if let Some(path) = resolve_session_image(record, &part.text, Some(item.id)) {
                        let disp = Size::new(width.min(320.0), 180.0);
                        let img_el = UiElement {
                            content: UiContent::Image {
                                path,
                                display_size: disp,
                                corners: Corners::all(8.0),
                                opacity: 1.0,
                            },
                            ..Default::default()
                        };
                        col = col.child(
                            img_el
                                .id("markdownImage")
                                .width(disp.width)
                                .height(disp.height)
                                .a11y(A11ySpec::new(
                                    A11yRole::Image,
                                    part.path.unwrap_or_else(|| "Tool image".to_string()),
                                )),
                        );
                    }
                }
            }
        }
        return col;
    }
    UiElement::column()
        .width(width)
        .padding(Edges::all(theme.ui_px(10.0)))
        .rounded(theme.ui_px(8.0))
        .bg(theme.code_bg)
        .border(1.0, theme.subtle_border)
        .clip()
        .child(
            mono_text(
                &item.text,
                theme.chat_code_size(),
                theme.text_secondary,
                width - 20.0,
                Some(20),
            )
            .a11y(A11ySpec::new(A11yRole::StaticText, &item.text)),
        )
}

pub fn populate_selectable_blocks(
    state: &mut AppState,
    session_id: Uuid,
    tree: &ComputedUiTree,
    text_sys: &mut TextSystem,
    scale_factor: f32,
) {
    let Some(tr) = state.transcripts.get_mut(&session_id) else {
        return;
    };
    tr.selectable_blocks.clear();
    for item in &tr.snapshot.items {
        let key = format!("selBlock-{}-0", item.id);
        if let Some(bounds) = tree.bounds_by_id(&key) {
            let para = text_sys.shape_paragraph(
                &[TextSpan::new(&item.text, 14.0, Color::BLACK)],
                TextLayoutOpts {
                    max_width: Some(bounds.width.max(1.0)),
                    ..Default::default()
                },
                scale_factor,
            );
            tr.selectable_blocks.push(SelectableBlock {
                block_id: item.id as u64,
                bounds,
                paragraph: para,
                plain_text: item.text.clone(),
            });
        }
    }
}

pub fn paint_selection_highlights(state: &AppState, session_id: Uuid, theme: &Theme, scene: &mut Scene) {
    let Some(tr) = state.transcripts.get(&session_id) else {
        return;
    };
    if !tr.selection.is_active() {
        return;
    }
    for (idx, b) in tr.selectable_blocks.iter().enumerate() {
        for r in tr.selection.highlight_rects_for_block(idx, b) {
            scene.push_quad(QuadSpec::solid(r, theme.accent.with_alpha(0.24)).rounded(2.0));
        }
    }
}

pub fn clamp_a11y_tree_to_parents(nodes: &mut [rota_ui::A11yNode], parent_clip: rota_ui::Rect) {
    for node in nodes {
        if node.role == A11yRole::Menu {
            continue;
        }
        let next_parent = if node.role == A11yRole::ScrollArea {
            rota_ui::Rect::INFINITE_CLIP
        } else {
            node.bounds_in_window = node.bounds_in_window.intersect(parent_clip);
            node.bounds_in_window
        };
        clamp_a11y_tree_to_parents(&mut node.children, next_parent);
    }
}
