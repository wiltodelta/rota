use std::io::Write;

use regex_lite::Regex;
use serde_json::{Value, json};

use crate::model::{AgentQuestion, QuestionOption};

pub use super::claude_dialog_bridge::{ClaudeDialogBridge, QuestionHook};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ClaudeDialog {
    pub prompt: Vec<String>,
    pub options: Vec<String>,
    pub selected: usize,
    pub numbered: bool,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ClaudeDialogEvent {
    Shown { message: Option<String> },
    Question { pid: i32, open: bool },
}

#[derive(Clone)]
struct NumberedOpt {
    number: usize,
    label: String,
    marked: bool,
    label_column: usize,
}

#[derive(Clone)]
struct FocusedOpt {
    label: String,
    label_column: usize,
}

struct ScreenLine {
    text: String,
    indent: usize,
    is_rule: bool,
    option: Option<NumberedOpt>,
    focused: Option<FocusedOpt>,
}

impl ScreenLine {
    fn parse(raw: &[u8]) -> Self {
        let mut nuls = 0usize;
        let mut border_bytes = true;
        for &b in raw {
            if b == 0 {
                nuls += 1;
            } else if b != b' ' && b != b'\r' {
                border_bytes = false;
            }
        }
        if border_bytes && nuls >= 10 {
            return Self {
                text: String::new(),
                indent: 0,
                is_rule: true,
                option: None,
                focused: None,
            };
        }
        let Some(end) = raw.iter().rposition(|b| (0x21..=0x7E).contains(b)) else {
            return Self {
                text: String::new(),
                indent: 0,
                is_rule: false,
                option: None,
                focused: None,
            };
        };
        let trimmed: String = raw[..=end]
            .iter()
            .map(|&b| {
                if (0x21..=0x7E).contains(&b) {
                    b as char
                } else {
                    ' '
                }
            })
            .collect();
        let non_space = trimmed.trim_start_matches(' ');
        if non_space.len() >= 10
            && let Some(first_ch) = non_space.chars().next()
            && non_space.chars().all(|c| c == first_ch)
        {
            return Self {
                text: String::new(),
                indent: 0,
                is_rule: true,
                option: None,
                focused: None,
            };
        }
        let indent = trimmed.len() - non_space.len();
        let option = Self::parse_numbered(&trimmed);
        let focused = if option.is_none() {
            Self::parse_focused(&trimmed)
        } else {
            None
        };
        Self {
            text: trimmed,
            indent,
            is_rule: false,
            option,
            focused,
        }
    }

    fn parse_numbered(line: &str) -> Option<NumberedOpt> {
        let re = Regex::new(r"^(\s*)(?:(\S)\s+)?([1-9])\.\s+(\S.*)$").ok()?;
        let caps = re.captures(line)?;
        let number: usize = caps.get(3)?.as_str().parse().ok()?;
        let label_match = caps.get(4)?;
        Some(NumberedOpt {
            number,
            label: collapse_spaces(label_match.as_str()),
            marked: caps.get(2).is_some(),
            label_column: label_match.start(),
        })
    }

    fn parse_focused(line: &str) -> Option<FocusedOpt> {
        let re = Regex::new(r"^(\s+)([o>])(\s{1,3})(\S.*)$").ok()?;
        let caps = re.captures(line)?;
        let label_match = caps.get(4)?;
        Some(FocusedOpt {
            label: collapse_spaces(label_match.as_str()),
            label_column: label_match.start(),
        })
    }
}

fn collapse_spaces(s: &str) -> String {
    s.split_whitespace().collect::<Vec<_>>().join(" ")
}

impl ClaudeDialog {
    pub const DEFAULT_TITLE: &'static str = "Claude is waiting for your answer";
    pub const ESCAPE: &'static str = "\x1B";

    pub fn cancels(action: &str) -> bool {
        action == "cancel" || action == "decline"
    }

    pub fn read_screen(data: &[u8]) -> Option<Self> {
        let lines: Vec<ScreenLine> = data.split(|&b| b == b'\n').map(ScreenLine::parse).collect();
        let mut found = None;
        let mut idx = 0usize;
        while idx < lines.len() {
            if let Some((dlg, next)) =
                Self::numbered_dialog(idx, &lines).or_else(|| Self::unnumbered_dialog(idx, &lines))
            {
                if let Some(d) = dlg {
                    found = Some(d);
                }
                idx = next;
            } else {
                idx += 1;
            }
        }
        found
    }

    fn numbered_dialog(idx: usize, lines: &[ScreenLine]) -> Option<(Option<Self>, usize)> {
        let first = lines[idx].option.as_ref()?;
        if first.number != 1 {
            return None;
        }
        let mut options = vec![first.label.clone()];
        let mut marked = usize::from(first.marked);
        let mut selected = 0usize;
        let mut next = idx + 1;
        while next < lines.len() {
            let line = &lines[next];
            if let Some(opt) = &line.option {
                if opt.number != options.len() + 1 {
                    break;
                }
                if opt.marked {
                    selected = options.len();
                    marked += 1;
                }
                options.push(opt.label.clone());
            } else if !line.text.is_empty() && line.indent >= first.label_column {
                if let Some(last) = options.last_mut() {
                    last.push(' ');
                    last.push_str(&collapse_spaces(&line.text));
                }
            } else {
                break;
            }
            next += 1;
        }
        if options.len() < 2 || marked != 1 || !Self::is_at_bottom(&lines[next..]) {
            return Some((None, next));
        }
        Some((
            Some(Self {
                prompt: Self::prompt_above(idx, lines),
                options,
                selected,
                numbered: true,
            }),
            next,
        ))
    }

    fn unnumbered_dialog(focus_idx: usize, lines: &[ScreenLine]) -> Option<(Option<Self>, usize)> {
        let focused = lines[focus_idx].focused.as_ref()?;
        let belongs = |l: &ScreenLine| {
            !l.text.is_empty()
                && l.option.is_none()
                && (l.focused.is_some() || l.indent >= focused.label_column)
        };
        let mut start = focus_idx;
        while start > 0 && belongs(&lines[start - 1]) {
            start -= 1;
        }
        while start < focus_idx
            && lines[start].focused.is_none()
            && lines[start].indent > focused.label_column
        {
            start += 1;
        }
        let mut next = focus_idx + 1;
        while next < lines.len() && belongs(&lines[next]) {
            next += 1;
        }
        let mut options: Vec<String> = Vec::new();
        let mut marked = 0usize;
        let mut selected = 0usize;
        for line in &lines[start..next] {
            if let Some(choice) = &line.focused {
                selected = options.len();
                marked += 1;
                options.push(choice.label.clone());
            } else if line.indent == focused.label_column {
                options.push(collapse_spaces(&line.text));
            } else if let Some(last) = options.last_mut() {
                last.push(' ');
                last.push_str(&collapse_spaces(&line.text));
            }
        }
        if options.len() < 2 || marked != 1 || !Self::is_at_bottom(&lines[next..]) {
            return Some((None, next));
        }
        Some((
            Some(Self {
                prompt: Self::prompt_above(start, lines),
                options,
                selected,
                numbered: false,
            }),
            next,
        ))
    }

    fn is_at_bottom(tail: &[ScreenLine]) -> bool {
        if tail.iter().filter(|l| !l.text.is_empty()).count() > 3 {
            return false;
        }
        if let Some(rule_pos) = tail.iter().position(|l| l.is_rule) {
            return tail[rule_pos + 1..].iter().all(|l| l.text.is_empty());
        }
        true
    }

    fn prompt_above(idx: usize, lines: &[ScreenLine]) -> Vec<String> {
        let mut prompt = Vec::new();
        let mut unindented = false;
        for line in lines[..idx].iter().rev() {
            if line.is_rule {
                break;
            }
            if line.text.is_empty() {
                if unindented {
                    break;
                }
                continue;
            }
            if line.indent == 0 {
                if !prompt.is_empty() && !unindented {
                    break;
                }
                unindented = true;
            }
            prompt.insert(0, collapse_spaces(&line.text));
            if prompt.len() == if unindented { 3 } else { 12 } {
                break;
            }
        }
        prompt
    }

    pub fn question(dialog: Option<&Self>, title: &str, tool: Option<String>) -> AgentQuestion {
        let unreadable = "Rota cannot read the choices of this dialog. Open the session in Terminal to answer it, \
or cancel it here.";
        let mut q = AgentQuestion::new(title);
        q.detail = dialog
            .map(|d| d.prompt.join("\n"))
            .unwrap_or_else(|| unreadable.to_string());
        q.actions = dialog
            .map(|d| {
                d.options
                    .iter()
                    .map(|o| QuestionOption::new(o.clone(), o.clone()))
                    .collect()
            })
            .unwrap_or_default();
        q.context = tool;
        q
    }

    pub fn key(&self, action: &str) -> Option<String> {
        if Self::cancels(action) {
            return Some(Self::ESCAPE.to_string());
        }
        let target = self.options.iter().position(|o| o == action)?;
        if self.numbered {
            return Some((target + 1).to_string());
        }
        let step = if target >= self.selected {
            "\x1B[B"
        } else {
            "\x1B[A"
        };
        let count = target.abs_diff(self.selected);
        Some(format!("{}\r", step.repeat(count)))
    }

    pub fn parse_event(line: &str) -> Option<ClaudeDialogEvent> {
        let obj: Value = serde_json::from_str(line).ok()?;
        if let Some(st) = obj.get("rota_question").and_then(Value::as_str)
            && let Some(pid) = obj.get("pid").and_then(Value::as_i64)
        {
            return Some(ClaudeDialogEvent::Question {
                pid: pid as i32,
                open: st == "open",
            });
        }
        if obj.get("hook_event_name").and_then(Value::as_str) == Some("Notification") {
            return Some(ClaudeDialogEvent::Shown {
                message: obj.get("message").and_then(Value::as_str).map(ToOwned::to_owned),
            });
        }
        None
    }

    pub fn append_question_marker(open: bool, path: Option<&str>) {
        let Some(path) = path else {
            return;
        };
        let Ok(mut line) = serde_json::to_vec(&json!({
            "rota_question": if open { "open" } else { "closed" },
            "pid": std::process::id(),
        })) else {
            return;
        };
        line.push(b'\n');
        if let Ok(mut file) = std::fs::OpenOptions::new().create(true).append(true).open(path) {
            let _ = file.write_all(&line);
        }
    }
}
