use pulldown_cmark::{Event, Options, Parser, Tag, TagEnd};

use crate::transcript::MarkdownTable;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum MarkdownAlert {
    Note,
    Tip,
    Important,
    Warning,
    Caution,
}

impl MarkdownAlert {
    pub fn title(self) -> &'static str {
        match self {
            Self::Note => "Note",
            Self::Tip => "Tip",
            Self::Important => "Important",
            Self::Warning => "Warning",
            Self::Caution => "Caution",
        }
    }

    pub fn extract(raw: &str) -> (Option<Self>, String) {
        let (first, rest) = match raw.split_once('\n') {
            Some((f, r)) => (f.trim(), Some(r)),
            None => (raw.trim(), None),
        };
        let kind = match first.to_ascii_uppercase().as_str() {
            "[!NOTE]" => Some(Self::Note),
            "[!TIP]" => Some(Self::Tip),
            "[!IMPORTANT]" => Some(Self::Important),
            "[!WARNING]" => Some(Self::Warning),
            "[!CAUTION]" => Some(Self::Caution),
            _ => None,
        };
        let Some(alert) = kind else {
            return (None, raw.to_string());
        };
        let body = rest.map_or_else(String::new, |r| r.trim().to_string());
        (Some(alert), body)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MarkdownBlock {
    Heading {
        level: u8,
        text: String,
    },
    ListItem {
        marker: String,
        text: String,
        indent: usize,
    },
    Code {
        text: String,
        language: Option<String>,
    },
    Paragraph(String),
    Table(MarkdownTable),
    Blockquote(String),
    ThematicBreak,
}

impl MarkdownBlock {
    pub fn parse(text: &str) -> Vec<Self> {
        let lines: Vec<&str> = text.split('\n').collect();
        let mut blocks = Vec::new();
        let mut paragraph: Vec<&str> = Vec::new();
        let mut quote: Vec<String> = Vec::new();
        let mut code: Option<Vec<&str>> = None;
        let mut language: Option<String> = None;

        let flush = |blocks: &mut Vec<Self>, paragraph: &mut Vec<&str>, quote: &mut Vec<String>| {
            if !paragraph.is_empty() {
                blocks.push(Self::Paragraph(paragraph.join("\n")));
                paragraph.clear();
            }
            if !quote.is_empty() {
                blocks.push(Self::Blockquote(quote.join("\n")));
                quote.clear();
            }
        };

        let mut index = 0usize;
        while index < lines.len() {
            let line = lines[index];
            let trimmed = line.trim_matches([' ', '\t', '\r']);
            if let Some(rest) = trimmed.strip_prefix("```") {
                if let Some(open) = code.take() {
                    blocks.push(Self::Code {
                        text: open.join("\n"),
                        language: language.take(),
                    });
                } else {
                    flush(&mut blocks, &mut paragraph, &mut quote);
                    code = Some(Vec::new());
                    let info = rest.split_whitespace().next().unwrap_or("");
                    language = (!info.is_empty()).then(|| info.to_string());
                }
                index += 1;
                continue;
            }
            if let Some(open) = &mut code {
                open.push(line);
                index += 1;
                continue;
            }
            if let Some(quoted) = Self::blockquote_line(line) {
                if !paragraph.is_empty() {
                    flush(&mut blocks, &mut paragraph, &mut quote);
                }
                quote.push(quoted);
                index += 1;
                continue;
            }
            if !quote.is_empty() {
                flush(&mut blocks, &mut paragraph, &mut quote);
            }
            if let Some(table) = MarkdownTable::parse(&lines, &mut index) {
                flush(&mut blocks, &mut paragraph, &mut quote);
                blocks.push(Self::Table(table));
            } else if trimmed.is_empty() {
                flush(&mut blocks, &mut paragraph, &mut quote);
            } else if paragraph.is_empty() && Self::is_thematic_break(line) {
                blocks.push(Self::ThematicBreak);
            } else if let Some(block) = Self::heading(trimmed).or_else(|| Self::list_item(line)) {
                flush(&mut blocks, &mut paragraph, &mut quote);
                blocks.push(block);
            } else {
                paragraph.push(line);
            }
            index += 1;
        }
        if let Some(open) = code {
            blocks.push(Self::Code {
                text: open.join("\n"),
                language,
            });
        }
        flush(&mut blocks, &mut paragraph, &mut quote);
        blocks
    }

    fn blockquote_line(line: &str) -> Option<String> {
        let spaces = line.bytes().take_while(|&b| b == b' ').count();
        if spaces > 3 {
            return None;
        }
        let rest = &line[spaces..];
        let after = rest.strip_prefix('>')?;
        if after.is_empty() {
            return Some(String::new());
        }
        after.strip_prefix(' ').map(ToOwned::to_owned)
    }

    fn is_thematic_break(line: &str) -> bool {
        let spaces = line.bytes().take_while(|&b| b == b' ').count();
        if spaces > 3 {
            return false;
        }
        let rest = &line[spaces..];
        let Some(marker) = rest.chars().next() else {
            return false;
        };
        if !matches!(marker, '-' | '*' | '_') {
            return false;
        }
        let mut count = 0usize;
        for ch in rest.chars() {
            if ch == marker {
                count += 1;
            } else if ch != ' ' && ch != '\t' {
                return false;
            }
        }
        count >= 3
    }

    fn heading(trimmed: &str) -> Option<Self> {
        let hashes = trimmed.bytes().take_while(|&b| b == b'#').count();
        if !(1..=6).contains(&hashes) {
            return None;
        }
        let text = trimmed[hashes..].strip_prefix(' ')?;
        Some(Self::Heading {
            level: hashes as u8,
            text: text.to_string(),
        })
    }

    fn list_item(line: &str) -> Option<Self> {
        let spaces = line.bytes().take_while(|&b| b == b' ').count();
        let indent = spaces / 2;
        let body = &line[spaces..];
        for bullet in ["- ", "* ", "+ "] {
            if let Some(rest) = body.strip_prefix(bullet) {
                return Some(Self::ListItem {
                    marker: "\u{2022}".to_string(),
                    text: rest.to_string(),
                    indent,
                });
            }
        }
        let digits: String = body.chars().take_while(char::is_ascii_digit).collect();
        if !digits.is_empty()
            && digits.len() <= 3
            && let Some(rest) = body[digits.len()..].strip_prefix(". ")
        {
            return Some(Self::ListItem {
                marker: format!("{digits}."),
                text: rest.to_string(),
                indent,
            });
        }
        None
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct InlineSpan {
    pub text: String,
    pub bold: bool,
    pub italic: bool,
    pub strikethrough: bool,
    pub code: bool,
    pub link: Option<String>,
    pub image: Option<MarkdownImageReference>,
}

/// Parses inline Markdown with `pulldown-cmark`, normalizing absolute file links to `file:///...`.
pub fn parse_inline_spans(source: &str) -> Vec<InlineSpan> {
    let mut opts = Options::empty();
    opts.insert(Options::ENABLE_STRIKETHROUGH);
    let parser = Parser::new_ext(source, opts);

    let mut out: Vec<InlineSpan> = Vec::new();
    let mut bold = 0usize;
    let mut italic = 0usize;
    let mut strike = 0usize;
    let mut link_stack: Vec<String> = Vec::new();
    let mut image_stack: Vec<(String, String)> = Vec::new();

    for ev in parser {
        match ev {
            Event::Start(Tag::Strong) => bold += 1,
            Event::End(TagEnd::Strong) => bold = bold.saturating_sub(1),
            Event::Start(Tag::Emphasis) => italic += 1,
            Event::End(TagEnd::Emphasis) => italic = italic.saturating_sub(1),
            Event::Start(Tag::Strikethrough) => strike += 1,
            Event::End(TagEnd::Strikethrough) => strike = strike.saturating_sub(1),
            Event::Start(Tag::Link { dest_url, .. }) => {
                link_stack.push(normalize_link(&dest_url));
            }
            Event::End(TagEnd::Link) => {
                link_stack.pop();
            }
            Event::Start(Tag::Image { dest_url, .. }) => {
                image_stack.push((dest_url.into_string(), String::new()));
            }
            Event::End(TagEnd::Image) => {
                if let Some((url, alt)) = image_stack.pop() {
                    out.push(InlineSpan {
                        text: alt.clone(),
                        bold: false,
                        italic: false,
                        strikethrough: false,
                        code: false,
                        link: None,
                        image: Some(MarkdownImageReference { url, alt }),
                    });
                }
            }
            Event::Code(code_str) => {
                if let Some((_, alt)) = image_stack.last_mut() {
                    alt.push_str(&code_str);
                } else {
                    out.push(InlineSpan {
                        text: code_str.into_string(),
                        bold: bold > 0,
                        italic: italic > 0,
                        strikethrough: strike > 0,
                        code: true,
                        link: link_stack.last().cloned(),
                        image: None,
                    });
                }
            }
            Event::Text(t) => {
                if let Some((_, alt)) = image_stack.last_mut() {
                    alt.push_str(&t);
                } else {
                    out.push(InlineSpan {
                        text: t.into_string(),
                        bold: bold > 0,
                        italic: italic > 0,
                        strikethrough: strike > 0,
                        code: false,
                        link: link_stack.last().cloned(),
                        image: None,
                    });
                }
            }
            Event::SoftBreak | Event::HardBreak if image_stack.is_empty() => {
                out.push(InlineSpan {
                    text: "\n".to_string(),
                    bold: bold > 0,
                    italic: italic > 0,
                    strikethrough: strike > 0,
                    code: false,
                    link: link_stack.last().cloned(),
                    image: None,
                });
            }
            _ => {}
        }
    }
    out
}

pub fn strip_inline_markdown(source: &str) -> String {
    parse_inline_spans(source).into_iter().map(|s| s.text).collect()
}

fn normalize_link(url: &str) -> String {
    if url.starts_with('/') && !url.starts_with("//") {
        format!("file://{url}")
    } else {
        url.to_string()
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MarkdownImageReference {
    pub url: String,
    pub alt: String,
}

impl MarkdownImageReference {
    pub fn references_in_source(source: &str) -> Vec<Self> {
        parse_inline_spans(source)
            .into_iter()
            .filter_map(|s| s.image)
            .collect()
    }

    pub fn references_in_blocks(blocks: &[MarkdownBlock]) -> Vec<Self> {
        let mut out = Vec::new();
        for block in blocks {
            match block {
                MarkdownBlock::Paragraph(t)
                | MarkdownBlock::Heading { text: t, .. }
                | MarkdownBlock::ListItem { text: t, .. } => {
                    out.extend(Self::references_in_source(t));
                }
                MarkdownBlock::Table(table) => {
                    for cell in table.headers.iter().chain(table.rows.iter().flatten()) {
                        out.extend(Self::references_in_source(cell));
                    }
                }
                MarkdownBlock::Blockquote(text) => {
                    out.extend(Self::references_in_blocks(&MarkdownBlock::parse(text)));
                }
                MarkdownBlock::Code { .. } | MarkdownBlock::ThematicBreak => {}
            }
        }
        out
    }
}
