//! UTF-8 single-line and multi-line text editor state (`TextEditState`) with Undo/Redo & mouse selection.

use std::ops::Range;

use crate::geometry::{Point, Size};
use crate::text::ShapedParagraph;
pub use crate::text_nav::{
    EditKey, EditOutcome, Modifiers, ReturnBehavior, clamp_char_boundary, line_end, line_start,
    next_char_boundary, next_word_boundary, prev_char_boundary, prev_word_boundary,
};

#[derive(Debug, Clone, PartialEq, Eq)]
struct UndoSnapshot {
    text: String,
    cursor: usize,
    anchor: usize,
}

#[derive(Debug, Clone)]
pub struct TextEditState {
    text: String,
    cursor: usize,
    anchor: usize,
    preferred_x: Option<f32>,
    pub multiline: bool,
    pub return_behavior: ReturnBehavior,
    pub scroll_x: f32,
    pub scroll_y: f32,
    undo_stack: Vec<UndoSnapshot>,
    redo_stack: Vec<UndoSnapshot>,
}

impl Default for TextEditState {
    fn default() -> Self {
        Self::single_line("")
    }
}

impl TextEditState {
    const MAX_UNDO: usize = 128;

    pub fn single_line(initial: impl Into<String>) -> Self {
        let text = sanitize_single_line(&initial.into());
        let end = text.len();
        Self {
            text,
            cursor: end,
            anchor: end,
            preferred_x: None,
            multiline: false,
            return_behavior: ReturnBehavior::SubmitOnReturn,
            scroll_x: 0.0,
            scroll_y: 0.0,
            undo_stack: Vec::new(),
            redo_stack: Vec::new(),
        }
    }

    pub fn multi_line(initial: impl Into<String>, return_behavior: ReturnBehavior) -> Self {
        let text = initial.into().replace("\r\n", "\n").replace('\r', "\n");
        let end = text.len();
        Self {
            text,
            cursor: end,
            anchor: end,
            preferred_x: None,
            multiline: true,
            return_behavior,
            scroll_x: 0.0,
            scroll_y: 0.0,
            undo_stack: Vec::new(),
            redo_stack: Vec::new(),
        }
    }

    #[inline]
    pub fn text(&self) -> &str {
        &self.text
    }

    #[inline]
    pub fn is_empty(&self) -> bool {
        self.text.is_empty()
    }

    #[inline]
    pub fn cursor(&self) -> usize {
        self.cursor
    }

    #[inline]
    pub fn anchor(&self) -> usize {
        self.anchor
    }

    #[inline]
    pub fn selection_range(&self) -> Range<usize> {
        if self.cursor <= self.anchor {
            self.cursor..self.anchor
        } else {
            self.anchor..self.cursor
        }
    }

    #[inline]
    pub fn has_selection(&self) -> bool {
        self.cursor != self.anchor
    }

    pub fn selected_text(&self) -> &str {
        &self.text[self.selection_range()]
    }

    pub fn set_text(&mut self, next: impl Into<String>) {
        let raw = next.into();
        self.text = if self.multiline {
            raw.replace("\r\n", "\n").replace('\r', "\n")
        } else {
            sanitize_single_line(&raw)
        };
        self.cursor = self.text.len();
        self.anchor = self.cursor;
        self.preferred_x = None;
    }

    pub fn select_all(&mut self) {
        self.anchor = 0;
        self.cursor = self.text.len();
        self.preferred_x = None;
    }

    pub fn insert_str(&mut self, input: &str) -> EditOutcome {
        let cleaned = if self.multiline {
            input.replace("\r\n", "\n").replace('\r', "\n")
        } else {
            sanitize_single_line(input)
        };
        if cleaned.is_empty() && !self.has_selection() {
            return EditOutcome::Unchanged;
        }
        self.push_undo();
        let sel = self.selection_range();
        self.text.replace_range(sel.clone(), &cleaned);
        self.cursor = sel.start + cleaned.len();
        self.anchor = self.cursor;
        self.preferred_x = None;
        EditOutcome::Changed
    }

    pub fn cut_to_string(&mut self) -> Option<String> {
        if !self.has_selection() {
            return None;
        }
        let copied = self.selected_text().to_string();
        self.push_undo();
        let sel = self.selection_range();
        self.text.replace_range(sel.clone(), "");
        self.cursor = sel.start;
        self.anchor = self.cursor;
        self.preferred_x = None;
        Some(copied)
    }

    pub fn undo(&mut self) -> bool {
        let Some(prev) = self.undo_stack.pop() else {
            return false;
        };
        self.redo_stack.push(self.snapshot());
        self.restore(prev);
        true
    }

    pub fn redo(&mut self) -> bool {
        let Some(next) = self.redo_stack.pop() else {
            return false;
        };
        self.undo_stack.push(self.snapshot());
        self.restore(next);
        true
    }

    pub fn handle_key(
        &mut self,
        key: EditKey,
        mods: Modifiers,
        shaped: Option<&ShapedParagraph>,
    ) -> EditOutcome {
        match key {
            EditKey::Escape => EditOutcome::Cancelled,
            EditKey::SelectAll => {
                self.select_all();
                EditOutcome::Unchanged
            }
            EditKey::Copy => {
                if self.has_selection() {
                    rota_platform::clipboard_set(self.selected_text());
                }
                EditOutcome::Unchanged
            }
            EditKey::Cut => self.cut_to_string().map_or(EditOutcome::Unchanged, |s| {
                rota_platform::clipboard_set(&s);
                EditOutcome::Changed
            }),
            EditKey::Paste => {
                rota_platform::clipboard_get().map_or(EditOutcome::Unchanged, |clip| self.insert_str(&clip))
            }
            EditKey::Undo => {
                if self.undo() {
                    EditOutcome::Changed
                } else {
                    EditOutcome::Unchanged
                }
            }
            EditKey::Redo => {
                if self.redo() {
                    EditOutcome::Changed
                } else {
                    EditOutcome::Unchanged
                }
            }
            EditKey::Return => match self.return_behavior {
                ReturnBehavior::SubmitOnReturn if !mods.shift => EditOutcome::Submitted(self.text.clone()),
                ReturnBehavior::SubmitOnReturn | ReturnBehavior::InsertNewline => {
                    if self.multiline {
                        self.insert_str("\n")
                    } else {
                        EditOutcome::Submitted(self.text.clone())
                    }
                }
            },
            EditKey::Tab => {
                if self.multiline {
                    self.insert_str("    ")
                } else {
                    EditOutcome::Unchanged
                }
            }
            EditKey::Text(s) => self.insert_str(&s),
            EditKey::Backspace => self.delete_backward(mods),
            EditKey::Delete => self.delete_forward(mods),
            EditKey::KillToLineEnd => self.kill_to_line_end(),
            EditKey::Left => {
                self.move_horizontal(-1, mods);
                EditOutcome::Unchanged
            }
            EditKey::Right => {
                self.move_horizontal(1, mods);
                EditOutcome::Unchanged
            }
            EditKey::Home | EditKey::PageUp => {
                self.set_cursor(line_start(&self.text, self.cursor), mods.shift);
                EditOutcome::Unchanged
            }
            EditKey::End | EditKey::PageDown => {
                self.set_cursor(line_end(&self.text, self.cursor), mods.shift);
                EditOutcome::Unchanged
            }
            EditKey::Up => {
                self.move_vertical(-1, mods, shaped);
                EditOutcome::Unchanged
            }
            EditKey::Down => {
                self.move_vertical(1, mods, shaped);
                EditOutcome::Unchanged
            }
        }
    }

    pub fn pointer_down(
        &mut self,
        local_point: Point,
        click_count: u8,
        shift: bool,
        shaped: &ShapedParagraph,
    ) {
        let idx = clamp_char_boundary(&self.text, shaped.byte_index_at_point(local_point));
        match click_count {
            2 => {
                self.anchor = prev_word_boundary(&self.text, idx.saturating_add(1).min(self.text.len()));
                self.cursor = next_word_boundary(&self.text, idx);
            }
            3.. => {
                self.anchor = line_start(&self.text, idx);
                self.cursor = line_end(&self.text, idx);
            }
            _ => self.set_cursor(idx, shift),
        }
    }

    pub fn pointer_drag(&mut self, local_point: Point, shaped: &ShapedParagraph) {
        self.cursor = clamp_char_boundary(&self.text, shaped.byte_index_at_point(local_point));
        self.preferred_x = None;
    }

    pub fn ensure_cursor_visible(&mut self, shaped: &ShapedParagraph, viewport: Size) {
        let caret = shaped.cursor_rect(self.cursor);
        let pad = 8.0;
        if !self.multiline {
            if caret.x < self.scroll_x + pad {
                self.scroll_x = (caret.x - pad).max(0.0);
            } else if caret.max_x() > self.scroll_x + viewport.width - pad {
                self.scroll_x = (caret.max_x() + pad - viewport.width).max(0.0);
            }
            self.scroll_y = 0.0;
        } else {
            self.scroll_x = 0.0;
            if caret.y < self.scroll_y {
                self.scroll_y = caret.y.max(0.0);
            } else if caret.max_y() > self.scroll_y + viewport.height {
                self.scroll_y = (caret.max_y() - viewport.height).max(0.0);
            }
        }
    }

    fn delete_backward(&mut self, mods: Modifiers) -> EditOutcome {
        if self.has_selection() {
            return self.insert_str("");
        }
        if self.cursor == 0 {
            return EditOutcome::Unchanged;
        }
        let target = if mods.cmd {
            let ls = line_start(&self.text, self.cursor);
            if ls == self.cursor {
                prev_char_boundary(&self.text, self.cursor)
            } else {
                ls
            }
        } else if mods.alt {
            prev_word_boundary(&self.text, self.cursor)
        } else {
            prev_char_boundary(&self.text, self.cursor)
        };
        self.push_undo();
        self.text.replace_range(target..self.cursor, "");
        self.cursor = target;
        self.anchor = target;
        self.preferred_x = None;
        EditOutcome::Changed
    }

    fn delete_forward(&mut self, mods: Modifiers) -> EditOutcome {
        if self.has_selection() {
            return self.insert_str("");
        }
        if self.cursor >= self.text.len() {
            return EditOutcome::Unchanged;
        }
        let target = if mods.alt {
            next_word_boundary(&self.text, self.cursor)
        } else {
            next_char_boundary(&self.text, self.cursor)
        };
        self.push_undo();
        self.text.replace_range(self.cursor..target, "");
        self.anchor = self.cursor;
        self.preferred_x = None;
        EditOutcome::Changed
    }

    fn kill_to_line_end(&mut self) -> EditOutcome {
        if self.has_selection() {
            return self.insert_str("");
        }
        if self.cursor >= self.text.len() {
            return EditOutcome::Unchanged;
        }
        let le = line_end(&self.text, self.cursor);
        let target = if le == self.cursor {
            next_char_boundary(&self.text, self.cursor)
        } else {
            le
        };
        self.push_undo();
        self.text.replace_range(self.cursor..target, "");
        self.anchor = self.cursor;
        self.preferred_x = None;
        EditOutcome::Changed
    }

    fn move_horizontal(&mut self, dir: i32, mods: Modifiers) {
        if !mods.shift && self.has_selection() && !mods.cmd && !mods.alt {
            let sel = self.selection_range();
            self.set_cursor(if dir < 0 { sel.start } else { sel.end }, false);
            return;
        }
        let next = if dir < 0 {
            if mods.cmd {
                line_start(&self.text, self.cursor)
            } else if mods.alt {
                prev_word_boundary(&self.text, self.cursor)
            } else {
                prev_char_boundary(&self.text, self.cursor)
            }
        } else if mods.cmd {
            line_end(&self.text, self.cursor)
        } else if mods.alt {
            next_word_boundary(&self.text, self.cursor)
        } else {
            next_char_boundary(&self.text, self.cursor)
        };
        self.set_cursor(next, mods.shift);
    }

    fn move_vertical(&mut self, dir: i32, mods: Modifiers, shaped: Option<&ShapedParagraph>) {
        if mods.cmd || !self.multiline {
            self.set_cursor(if dir < 0 { 0 } else { self.text.len() }, mods.shift);
            return;
        }
        let Some(para) = shaped.filter(|p| !p.lines.is_empty()) else {
            return;
        };
        let cur_line = para.line_index_for_byte(self.cursor);
        let pref_x = self
            .preferred_x
            .unwrap_or_else(|| para.lines[cur_line].x_for_byte_index(self.cursor));
        let next_line = if dir < 0 {
            let Some(prev) = cur_line.checked_sub(1) else {
                self.set_cursor(0, mods.shift);
                return;
            };
            prev
        } else if cur_line + 1 >= para.lines.len() {
            self.set_cursor(self.text.len(), mods.shift);
            return;
        } else {
            cur_line + 1
        };
        let byte = clamp_char_boundary(&self.text, para.lines[next_line].byte_index_at_x(pref_x));
        self.cursor = byte;
        if !mods.shift {
            self.anchor = byte;
        }
        self.preferred_x = Some(pref_x);
    }

    fn set_cursor(&mut self, pos: usize, extend: bool) {
        let clamped = clamp_char_boundary(&self.text, pos);
        self.cursor = clamped;
        if !extend {
            self.anchor = clamped;
        }
        self.preferred_x = None;
    }

    fn snapshot(&self) -> UndoSnapshot {
        UndoSnapshot {
            text: self.text.clone(),
            cursor: self.cursor,
            anchor: self.anchor,
        }
    }

    fn push_undo(&mut self) {
        if self.undo_stack.len() >= Self::MAX_UNDO {
            self.undo_stack.remove(0);
        }
        self.undo_stack.push(self.snapshot());
        self.redo_stack.clear();
    }

    fn restore(&mut self, snap: UndoSnapshot) {
        self.text = snap.text;
        self.cursor = clamp_char_boundary(&self.text, snap.cursor);
        self.anchor = clamp_char_boundary(&self.text, snap.anchor);
        self.preferred_x = None;
    }
}

fn sanitize_single_line(s: &str) -> String {
    s.replace(['\r', '\n'], " ")
}
