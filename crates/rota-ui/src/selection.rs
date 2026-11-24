//! Cross-block text selection across selectable transcript blocks with highlight rects & copy.

use crate::geometry::{Point, Rect};
use crate::text::ShapedParagraph;
use crate::text_input::{clamp_char_boundary, line_end, line_start, next_word_boundary, prev_word_boundary};

#[derive(Debug, Clone)]
pub struct SelectableBlock {
    pub block_id: u64,
    pub bounds: Rect,
    pub paragraph: ShapedParagraph,
    pub plain_text: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct SelectionEndpoint {
    pub block_index: usize,
    pub byte_offset: usize,
}

#[derive(Debug, Clone, Default)]
pub struct TranscriptSelection {
    anchor: Option<SelectionEndpoint>,
    focus: Option<SelectionEndpoint>,
    pub is_dragging: bool,
}

impl TranscriptSelection {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn clear(&mut self) {
        self.anchor = None;
        self.focus = None;
        self.is_dragging = false;
    }

    pub fn is_active(&self) -> bool {
        match (self.anchor, self.focus) {
            (Some(a), Some(b)) => a != b,
            _ => false,
        }
    }

    pub fn ordered_range(&self) -> Option<(SelectionEndpoint, SelectionEndpoint)> {
        let a = self.anchor?;
        let b = self.focus?;
        if a <= b { Some((a, b)) } else { Some((b, a)) }
    }

    pub fn begin_drag(&mut self, window_point: Point, blocks: &[SelectableBlock], extend: bool) {
        self.begin_click_or_drag(window_point, 1, blocks, extend);
    }

    pub fn begin_click_or_drag(
        &mut self,
        window_point: Point,
        click_count: u8,
        blocks: &[SelectableBlock],
        extend: bool,
    ) {
        let Some(hit) = resolve_point_in_blocks(window_point, blocks) else {
            if !extend {
                self.clear();
            }
            return;
        };
        let text = &blocks[hit.block_index].plain_text;
        match click_count {
            2 => {
                let s = prev_word_boundary(text, hit.byte_offset.saturating_add(1).min(text.len()));
                let e = next_word_boundary(text, hit.byte_offset);
                self.anchor = Some(SelectionEndpoint {
                    block_index: hit.block_index,
                    byte_offset: s,
                });
                self.focus = Some(SelectionEndpoint {
                    block_index: hit.block_index,
                    byte_offset: e,
                });
                self.is_dragging = false;
            }
            3.. => {
                let s = line_start(text, hit.byte_offset);
                let e = line_end(text, hit.byte_offset);
                self.anchor = Some(SelectionEndpoint {
                    block_index: hit.block_index,
                    byte_offset: s,
                });
                self.focus = Some(SelectionEndpoint {
                    block_index: hit.block_index,
                    byte_offset: e,
                });
                self.is_dragging = false;
            }
            _ => {
                if extend && self.anchor.is_some() {
                    self.focus = Some(hit);
                } else {
                    self.anchor = Some(hit);
                    self.focus = Some(hit);
                }
                self.is_dragging = true;
            }
        }
    }

    pub fn update_drag(&mut self, window_point: Point, blocks: &[SelectableBlock]) {
        if !self.is_dragging {
            return;
        }
        if let Some(hit) = resolve_point_in_blocks(window_point, blocks) {
            self.focus = Some(hit);
        }
    }

    pub fn end_drag(&mut self) {
        self.is_dragging = false;
    }

    pub fn select_all(&mut self, blocks: &[SelectableBlock]) {
        let Some(last) = blocks.last() else {
            self.clear();
            return;
        };
        self.anchor = Some(SelectionEndpoint {
            block_index: 0,
            byte_offset: 0,
        });
        self.focus = Some(SelectionEndpoint {
            block_index: blocks.len() - 1,
            byte_offset: last.plain_text.len(),
        });
        self.is_dragging = false;
    }

    /// Computes highlight rectangles in window coordinates for `block_index`.
    pub fn highlight_rects_for_block(&self, block_index: usize, block: &SelectableBlock) -> Vec<Rect> {
        let Some((start, end)) = self.ordered_range() else {
            return Vec::new();
        };
        if start == end || block_index < start.block_index || block_index > end.block_index {
            return Vec::new();
        }
        let s_byte = if block_index == start.block_index {
            clamp_char_boundary(&block.plain_text, start.byte_offset)
        } else {
            0
        };
        let e_byte = if block_index == end.block_index {
            clamp_char_boundary(&block.plain_text, end.byte_offset)
        } else {
            block.plain_text.len()
        };
        block
            .paragraph
            .selection_rects(s_byte..e_byte)
            .into_iter()
            .map(|r| r.offset(block.bounds.x, block.bounds.y))
            .collect()
    }

    /// Extracts concatenated UTF-8 text across all selected transcript blocks.
    pub fn selected_text(&self, blocks: &[SelectableBlock]) -> String {
        let Some((start, end)) = self.ordered_range() else {
            return String::new();
        };
        if start == end || blocks.is_empty() {
            return String::new();
        }
        let last_idx = end.block_index.min(blocks.len() - 1);
        let mut out = String::new();
        for (idx, block) in blocks
            .iter()
            .enumerate()
            .take(last_idx + 1)
            .skip(start.block_index)
        {
            if idx > start.block_index {
                out.push('\n');
            }
            let s = if idx == start.block_index {
                clamp_char_boundary(&block.plain_text, start.byte_offset)
            } else {
                0
            };
            let e = if idx == end.block_index {
                clamp_char_boundary(&block.plain_text, end.byte_offset)
            } else {
                block.plain_text.len()
            };
            if s < e {
                out.push_str(&block.plain_text[s..e]);
            }
        }
        out
    }

    pub fn copy_to_clipboard(&self, blocks: &[SelectableBlock]) -> bool {
        let text = self.selected_text(blocks);
        if text.is_empty() {
            return false;
        }
        rota_platform::clipboard_set(&text);
        true
    }
}

fn resolve_point_in_blocks(window_point: Point, blocks: &[SelectableBlock]) -> Option<SelectionEndpoint> {
    if blocks.is_empty() {
        return None;
    }
    if window_point.y < blocks[0].bounds.min_y() {
        return Some(SelectionEndpoint {
            block_index: 0,
            byte_offset: 0,
        });
    }
    for (idx, b) in blocks.iter().enumerate() {
        if window_point.y <= b.bounds.max_y() || idx + 1 == blocks.len() {
            let local = Point::new(
                (window_point.x - b.bounds.x).max(0.0),
                (window_point.y - b.bounds.y).clamp(0.0, b.bounds.height),
            );
            let byte = clamp_char_boundary(&b.plain_text, b.paragraph.byte_index_at_point(local));
            return Some(SelectionEndpoint {
                block_index: idx,
                byte_offset: byte,
            });
        }
    }
    None
}
