//! UTF-8 character/word/line boundary navigation and editor key/modifier types.

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Modifiers {
    pub cmd: bool,
    pub shift: bool,
    pub alt: bool,
    pub ctrl: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ReturnBehavior {
    SubmitOnReturn,
    InsertNewline,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum EditKey {
    Left,
    Right,
    Up,
    Down,
    Home,
    End,
    PageUp,
    PageDown,
    Backspace,
    Delete,
    Return,
    Tab,
    Escape,
    SelectAll,
    Copy,
    Cut,
    Paste,
    Undo,
    Redo,
    KillToLineEnd,
    Text(String),
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum EditOutcome {
    Unchanged,
    Changed,
    Submitted(String),
    Cancelled,
}

pub fn clamp_char_boundary(s: &str, idx: usize) -> usize {
    let mut i = idx.min(s.len());
    while i > 0 && !s.is_char_boundary(i) {
        i -= 1;
    }
    i
}

pub fn prev_char_boundary(s: &str, idx: usize) -> usize {
    let i = clamp_char_boundary(s, idx);
    s[..i].char_indices().next_back().map_or(0, |(p, _)| p)
}

pub fn next_char_boundary(s: &str, idx: usize) -> usize {
    let i = clamp_char_boundary(s, idx);
    let mut it = s[i..].char_indices();
    let _ = it.next();
    it.next().map_or(s.len(), |(off, _)| i + off)
}

pub fn prev_word_boundary(s: &str, idx: usize) -> usize {
    let i = clamp_char_boundary(s, idx);
    let mut chars: Vec<(usize, char)> = s[..i].char_indices().collect();
    while let Some(&(_, c)) = chars.last() {
        if !c.is_whitespace() {
            break;
        }
        chars.pop();
    }
    let word_kind = chars.last().is_some_and(|&(_, c)| is_word_char(c));
    while let Some(&(_, c)) = chars.last() {
        if c.is_whitespace() || is_word_char(c) != word_kind {
            break;
        }
        chars.pop();
    }
    chars.last().map_or(0, |&(b, c)| b + c.len_utf8()).min(i)
}

pub fn next_word_boundary(s: &str, idx: usize) -> usize {
    let i = clamp_char_boundary(s, idx);
    let mut iter = s[i..].char_indices().peekable();
    while let Some(&(_, c)) = iter.peek() {
        if !c.is_whitespace() {
            break;
        }
        iter.next();
    }
    let Some(&(_, first)) = iter.peek() else {
        return s.len();
    };
    let word_kind = is_word_char(first);
    while let Some(&(off, c)) = iter.peek() {
        if c.is_whitespace() || is_word_char(c) != word_kind {
            return i + off;
        }
        iter.next();
    }
    s.len()
}

pub fn line_start(s: &str, idx: usize) -> usize {
    let i = clamp_char_boundary(s, idx);
    s[..i].rfind('\n').map_or(0, |p| p + 1)
}

pub fn line_end(s: &str, idx: usize) -> usize {
    let i = clamp_char_boundary(s, idx);
    s[i..].find('\n').map_or(s.len(), |p| i + p)
}

#[inline]
fn is_word_char(c: char) -> bool {
    c.is_alphanumeric() || c == '_'
}

pub fn translate_winit_key(
    logical: &winit::keyboard::Key,
    text: Option<&str>,
    mods: Modifiers,
) -> Option<EditKey> {
    use winit::keyboard::{Key, NamedKey};
    if mods.cmd
        && let Key::Character(ch) = logical
    {
        match ch.to_ascii_lowercase().as_str() {
            "a" => return Some(EditKey::SelectAll),
            "c" => return Some(EditKey::Copy),
            "x" => return Some(EditKey::Cut),
            "v" => return Some(EditKey::Paste),
            "z" if mods.shift => return Some(EditKey::Redo),
            "z" => return Some(EditKey::Undo),
            "y" => return Some(EditKey::Redo),
            "=" | "+" | "-" | "0" => return Some(EditKey::Text(ch.to_string())),
            other if other.len() == 1 && other.chars().all(|c| c.is_ascii_digit()) => {
                return Some(EditKey::Text(other.to_string()));
            }
            _ => {}
        }
    }
    if mods.ctrl
        && !mods.cmd
        && !mods.alt
        && let Key::Character(ch) = logical
    {
        match ch.to_ascii_lowercase().as_str() {
            "a" => return Some(EditKey::Home),
            "e" => return Some(EditKey::End),
            "k" => return Some(EditKey::KillToLineEnd),
            "d" => return Some(EditKey::Delete),
            "h" => return Some(EditKey::Backspace),
            "b" => return Some(EditKey::Left),
            "f" => return Some(EditKey::Right),
            "p" => return Some(EditKey::Up),
            "n" => return Some(EditKey::Down),
            _ => {}
        }
    }
    match logical {
        Key::Named(NamedKey::ArrowLeft) => Some(EditKey::Left),
        Key::Named(NamedKey::ArrowRight) => Some(EditKey::Right),
        Key::Named(NamedKey::ArrowUp) => Some(EditKey::Up),
        Key::Named(NamedKey::ArrowDown) => Some(EditKey::Down),
        Key::Named(NamedKey::Home) => Some(EditKey::Home),
        Key::Named(NamedKey::End) => Some(EditKey::End),
        Key::Named(NamedKey::PageUp) => Some(EditKey::PageUp),
        Key::Named(NamedKey::PageDown) => Some(EditKey::PageDown),
        Key::Named(NamedKey::Space) if !mods.cmd && !mods.ctrl => Some(EditKey::Text(" ".to_string())),
        Key::Named(NamedKey::Backspace) => Some(EditKey::Backspace),
        Key::Named(NamedKey::Delete) => Some(EditKey::Delete),
        Key::Named(NamedKey::Enter) => Some(EditKey::Return),
        Key::Named(NamedKey::Tab) => Some(EditKey::Tab),
        Key::Named(NamedKey::Escape) => Some(EditKey::Escape),
        _ if !mods.cmd && !mods.ctrl => {
            let filtered: String = text?.chars().filter(|c| !c.is_control()).collect();
            (!filtered.is_empty()).then_some(EditKey::Text(filtered))
        }
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::text_input::TextEditState;

    #[test]
    fn utf8_word_line_navigation_kill_line_and_undo_redo() {
        let mut ed = TextEditState::multi_line("Привет мир 🚀\nsecond line", ReturnBehavior::SubmitOnReturn);
        ed.handle_key(
            EditKey::Left,
            Modifiers {
                cmd: true,
                ..Default::default()
            },
            None,
        );
        assert_eq!(&ed.text()[ed.cursor()..], "second line");
        assert_eq!(
            ed.handle_key(EditKey::KillToLineEnd, Modifiers::default(), None),
            EditOutcome::Changed
        );
        assert_eq!(ed.text(), "Привет мир 🚀\n");
        assert!(ed.undo());
        assert_eq!(&ed.text()[ed.cursor()..], "second line");
        ed.handle_key(EditKey::Left, Modifiers::default(), None);
        assert!(ed.text()[..ed.cursor()].ends_with('🚀'));
        assert_eq!(
            ed.handle_key(EditKey::Backspace, Modifiers::default(), None),
            EditOutcome::Changed
        );
        assert!(ed.undo());
        assert!(ed.text().starts_with("Привет мир 🚀\n"));
        assert!(ed.redo());
        ed.handle_key(
            EditKey::Return,
            Modifiers {
                shift: true,
                ..Default::default()
            },
            None,
        );
        assert_eq!(ed.text().lines().count(), 3);
        assert!(matches!(
            ed.handle_key(EditKey::Return, Modifiers::default(), None),
            EditOutcome::Submitted(_)
        ));
    }
}
