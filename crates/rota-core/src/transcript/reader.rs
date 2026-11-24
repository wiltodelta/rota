use std::collections::{HashMap, HashSet};
use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::sync::Mutex;

use rota_platform::system_uptime_seconds;

use crate::diagnostics::PerformanceDiagnostics;
use crate::model::{Harness, RunOutcome, RunRecord};
use crate::transcript::{
    JournalError, JournalPage, SessionPreview, Transcript, TranscriptItem, TranscriptItemKind,
    TranscriptOrder, TranscriptRecord, TranscriptSnapshot,
};

/// Incrementally replays `<log>.chat.jsonl` with optional reverse-chunk paging and 1-poll settle grace.
pub struct TranscriptReader {
    offset: u64,
    pending: Vec<u8>,
    items: Vec<TranscriptItem>,
    indices: HashMap<usize, usize>,
    header_seen: bool,
    log_size: u64,
    failure: Option<String>,
    page_size: Option<usize>,
    settle_writes: bool,
    earlier_offset: u64,
    header_end: u64,
    last_good: Option<TranscriptSnapshot>,
    unsettled_reads: usize,
    source_ids: HashSet<String>,
    collects_source_ids: bool,
    bytes_read: usize,
}

impl Default for TranscriptReader {
    fn default() -> Self {
        Self::new(None, false)
    }
}

impl TranscriptReader {
    pub fn new(page_size: Option<usize>, settle_writes: bool) -> Self {
        Self {
            offset: 0,
            pending: Vec::new(),
            items: Vec::new(),
            indices: HashMap::new(),
            header_seen: false,
            log_size: 0,
            failure: None,
            page_size: page_size.map(|n| n.max(1)),
            settle_writes,
            earlier_offset: 0,
            header_end: 0,
            last_good: None,
            unsettled_reads: 0,
            source_ids: HashSet::new(),
            collects_source_ids: false,
            bytes_read: 0,
        }
    }

    pub(crate) fn with_recovery() -> Self {
        let mut r = Self::new(None, false);
        r.collects_source_ids = true;
        r
    }

    pub fn journal_path(log: &Path) -> PathBuf {
        let mut s = log.as_os_str().to_os_string();
        s.push(".chat.jsonl");
        PathBuf::from(s)
    }

    pub fn bytes_read(&self) -> usize {
        self.bytes_read
    }

    pub fn can_append(&self) -> bool {
        self.failure.is_none() && self.header_seen && self.pending.is_empty()
    }

    pub fn next_id(&self) -> usize {
        self.items.iter().map(|i| i.id + 1).max().unwrap_or(0)
    }

    pub fn source_ids(&self) -> &HashSet<String> {
        &self.source_ids
    }

    pub fn read(&mut self, log: &Path, shell: bool, finished: bool) -> TranscriptSnapshot {
        let url = Self::journal_path(log);
        if shell || !url.exists() {
            return Self::legacy(log, shell, None);
        }
        let res = (|| -> Result<TranscriptSnapshot, JournalError> {
            if self.offset == 0
                && let Some(ps) = self.page_size
            {
                self.open_tail(&url, ps)?;
            }
            self.replay(&url)?;
            let actual_size = std::fs::metadata(log).map(|m| m.len()).ok();
            let presented: Vec<TranscriptItem> = self.items.iter().map(TranscriptItem::presented).collect();
            let ordered = TranscriptOrder::align_same_step_reasoning(&presented);
            let candidate = TranscriptSnapshot {
                items: ordered,
                structured: true,
                problem: None,
                has_earlier: self.earlier_offset > 0,
            };
            let ok = self.failure.is_none()
                && self.header_seen
                && actual_size == Some(self.log_size)
                && (!finished || self.pending.is_empty());
            if !ok {
                self.unsettled_reads += 1;
                if self.settle_writes && !finished && self.failure.is_none() && self.unsettled_reads == 1 {
                    return Ok(self.last_good.clone().unwrap_or(candidate));
                }
                let problem = self
                    .failure
                    .clone()
                    .unwrap_or_else(|| "Chat history is incomplete. Open the log for details.".to_string());
                return Ok(Self::legacy(log, shell, Some(problem)));
            }
            self.unsettled_reads = 0;
            self.last_good = Some(candidate.clone());
            Ok(candidate)
        })();

        match res {
            Ok(snap) => snap,
            Err(_) => Self::legacy(
                log,
                shell,
                Some("Couldn't read chat history. Open the log for details.".to_string()),
            ),
        }
    }

    pub fn read_earlier(&mut self, log: &Path, finished: bool) -> TranscriptSnapshot {
        let (true, Some(page_size), true) = (self.earlier_offset > 0, self.page_size, self.failure.is_none())
        else {
            return self.read(log, false, finished);
        };
        let url = Self::journal_path(log);
        let res = (|| -> Result<(), JournalError> {
            let page = JournalPage::read(&url, self.earlier_offset, page_size, false)?;
            self.bytes_read += page.bytes_read;
            let mut older = Self::new(None, false);
            older.header_seen = true;
            for rec in page.records {
                if rec.record_type != "header" {
                    older.apply(rec)?;
                }
            }
            if older.items.iter().any(|i| self.indices.contains_key(&i.id)) {
                return Err(JournalError::Unsupported);
            }
            let prepended = older.items.clone();
            older.items.append(&mut self.items);
            self.items = older.items;
            self.indices = self
                .items
                .iter()
                .enumerate()
                .map(|(idx, item)| (item.id, idx))
                .collect();
            self.earlier_offset = if page.start > self.header_end {
                page.start
            } else {
                0
            };
            if let Some(good) = &mut self.last_good {
                let mut combined = prepended;
                combined.append(&mut good.items);
                good.items = combined;
                good.has_earlier = self.earlier_offset > 0;
            }
            Ok(())
        })();
        if res.is_err() {
            self.failure =
                Some("Chat history is incomplete or unsupported. Open the log for details.".into());
        }
        self.read(log, false, finished)
    }

    fn replay(&mut self, url: &Path) -> Result<(), JournalError> {
        let mut file = File::open(url).map_err(|_| JournalError::Io)?;
        let size = file.seek(SeekFrom::End(0)).map_err(|_| JournalError::Io)?;
        if size < self.offset {
            let ps = self.page_size;
            let sw = self.settle_writes;
            *self = Self::new(ps, sw);
            if let Some(count) = ps {
                self.open_tail(url, count)?;
            }
        }
        file.seek(SeekFrom::Start(self.offset))
            .map_err(|_| JournalError::Io)?;
        let mut data = Vec::new();
        file.read_to_end(&mut data).map_err(|_| JournalError::Io)?;
        self.bytes_read += data.len();
        self.offset += data.len() as u64;
        self.pending.extend_from_slice(&data);
        while let Some(nl) = self.pending.iter().position(|&b| b == b'\n') {
            let line: Vec<u8> = self.pending.drain(..=nl).take(nl).collect();
            match serde_json::from_slice::<TranscriptRecord>(&line)
                .map_err(|_| JournalError::Unsupported)
                .and_then(|rec| self.apply(rec))
            {
                Ok(()) => {}
                Err(_) => {
                    self.failure =
                        Some("Chat history is incomplete or unsupported. Open the log for details.".into());
                }
            }
        }
        Ok(())
    }

    fn open_tail(&mut self, url: &Path, count: usize) -> Result<(), JournalError> {
        let mut file = File::open(url).map_err(|_| JournalError::Io)?;
        let mut first = Vec::new();
        let mut chunk = [0u8; 4096];
        while !first.contains(&b'\n') {
            let n = file.read(&mut chunk).map_err(|_| JournalError::Io)?;
            if n == 0 {
                break;
            }
            self.bytes_read += n;
            first.extend_from_slice(&chunk[..n]);
        }
        let Some(nl) = first.iter().position(|&b| b == b'\n') else {
            self.offset = first.len() as u64;
            self.pending = first;
            return Ok(());
        };
        let header: TranscriptRecord =
            serde_json::from_slice(&first[..nl]).map_err(|_| JournalError::Unsupported)?;
        if header.record_type != "header" {
            return Err(JournalError::Unsupported);
        }
        self.apply(header)?;
        self.header_end = (nl as u64) + 1;
        let size = file.seek(SeekFrom::End(0)).map_err(|_| JournalError::Io)?;
        let page = JournalPage::read(url, size, count, true)?;
        self.bytes_read += page.bytes_read;
        for rec in page.records {
            if rec.record_type != "header" {
                self.apply(rec)?;
            }
        }
        self.earlier_offset = if page.start > self.header_end {
            page.start
        } else {
            0
        };
        self.offset = size;
        self.pending = page.partial;
        Ok(())
    }

    fn apply(&mut self, record: TranscriptRecord) -> Result<(), JournalError> {
        if record.version != 1 {
            return Err(JournalError::Unsupported);
        }
        if self.collects_source_ids
            && let Some(src) = &record.source_id
        {
            self.source_ids.insert(src.clone());
        }
        if record.record_type == "header" {
            if self.header_seen {
                return Err(JournalError::Unsupported);
            }
            self.header_seen = true;
        } else {
            if !self.header_seen {
                return Err(JournalError::Unsupported);
            }
            match record.record_type.as_str() {
                "item" => self.insert(
                    record.id,
                    record.kind,
                    record.text,
                    record.complete,
                    record.native_id,
                )?,
                "append" => self.update_append(record.id, record.text)?,
                "complete" => self.update_complete(record.id)?,
                _ => {
                    if record.required != Some(false) {
                        return Err(JournalError::Unsupported);
                    }
                }
            }
        }
        self.log_size = record.log_size;
        Ok(())
    }

    fn insert(
        &mut self,
        raw_id: Option<isize>,
        kind: Option<String>,
        text: Option<String>,
        complete: Option<bool>,
        native_id: Option<String>,
    ) -> Result<(), JournalError> {
        let id_signed = raw_id.ok_or(JournalError::Unsupported)?;
        if id_signed < 0 {
            return Err(JournalError::Unsupported);
        }
        let id = id_signed as usize;
        if self.indices.contains_key(&id) {
            return Err(JournalError::Unsupported);
        }
        let kind_str = kind.ok_or(JournalError::Unsupported)?;
        let body = text.ok_or(JournalError::Unsupported)?;
        self.indices.insert(id, self.items.len());
        self.items.push(TranscriptItem {
            id,
            kind: TranscriptItemKind::parse(&kind_str).unwrap_or(TranscriptItemKind::Status),
            text: body,
            is_complete: complete.unwrap_or(true),
            native_id,
        });
        Ok(())
    }

    fn update_append(&mut self, raw_id: Option<isize>, chunk: Option<String>) -> Result<(), JournalError> {
        let id = usize::try_from(raw_id.ok_or(JournalError::Unsupported)?)
            .map_err(|_| JournalError::Unsupported)?;
        let idx = *self.indices.get(&id).ok_or(JournalError::Unsupported)?;
        if self.items[idx].is_complete {
            return Err(JournalError::Unsupported);
        }
        let text = chunk.ok_or(JournalError::Unsupported)?;
        self.items[idx].text.push_str(&text);
        Ok(())
    }

    fn update_complete(&mut self, raw_id: Option<isize>) -> Result<(), JournalError> {
        let id = usize::try_from(raw_id.ok_or(JournalError::Unsupported)?)
            .map_err(|_| JournalError::Unsupported)?;
        let idx = *self.indices.get(&id).ok_or(JournalError::Unsupported)?;
        if self.items[idx].is_complete {
            return Err(JournalError::Unsupported);
        }
        self.items[idx].is_complete = true;
        Ok(())
    }

    fn legacy(log: &Path, shell: bool, problem: Option<String>) -> TranscriptSnapshot {
        let Ok(mut file) = File::open(log) else {
            return TranscriptSnapshot {
                items: Vec::new(),
                structured: false,
                problem: Some(problem.unwrap_or_else(|| "Couldn't read the session log.".to_string())),
                has_earlier: false,
            };
        };
        let size = file.seek(SeekFrom::End(0)).unwrap_or(0);
        let _ = file.seek(SeekFrom::Start(size.saturating_sub(400_000)));
        let mut buf = Vec::new();
        let _ = file.read_to_end(&mut buf);
        let text = String::from_utf8_lossy(&buf);
        TranscriptSnapshot {
            items: Transcript::parse(&text, shell),
            structured: false,
            problem,
            has_earlier: false,
        }
    }
}

/// Thread-safe session transcript reader with 50-item default paging and diagnostics recording.
pub struct TranscriptSessionReader {
    inner: Mutex<TranscriptReader>,
}

impl Default for TranscriptSessionReader {
    fn default() -> Self {
        Self::new()
    }
}

impl TranscriptSessionReader {
    pub fn new() -> Self {
        Self {
            inner: Mutex::new(TranscriptReader::new(Some(50), true)),
        }
    }

    pub fn read(&self, log: &Path, shell: bool, finished: bool, earlier: bool) -> TranscriptSnapshot {
        let started = system_uptime_seconds();
        let mut guard = self.inner.lock().unwrap();
        let snapshot = if earlier && !shell {
            guard.read_earlier(log, finished)
        } else {
            guard.read(log, shell, finished)
        };
        drop(guard);
        PerformanceDiagnostics::shared().record_transcript(
            system_uptime_seconds() - started,
            snapshot.items.len(),
            earlier,
            shell,
        );
        snapshot
    }

    pub fn preview_once(&self, record: &RunRecord) -> String {
        let snapshot = if !record.is_skip()
            && let Some(path) = &record.log_path
        {
            Some(self.read(
                Path::new(path),
                record.harness == Harness::Shell,
                record.outcome != RunOutcome::Running,
                false,
            ))
        } else {
            None
        };
        SessionPreview::text(record, snapshot.as_ref())
    }
}
