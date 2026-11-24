//! Clickable URL & Markdown link pills (`[label](url)` and bare `https://...` / `http://...`) for `ChatTranscript`.

use rota_core::transcript::{ColumnAlignment, InlineSpan, MarkdownTable, parse_inline_spans};
use rota_ui::{
    A11yRole, A11ySpec, CursorKind, Edges, FontFamily, FontStyle, FontWeight, IconKind, TextAlign,
    TextLayoutOpts, TextSpan, Theme, UiElement,
};

use crate::actions::AppAction;
use crate::app_state::AppState;
use crate::views::widgets::label_1line;

/// Extracts unique `(display_label, target_url)` links from parsed `InlineSpan`s and bare `http(s)://` tokens.
pub fn collect_links(spans: &[InlineSpan]) -> Vec<(String, String)> {
    let mut out: Vec<(String, String)> = Vec::new();
    for sp in spans {
        if sp.code || sp.image.is_some() {
            continue;
        }
        if let Some(ref url) = sp.link {
            let clean = url.trim();
            if !clean.is_empty() && !out.iter().any(|(_, u)| u == clean) {
                let lbl = if sp.text.trim().is_empty() {
                    clean.to_string()
                } else {
                    sp.text.trim().to_string()
                };
                out.push((lbl, clean.to_string()));
            }
            continue;
        }
        for tok in sp.text.split_whitespace() {
            let trimmed = tok.trim_matches(|c: char| {
                matches!(
                    c,
                    '(' | ')' | '[' | ']' | '<' | '>' | ',' | '.' | ';' | ':' | '"' | '\''
                )
            });
            if (trimmed.starts_with("https://") || trimmed.starts_with("http://"))
                && trimmed.len() > 10
                && !out.iter().any(|(_, u)| u == trimmed)
            {
                out.push((trimmed.to_string(), trimmed.to_string()));
            }
        }
    }
    out
}

/// Builds a compact row of clickable link chips (`CursorKind::PointingHand` + URL tooltip) below a Markdown block.
pub fn build_link_chips(
    state: &mut AppState,
    theme: &Theme,
    item_id: usize,
    block_idx: usize,
    spans: &[InlineSpan],
    max_w: f32,
) -> Option<UiElement> {
    let links = collect_links(spans);
    if links.is_empty() {
        return None;
    }
    let mut row = UiElement::row()
        .width(max_w)
        .align_center()
        .gap(theme.ui_px(6.0))
        .clip();
    for (idx, (lbl, url)) in links.into_iter().take(3).enumerate() {
        let chip_id = format!("markdownLink-{item_id}-{block_idx}-{idx}");
        let hovered = state.is_hovered(&chip_id);
        let act = state
            .actions
            .register_named(&chip_id, AppAction::OpenUrlOrPath(url.clone()));
        row = row.child(
            UiElement::row()
                .id(chip_id)
                .height(theme.ui_px(24.0))
                .min_height(theme.ui_px(24.0))
                .align_center()
                .gap(theme.ui_px(4.5))
                .padding(Edges::xy(theme.ui_px(8.0), theme.ui_px(3.0)))
                .rounded(theme.ui_px(12.0))
                .bg(if hovered {
                    theme.selection_fill.with_alpha(0.16)
                } else {
                    theme.selection_fill.with_alpha(0.09)
                })
                .border(1.0, theme.selection_fill.with_alpha(0.28))
                .cursor(CursorKind::PointingHand)
                .tooltip(&url)
                .on_click(act)
                .a11y(A11ySpec::new(A11yRole::Button, format!("Open {lbl}")))
                .child(UiElement::icon(
                    IconKind::ExternalLink,
                    theme.ui_px(11.0),
                    theme.accent,
                ))
                .child(label_1line(lbl, theme.caption_size(), theme.accent, 220.0)),
        );
    }
    Some(row)
}

pub fn build_markdown_table(
    theme: &Theme,
    table: &MarkdownTable,
    width: f32,
    chat_font: FontFamily,
) -> UiElement {
    let ncols = table.headers.len().max(1);
    let cell_w = ((width - 2.0) / (ncols as f32)).floor().max(48.0);
    let align_for = |i: usize| match table.alignments.get(i).copied().unwrap_or(ColumnAlignment::Left) {
        ColumnAlignment::Left => TextAlign::Left,
        ColumnAlignment::Center => TextAlign::Center,
        ColumnAlignment::Right => TextAlign::Right,
    };

    let mk_cell = |ci: usize, txt: &str, wt: FontWeight, py: f32| {
        UiElement::column()
            .width(cell_w)
            .padding(Edges::xy(theme.ui_px(10.0), theme.ui_px(py)))
            .border(0.5, theme.subtle_border)
            .clip()
            .child(
                UiElement::text(
                    inline_to_text_spans(
                        &parse_inline_spans(txt),
                        theme.caption_size(),
                        theme,
                        wt,
                        chat_font,
                    ),
                    TextLayoutOpts {
                        max_width: Some((cell_w - 20.0).max(16.0)),
                        align: align_for(ci),
                        ..Default::default()
                    },
                )
                .a11y(A11ySpec::new(A11yRole::StaticText, txt)),
            )
    };

    let mut hdr_row = UiElement::row().width(width).bg(theme.canvas).clip();
    for (ci, h) in table.headers.iter().enumerate() {
        hdr_row = hdr_row.child(mk_cell(ci, h, FontWeight::Semibold, 7.0));
    }

    let mut tbl = UiElement::column()
        .id("markdownTable")
        .width(width)
        .rounded(theme.ui_px(10.0))
        .border(1.0, theme.border)
        .clip()
        .a11y(A11ySpec::new(A11yRole::Table, "Table"))
        .child(hdr_row);

    for (ri, r) in table.rows.iter().enumerate() {
        let row_bg = if ri % 2 == 1 {
            theme.canvas.with_alpha(0.45)
        } else {
            theme.surface
        };
        let mut r_el = UiElement::row().width(width).bg(row_bg).clip();
        for (ci, cell) in r.iter().enumerate().take(ncols) {
            r_el = r_el.child(mk_cell(ci, cell, FontWeight::Regular, 6.0));
        }
        tbl = tbl.child(r_el);
    }
    tbl
}

pub fn inline_to_text_spans(
    spans: &[InlineSpan],
    size: f32,
    theme: &Theme,
    base_weight: FontWeight,
    base_font: FontFamily,
) -> Vec<TextSpan> {
    spans
        .iter()
        .filter(|s| s.image.is_none() && !s.text.is_empty())
        .map(|s| {
            let fg = if s.link.is_some() {
                theme.accent
            } else {
                theme.text_primary
            };
            let mut ts = TextSpan::new(&s.text, if s.code { size * 0.92 } else { size }, fg)
                .font(if s.code { FontFamily::Mono } else { base_font })
                .weight(if s.bold { FontWeight::Semibold } else { base_weight });
            if s.italic {
                ts.style = FontStyle::Italic;
            }
            if s.link.is_some() {
                ts.underline = true;
            }
            if s.strikethrough {
                ts.strikethrough = true;
            }
            if s.code {
                ts.background = Some(theme.code_bg);
            }
            ts
        })
        .collect()
}
