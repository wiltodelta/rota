use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};

use jiff::Timestamp;
use rota_platform::home_dir;
use serde_json::Value;

use crate::model::serde_ext::parse_iso_timestamp;
use crate::model::{Harness, SessionConfiguration, TerminalState};
use crate::runners::{AntigravityQuestionArchive, AntigravityTranscript, ClaudeInteractiveRun};
use crate::transcript::TranscriptItemKind;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum NativeTranscriptEvent {
    Item(TranscriptItemKind, String),
    Chunk {
        text: String,
        kind: TranscriptItemKind,
        native_id: Option<String>,
    },
    Configuration(SessionConfiguration),
    State(TerminalState),
}

pub struct NativeTranscript {
    pub url: PathBuf,
    pub since: Option<Timestamp>,
    home: PathBuf,
    awaiting_expansion: bool,
    pub harness: Harness,
    offset: u64,
    partial: Vec<u8>,
    antigravity_decoder: AntigravityTranscript,
    primed: bool,
}

impl NativeTranscript {
    pub fn open(
        url: PathBuf,
        harness: Harness,
        offset: Option<u64>,
        since: Option<Timestamp>,
        home: PathBuf,
    ) -> Result<Self, String> {
        let awaiting_expansion =
            harness == Harness::Codex && url.extension().and_then(|e| e.to_str()) == Some("zst");
        let resolved_since = since.or_else(|| awaiting_expansion.then(Timestamp::now));
        let mut file = File::open(&url).map_err(|e| e.to_string())?;
        let end = if awaiting_expansion {
            0
        } else {
            file.seek(SeekFrom::End(0)).map_err(|e| e.to_string())?
        };
        Ok(Self {
            url,
            since: resolved_since,
            home,
            awaiting_expansion,
            harness,
            offset: offset.unwrap_or(end),
            partial: Vec::new(),
            antigravity_decoder: AntigravityTranscript::default(),
            primed: false,
        })
    }

    pub fn checkpoint(&self) -> u64 {
        self.offset.saturating_sub(self.partial.len() as u64)
    }

    fn remember_antigravity(&mut self, file: &mut File, end: u64) -> Result<(), String> {
        file.seek(SeekFrom::Start(0)).map_err(|e| e.to_string())?;
        let mut remaining = end;
        let mut pending = Vec::new();
        while remaining > 0 {
            let chunk_len = (remaining as usize).min(65_536);
            let mut buf = vec![0u8; chunk_len];
            let n = file.read(&mut buf).map_err(|e| e.to_string())?;
            if n == 0 {
                break;
            }
            remaining -= n as u64;
            pending.extend_from_slice(&buf[..n]);
            while let Some(nl) = pending.iter().position(|&b| b == b'\n') {
                let row: Vec<u8> = pending.drain(..=nl).take(nl).collect();
                if !row.is_empty()
                    && let Ok(val) = serde_json::from_slice::<Value>(&row)
                {
                    let _ = self.antigravity_decoder.read(&val);
                }
            }
        }
        Ok(())
    }

    pub fn read_with<F>(&mut self, mut receive: F) -> Result<(), String>
    where
        F: FnMut(Vec<NativeTranscriptEvent>, String),
    {
        if self.awaiting_expansion {
            let expanded = self.url.with_extension("");
            let stem = expanded
                .with_extension("")
                .file_name()
                .and_then(|n| n.to_str())
                .unwrap_or("")
                .to_string();
            let session: String = stem
                .chars()
                .rev()
                .take(36)
                .collect::<Vec<_>>()
                .into_iter()
                .rev()
                .collect();
            let source = if expanded.exists() {
                Some(expanded)
            } else {
                Self::locate_in(Harness::Codex, &session, &self.home, false)
            };
            let Some(src) = source else {
                return Ok(());
            };
            self.url = src;
            self.awaiting_expansion = false;
        }
        if self.harness == Harness::Codex && !self.url.exists() {
            let stem = self
                .url
                .with_extension("")
                .file_name()
                .and_then(|n| n.to_str())
                .unwrap_or("")
                .to_string();
            let session: String = stem
                .chars()
                .rev()
                .take(36)
                .collect::<Vec<_>>()
                .into_iter()
                .rev()
                .collect();
            if let Some(moved) = Self::locate_in(Harness::Codex, &session, &self.home, false) {
                self.url = moved;
            }
        }
        let mut file = File::open(&self.url).map_err(|e| e.to_string())?;
        if self.harness == Harness::Antigravity && !self.primed {
            self.remember_antigravity(&mut file, self.offset)?;
            self.primed = true;
        }
        let end = file.seek(SeekFrom::End(0)).map_err(|e| e.to_string())?;
        if end < self.offset {
            return Err("Corrupt native transcript".into());
        }
        file.seek(SeekFrom::Start(self.offset))
            .map_err(|e| e.to_string())?;
        let file_name = self
            .url
            .file_name()
            .and_then(|n| n.to_str())
            .unwrap_or("transcript")
            .to_string();
        let mut buf = [0u8; 65_536];
        loop {
            let n = file.read(&mut buf).map_err(|e| e.to_string())?;
            if n == 0 {
                break;
            }
            self.offset += n as u64;
            self.partial.extend_from_slice(&buf[..n]);
            while let Some(nl) = self.partial.iter().position(|&b| b == b'\n') {
                let start = self.offset - (self.partial.len() as u64);
                let line: Vec<u8> = self.partial.drain(..=nl).take(nl).collect();
                if !line.is_empty() {
                    let decoded = self.decode_line(&line)?;
                    receive(decoded, format!("{file_name}/{start}"));
                }
            }
        }
        Ok(())
    }

    pub fn read(&mut self) -> Result<Vec<NativeTranscriptEvent>, String> {
        let mut out = Vec::new();
        self.read_with(|evs, _| out.extend(evs))?;
        Ok(out)
    }

    fn decode_line(&mut self, data: &[u8]) -> Result<Vec<NativeTranscriptEvent>, String> {
        if self.harness == Harness::Codex
            && let Some(since) = self.since
        {
            let row: Value = serde_json::from_slice(data).map_err(|e| e.to_string())?;
            let Some(stamp) = row.get("timestamp").and_then(Value::as_str) else {
                return Ok(Vec::new());
            };
            let Some(ts) = parse_iso_timestamp(stamp) else {
                return Ok(Vec::new());
            };
            if ts < since {
                return Ok(Vec::new());
            }
            return Ok(Self::codex(&row));
        }
        if self.harness == Harness::Antigravity {
            let row: Value = serde_json::from_slice(data).map_err(|e| e.to_string())?;
            return Ok(self.antigravity_decoder.read(&row));
        }
        Self::events(data, self.harness)
    }

    pub fn locate(harness: Harness, session: &str) -> Option<PathBuf> {
        Self::locate_in(harness, session, &home_dir(), true)
    }

    pub fn locate_in(
        harness: Harness,
        session: &str,
        home: &Path,
        include_compressed: bool,
    ) -> Option<PathBuf> {
        match harness {
            Harness::Claude => {
                ClaudeInteractiveRun::transcript_file_in(session, &home.join(".claude/projects"))
            }
            Harness::Antigravity => AntigravityQuestionArchive::open(session, home, false).map(|a| a.file),
            Harness::Codex => {
                let mut compressed = None;
                for rel in [".codex/sessions", ".codex/archived_sessions"] {
                    if let Some(hit) = Self::walk_store(
                        &home.join(rel),
                        Harness::Codex,
                        session,
                        include_compressed,
                        &mut compressed,
                    ) {
                        return Some(hit);
                    }
                }
                compressed
            }
            Harness::Grok => {
                let mut unused = None;
                Self::walk_store(
                    &home.join(".grok/sessions"),
                    Harness::Grok,
                    session,
                    false,
                    &mut unused,
                )
            }
            Harness::Shell => None,
        }
    }

    fn walk_store(
        dir: &Path,
        harness: Harness,
        session: &str,
        include_compressed: bool,
        compressed: &mut Option<PathBuf>,
    ) -> Option<PathBuf> {
        let entries = std::fs::read_dir(dir).ok()?;
        for entry in entries.flatten() {
            let path = entry.path();
            let name = path.file_name().and_then(|n| n.to_str()).unwrap_or("");
            if name.starts_with('.') {
                continue;
            }
            if path.is_dir() {
                if let Some(hit) = Self::walk_store(&path, harness, session, include_compressed, compressed) {
                    return Some(hit);
                }
            } else if harness == Harness::Codex {
                if name.ends_with(&format!("-{session}.jsonl")) {
                    return Some(path);
                }
                if include_compressed && name.ends_with(&format!("-{session}.jsonl.zst")) {
                    *compressed = Some(path);
                }
            } else if name == "updates.jsonl"
                && path.parent().and_then(|p| p.file_name()).and_then(|n| n.to_str()) == Some(session)
            {
                return Some(path);
            }
        }
        None
    }

    pub fn grok_directory(source: &Path) -> Option<String> {
        let group = source.parent()?.parent()?;
        if let Ok(recorded) = std::fs::read_to_string(group.join(".cwd")) {
            let trimmed = recorded.trim();
            if trimmed.starts_with('/') {
                return Some(trimmed.to_string());
            }
        }
        let name = group.file_name()?.to_str()?;
        let decoded = crate::storage::attachments::percent_decode(name);
        decoded.starts_with('/').then_some(decoded)
    }
}
