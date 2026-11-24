//! Agent Markdown renderer (`MarkdownBlock` cache, authentic attribution header, `•` lists, code blocks, alerts, images, and `markdownTable`).

use rota_core::model::RunRecord;
use rota_core::transcript::{MarkdownAlert, MarkdownBlock, TranscriptItem, parse_inline_spans};
use rota_ui::{
    A11yRole, A11ySpec, Color, Corners, CursorKind, Edges, FontFamily, FontWeight, IconKind, Size,
    TextLayoutOpts, TextSpan, Theme, UiContent, UiElement,
};

use crate::actions::AppAction;
use crate::app_state::AppState;
use crate::settings_store::effort_title;
use crate::views::markdown_links::{build_markdown_table, inline_to_text_spans};
use crate::views::transcript_tools::resolve_session_image;
use crate::views::widgets::{
    hairline_h, harness_color, harness_icon, label_1line, label_semibold_1line, mono_text,
};

pub fn build_agent_markdown(
    state: &mut AppState,
    theme: &Theme,
    record: &RunRecord,
    item: &TranscriptItem,
    width: f32,
    chat_font: FontFamily,
) -> UiElement {
    let blocks = state
        .transcripts
        .get_mut(&record.id)
        .map(|tr| tr.parsed_markdown(item.id, &item.text).to_vec())
        .unwrap_or_else(|| MarkdownBlock::parse(&item.text));

    let model_name = record.reported_model_title.clone().or_else(|| {
        record
            .reported_model
            .as_deref()
            .or(record.model.as_deref())
            .map(|m| state.settings.model_title(m, record.harness, None))
    });
    let effort_name = record
        .reported_effort
        .as_deref()
        .or(record.effort.as_deref())
        .map(effort_title);

    let mut hdr_spans = vec![
        TextSpan::new(record.harness.title(), theme.caption_size(), theme.text_primary)
            .weight(FontWeight::Medium),
    ];
    if let Some(m) = model_name {
        hdr_spans.push(TextSpan::new(
            format!("  {m}"),
            theme.caption_size(),
            theme.text_secondary,
        ));
    }
    if let Some(eff) = effort_name {
        hdr_spans.push(TextSpan::new(
            format!("  {eff}"),
            theme.caption_size(),
            theme.text_muted,
        ));
    }

    let copy_id = format!("copyAgent-{}", item.id);
    let item_prefix = format!("selBlock-{}-", item.id);
    let msg_hovered = state.hovered_id.as_deref().is_some_and(|h| {
        h == copy_id || h == format!("transcriptItem-{}", item.id) || h.starts_with(&item_prefix)
    });
    let copy_hov = state.hovered_id.as_deref() == Some(copy_id.as_str());
    let msg_copied = state
        .copied_feedback
        .as_ref()
        .is_some_and(|(id, _)| id == &copy_id);
    let copy_act = state.actions.register_named(
        &copy_id,
        AppAction::CopyTextWithId {
            id: copy_id.clone(),
            text: item.text.clone(),
        },
    );
    let hdr = UiElement::row()
        .width(width)
        .align_center()
        .justify_between()
        .child(
            UiElement::row()
                .align_center()
                .gap(theme.ui_px(7.0))
                .clip()
                .child(UiElement::icon(
                    harness_icon(record.harness),
                    theme.ui_px(14.5),
                    harness_color(theme, record.harness),
                ))
                .child(UiElement::text(
                    hdr_spans,
                    TextLayoutOpts {
                        max_width: Some(width - 56.0),
                        max_lines: Some(1),
                        ..Default::default()
                    },
                )),
        )
        .child(
            UiElement::row()
                .id(copy_id.clone())
                .width(theme.ui_px(24.0))
                .height(theme.ui_px(24.0))
                .align_center()
                .justify_center()
                .rounded(theme.ui_px(6.0))
                .bg(if copy_hov {
                    theme.subtle_hover
                } else {
                    Color::TRANSPARENT
                })
                .on_click(copy_act)
                .tooltip(if msg_copied { "Copied" } else { "Copy message" })
                .a11y(A11ySpec::new(
                    A11yRole::Button,
                    if msg_copied { "Copied" } else { "Copy Message" },
                ))
                .child(if msg_copied {
                    UiElement::icon(IconKind::Check, theme.ui_px(13.0), theme.success)
                } else if msg_hovered {
                    UiElement::icon(IconKind::Copy, theme.ui_px(13.0), theme.text_muted)
                } else {
                    UiElement::row()
                }),
        );

    let mut col = UiElement::column()
        .width(width)
        .gap(theme.ui_px(9.0))
        .clip()
        .child(hdr);

    for (b_idx, block) in blocks.iter().enumerate() {
        let sel_id = format!("selBlock-{}-{b_idx}", item.id);
        let el = match block {
            MarkdownBlock::Heading { level, text } => {
                let sz = match level {
                    1 => theme.chat_px(19.0),
                    2 => theme.chat_px(16.5),
                    3 => theme.chat_px(14.5),
                    _ => theme.chat_body_size(),
                };
                UiElement::text(
                    inline_to_text_spans(
                        &parse_inline_spans(text),
                        sz,
                        theme,
                        FontWeight::Semibold,
                        chat_font,
                    ),
                    TextLayoutOpts {
                        max_width: Some(width),
                        line_height_factor: 1.38,
                        ..Default::default()
                    },
                )
                .id(sel_id)
                .cursor(CursorKind::IBeam)
                .a11y(A11ySpec::new(A11yRole::Heading, text))
            }
            MarkdownBlock::Paragraph(text) => render_paragraph_with_images(
                state, theme, record, item.id, b_idx, &sel_id, text, width, chat_font,
            ),
            MarkdownBlock::ListItem { marker, text, indent } => {
                let ind = ((*indent).min(4) as f32) * theme.ui_px(16.0);
                let body_w = (width - ind - theme.ui_px(20.0)).max(60.0);
                let pretty_marker = if marker == "-" || marker == "*" || marker == "+" {
                    "•"
                } else {
                    marker.as_str()
                };
                UiElement::row()
                    .width(width)
                    .padding(Edges::new(0.0, 0.0, 0.0, ind))
                    .gap(theme.ui_px(6.0))
                    .clip()
                    .child(
                        UiElement::text(
                            vec![
                                TextSpan::new(pretty_marker, theme.chat_body_size(), theme.text_secondary)
                                    .weight(FontWeight::Semibold),
                            ],
                            TextLayoutOpts {
                                max_width: Some(theme.ui_px(16.0)),
                                max_lines: Some(1),
                                line_height_factor: 1.50,
                                ..Default::default()
                            },
                        )
                        .width(theme.ui_px(14.0))
                        .flex_shrink(0.0),
                    )
                    .child(
                        UiElement::text(
                            inline_to_text_spans(
                                &parse_inline_spans(text),
                                theme.chat_body_size(),
                                theme,
                                FontWeight::Regular,
                                chat_font,
                            ),
                            TextLayoutOpts {
                                max_width: Some(body_w),
                                line_height_factor: 1.50,
                                ..Default::default()
                            },
                        )
                        .id(sel_id)
                        .cursor(CursorKind::IBeam),
                    )
            }
            MarkdownBlock::Code { text, language } => {
                let lang = language.as_deref().filter(|l| !l.is_empty()).unwrap_or("code");
                let cp_id = format!("copyCode-{}-{b_idx}", item.id);
                let cp_hov = state.is_hovered(&cp_id);
                let cp_done = state.copied_feedback.as_ref().is_some_and(|(id, _)| id == &cp_id);
                let cp_code = state.actions.register_named(
                    &cp_id,
                    AppAction::CopyTextWithId {
                        id: cp_id.clone(),
                        text: text.clone(),
                    },
                );
                let (cp_ic, cp_lbl, cp_col) = if cp_done {
                    (IconKind::Check, "Copied", theme.success)
                } else {
                    (IconKind::Copy, "Copy", theme.text_secondary)
                };
                UiElement::column()
                    .width(width)
                    .rounded(theme.ui_px(10.0))
                    .bg(theme.code_bg)
                    .border(1.0, theme.border)
                    .clip()
                    .child(
                        UiElement::row()
                            .width(width)
                            .align_center()
                            .justify_between()
                            .padding(Edges::xy(theme.ui_px(12.0), theme.ui_px(4.5)))
                            .child(mono_text(
                                lang,
                                theme.caption_size(),
                                theme.text_muted,
                                width - 88.0,
                                Some(1),
                            ))
                            .child(
                                UiElement::row()
                                    .id(cp_id)
                                    .min_height(theme.ui_px(24.0))
                                    .align_center()
                                    .gap(4.0)
                                    .padding(Edges::xy(theme.ui_px(7.0), theme.ui_px(3.0)))
                                    .rounded(theme.ui_px(6.0))
                                    .bg(if cp_hov {
                                        theme.subtle_hover
                                    } else {
                                        Color::TRANSPARENT
                                    })
                                    .on_click(cp_code)
                                    .a11y(A11ySpec::new(
                                        A11yRole::Button,
                                        if cp_done { "Copied" } else { "Copy Code" },
                                    ))
                                    .child(UiElement::icon(cp_ic, theme.ui_px(12.0), cp_col))
                                    .child(label_1line(cp_lbl, theme.caption_size(), cp_col, 52.0)),
                            ),
                    )
                    .child(hairline_h(theme))
                    .child(
                        UiElement::column()
                            .width(width)
                            .padding(Edges::xy(theme.ui_px(12.0), theme.ui_px(10.0)))
                            .child(
                                mono_text(
                                    text,
                                    theme.chat_code_size(),
                                    theme.text_primary,
                                    width - 24.0,
                                    None,
                                )
                                .id(sel_id)
                                .cursor(CursorKind::IBeam),
                            ),
                    )
            }
            MarkdownBlock::Blockquote(raw) => {
                let (alert, clean) = MarkdownAlert::extract(raw);
                let bar_col = match alert {
                    Some(MarkdownAlert::Warning) => theme.warning,
                    Some(MarkdownAlert::Caution) => theme.danger,
                    Some(MarkdownAlert::Tip) => theme.success,
                    Some(MarkdownAlert::Note | MarkdownAlert::Important) => theme.selection_fill,
                    None => theme.border,
                };
                let mut q_col = UiElement::column().width(width - 18.0).gap(4.0).clip();
                if let Some(a) = alert {
                    q_col = q_col.child(label_semibold_1line(
                        a.title(),
                        theme.caption_size(),
                        bar_col,
                        width - 24.0,
                    ));
                }
                q_col = q_col.child(
                    UiElement::text(
                        inline_to_text_spans(
                            &parse_inline_spans(&clean),
                            theme.chat_body_size(),
                            theme,
                            FontWeight::Regular,
                            chat_font,
                        ),
                        TextLayoutOpts {
                            max_width: Some(width - 24.0),
                            line_height_factor: 1.48,
                            ..Default::default()
                        },
                    )
                    .id(sel_id)
                    .cursor(CursorKind::IBeam),
                );
                UiElement::row()
                    .width(width)
                    .gap(theme.ui_px(10.0))
                    .padding(Edges::xy(theme.ui_px(4.0), theme.ui_px(4.0)))
                    .clip()
                    .child(UiElement::column().width(3.0).bg(bar_col).rounded(1.5))
                    .child(q_col)
            }
            MarkdownBlock::Table(table) => build_markdown_table(theme, table, width, chat_font),
            MarkdownBlock::ThematicBreak => hairline_h(theme),
        };
        col = col.child(el);
    }
    col
}

#[allow(clippy::too_many_arguments)]
fn render_paragraph_with_images(
    state: &mut AppState,
    theme: &Theme,
    record: &RunRecord,
    item_id: usize,
    block_idx: usize,
    sel_id: &str,
    text: &str,
    width: f32,
    chat_font: FontFamily,
) -> UiElement {
    let spans = parse_inline_spans(text);
    let mut col = UiElement::column().width(width).gap(theme.ui_px(6.0)).clip();
    let rich = inline_to_text_spans(
        &spans,
        theme.chat_body_size(),
        theme,
        FontWeight::Regular,
        chat_font,
    );
    if !rich.is_empty() {
        col = col.child(
            UiElement::text(
                rich,
                TextLayoutOpts {
                    max_width: Some(width),
                    line_height_factor: 1.50,
                    ..Default::default()
                },
            )
            .id(sel_id.to_string())
            .cursor(CursorKind::IBeam),
        );
    }
    if let Some(links_row) =
        crate::views::markdown_links::build_link_chips(state, theme, item_id, block_idx, &spans, width)
    {
        col = col.child(links_row);
    }
    for sp in spans {
        if let Some(img_ref) = sp.image
            && let Some(path) = resolve_session_image(record, &img_ref.url, Some(item_id))
        {
            let disp = Size::new(width.min(360.0), 200.0);
            let img_el = UiElement {
                content: UiContent::Image {
                    path,
                    display_size: disp,
                    corners: Corners::all(10.0),
                    opacity: 1.0,
                },
                ..Default::default()
            };
            col = col.child(
                img_el
                    .id("markdownImage")
                    .width(disp.width)
                    .height(disp.height)
                    .a11y(A11ySpec::new(A11yRole::Image, img_ref.alt)),
            );
        }
    }
    col
}
