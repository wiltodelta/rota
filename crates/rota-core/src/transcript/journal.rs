use std::collections::{HashMap, HashSet};
use std::fs::{File, OpenOptions};
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::Path;

use serde::{Deserialize, Serialize};

use crate::transcript::{TranscriptItem, TranscriptItemKind, TranscriptReader};

fn default_version() -> u32 {
    1
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TranscriptRecord {
    #[serde(default = "default_version")]
    pub version: u32,
    #[serde(rename = "type")]
    pub record_type: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub required: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub id: Option<isize>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub kind: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub text: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub complete: Option<bool>,
    pub log_size: u64,
    #[serde(default, rename = "sourceID", skip_serializing_if = "Option::is_none")]
    pub source_id: Option<String>,
    #[serde(default, rename = "nativeID", skip_serializing_if = "Option::is_none")]
    pub native_id: Option<String>,
}

impl TranscriptRecord {
    pub fn header(log_size: u64) -> Self {
        Self {
            version: 1,
            record_type: "header".to_string(),
            required: None,
            id: None,
            kind: None,
            text: None,
            complete: None,
            log_size,
            source_id: None,
            native_id: None,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct TranscriptSnapshot {
    pub items: Vec<TranscriptItem>,
    pub structured: bool,
    pub problem: Option<String>,
    pub has_earlier: bool,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum JournalError {
    Unsupported,
    Io,
}

#[derive(Debug)]
pub struct JournalPage {
    pub records: Vec<TranscriptRecord>,
    pub start: u64,
    pub partial: Vec<u8>,
    pub bytes_read: usize,
}

impl JournalPage {
    pub fn read(path: &Path, before: u64, count: usize, allow_partial: bool) -> Result<Self, JournalError> {
        let file = File::open(path).map_err(|_| JournalError::Io)?;
        let mut cursor = ReverseLines::new(file, before);
        let mut records = Vec::new();
        let mut partial = Vec::new();
        let mut start = 0u64;
        let mut remaining = count as isize;
        let mut first = true;

        while let Some((line_offset, line_data)) = cursor.previous()? {
            if first {
                first = false;
                if line_data.is_empty() {
                    continue;
                }
                if !allow_partial {
                    return Err(JournalError::Unsupported);
                }
                partial = line_data;
                continue;
            }
            let record: TranscriptRecord =
                serde_json::from_slice(&line_data).map_err(|_| JournalError::Unsupported)?;
            if record.version != 1 {
                return Err(JournalError::Unsupported);
            }
            let is_header = record.record_type == "header";
            let is_item = record.record_type == "item";
            let kind = record.kind.as_deref().and_then(TranscriptItemKind::parse);
            records.push(record);
            if is_header {
                if line_offset != 0 {
                    return Err(JournalError::Unsupported);
                }
                break;
            }
            if is_item {
                remaining -= 1;
                if remaining <= 0 && !kind.is_some_and(TranscriptItemKind::can_join_tool_group) {
                    start = line_offset;
                    break;
                }
            }
        }
        records.reverse();
        Ok(Self {
            records,
            start,
            partial,
            bytes_read: cursor.bytes_read,
        })
    }
}

struct ReverseLines {
    file: File,
    offset: u64,
    buffer: Vec<u8>,
    bytes_read: usize,
    exhausted: bool,
}

impl ReverseLines {
    const CHUNK: u64 = 32_768;

    fn new(file: File, offset: u64) -> Self {
        Self {
            file,
            offset,
            buffer: Vec::new(),
            bytes_read: 0,
            exhausted: false,
        }
    }

    fn previous(&mut self) -> Result<Option<(u64, Vec<u8>)>, JournalError> {
        if self.exhausted {
            return Ok(None);
        }
        loop {
            if let Some(nl_pos) = self.buffer.iter().rposition(|&b| b == b'\n') {
                let tail = self.buffer[nl_pos + 1..].to_vec();
                let line_start = self.offset + (nl_pos as u64) + 1;
                self.buffer.truncate(nl_pos);
                return Ok(Some((line_start, tail)));
            }
            if self.offset == 0 {
                self.exhausted = true;
                if self.buffer.is_empty() {
                    return Ok(None);
                }
                let data = std::mem::take(&mut self.buffer);
                return Ok(Some((0, data)));
            }
            let size = self.offset.min(Self::CHUNK);
            self.offset -= size;
            self.file
                .seek(SeekFrom::Start(self.offset))
                .map_err(|_| JournalError::Io)?;
            let mut chunk = vec![0u8; size as usize];
            self.file
                .read_exact(&mut chunk)
                .map_err(|_| JournalError::Unsupported)?;
            self.bytes_read += chunk.len();
            chunk.append(&mut self.buffer);
            self.buffer = chunk;
        }
    }
}

/// Normalized sidecar writer (`<log>.chat.jsonl`), owned under `RunJournal`'s lock.
pub struct TranscriptJournal {
    file: File,
    pub next_id: usize,
    pub source_ids: HashSet<String>,
    pub unfinished: Option<TranscriptItem>,
    pub native_items: HashMap<String, String>,
}

impl TranscriptJournal {
    pub fn open(log: &Path, resuming: bool, log_size: u64) -> Result<Self, JournalError> {
        let url = TranscriptReader::journal_path(log);
        let (next_id, source_ids, unfinished, native_items) = if resuming {
            let mut reader = TranscriptReader::with_recovery();
            let snapshot = reader.read(log, false, false);
            if !snapshot.structured || !reader.can_append() {
                return Err(JournalError::Unsupported);
            }
            let mut native = HashMap::new();
            for item in &snapshot.items {
                if let Some(id) = &item.native_id {
                    native.insert(id.clone(), item.text.clone());
                }
            }
            let unfin = snapshot.items.last().filter(|i| !i.is_complete).cloned();
            (reader.next_id(), reader.source_ids().clone(), unfin, native)
        } else {
            File::create(&url).map_err(|_| JournalError::Io)?;
            (0, HashSet::new(), None, HashMap::new())
        };

        let mut file = OpenOptions::new()
            .create(true)
            .append(true)
            .open(&url)
            .map_err(|_| JournalError::Io)?;
        file.seek(SeekFrom::End(0)).map_err(|_| JournalError::Io)?;

        let mut journal = Self {
            file,
            next_id,
            source_ids,
            unfinished,
            native_items,
        };
        if !resuming {
            journal.append(&TranscriptRecord::header(log_size))?;
        }
        Ok(journal)
    }

    pub fn append(&mut self, record: &TranscriptRecord) -> Result<(), JournalError> {
        let mut line = serde_json::to_vec(record).map_err(|_| JournalError::Unsupported)?;
        line.push(b'\n');
        self.file.write_all(&line).map_err(|_| JournalError::Io)?;
        Ok(())
    }

    pub fn allocate_id(&mut self) -> usize {
        let id = self.next_id;
        self.next_id += 1;
        id
    }
}
