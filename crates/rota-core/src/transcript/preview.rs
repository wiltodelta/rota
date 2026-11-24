use crate::model::{Harness, RunOutcome, RunRecord};
use crate::transcript::{
    MarkdownAlert, MarkdownBlock, TranscriptItemKind, TranscriptSnapshot, strip_inline_markdown,
};

pub struct SessionPreview;

impl SessionPreview {
    pub fn text(record: &RunRecord, snapshot: Option<&TranscriptSnapshot>) -> String {
        if let Some(question) = record.next_question() {
            let candidate = std::iter::once(question.detail.as_str())
                .chain(question.fields.iter().map(|f| f.title.as_str()))
                .chain(std::iter::once(question.title.as_str()))
                .find(|s| !s.trim().is_empty())
                .unwrap_or(&question.title);
            return Self::plain(candidate);
        }
        if let Some(attention) = &record.attention {
            return Self::plain(attention);
        }
        match &record.outcome {
            RunOutcome::LaunchFailed(reason) | RunOutcome::Skipped(reason) => {
                return Self::plain(reason);
            }
            _ => {}
        }
        let Some(snapshot) = snapshot else {
            return if record.log_path.is_none() {
                Self::empty(record)
            } else {
                "Loading last message\u{2026}".to_string()
            };
        };
        if record.outcome.is_failure()
            && let Some(err) = snapshot
                .items
                .iter()
                .rfind(|i| i.kind == TranscriptItemKind::Error && !i.text.is_empty())
        {
            return Self::plain(&err.text);
        }
        if let Some(item) = snapshot.items.iter().rfind(|i| {
            (i.kind == TranscriptItemKind::Agent
                || (i.kind == TranscriptItemKind::Output && record.harness == Harness::Shell)
                || i.kind == TranscriptItemKind::Error)
                && !i.text.trim().is_empty()
        }) {
            return Self::plain(Self::excerpt(&item.text));
        }
        if snapshot.problem.is_some() {
            return "Couldn't read the last message. Open the session for details.".to_string();
        }
        Self::empty(record)
    }

    fn empty(record: &RunRecord) -> String {
        if record.outcome == RunOutcome::Running {
            "Waiting for the first message\u{2026}".to_string()
        } else if record.harness == Harness::Shell {
            "No command output.".to_string()
        } else {
            "No agent message.".to_string()
        }
    }

    fn excerpt(text: &str) -> &str {
        let trimmed = text.trim();
        let Some((head, rest)) = trimmed.split_once("\n\n") else {
            return text;
        };
        if !strip_inline_markdown(head).starts_with("pre-commit:") {
            return text;
        }
        let rest_trimmed = rest.trim();
        if rest_trimmed.is_empty() {
            text
        } else {
            rest_trimmed
        }
    }

    fn plain(text: &str) -> String {
        let prefix: String = text.chars().take(2000).collect();
        let extracted = Self::extract_blocks(&MarkdownBlock::parse(&prefix));
        let stripped = strip_inline_markdown(&extracted);
        let collapsed = stripped.split_whitespace().collect::<Vec<_>>().join(" ");
        collapsed.chars().take(320).collect()
    }

    fn extract_blocks(blocks: &[MarkdownBlock]) -> String {
        blocks
            .iter()
            .map(|block| match block {
                MarkdownBlock::Heading { text, .. }
                | MarkdownBlock::ListItem { text, .. }
                | MarkdownBlock::Paragraph(text)
                | MarkdownBlock::Code { text, .. } => text.clone(),
                MarkdownBlock::Blockquote(text) => {
                    let (_, rest) = MarkdownAlert::extract(text);
                    Self::extract_blocks(&MarkdownBlock::parse(&rest))
                }
                MarkdownBlock::ThematicBreak => String::new(),
                MarkdownBlock::Table(table) => table
                    .headers
                    .iter()
                    .chain(table.rows.iter().flatten())
                    .cloned()
                    .collect::<Vec<_>>()
                    .join(" "),
            })
            .collect::<Vec<_>>()
            .join(" ")
    }
}
