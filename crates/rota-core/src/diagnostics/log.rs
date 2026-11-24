use std::collections::HashMap;
use std::fs::{File, OpenOptions};
use std::io::{Seek, SeekFrom, Write};
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};

use jiff::Timestamp;
use jiff::tz::TimeZone;
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value, json};

use crate::model::serde_ext::to_sorted_compact_string;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum PerformanceSurface {
    #[default]
    Background,
    Conversation,
    Routine,
    Calendar,
    Settings,
    Panel,
    Empty,
}

/// Fixed categories and numeric measurements recorded in the local performance journal.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct PerformanceContext {
    pub surface: PerformanceSurface,
    pub active_runs: usize,
    pub routine_count: usize,
    pub app_active: bool,
    pub window_width: f64,
    pub window_height: f64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub enum PerformanceEventKind {
    #[serde(rename = "launch")]
    Launch,
    #[serde(rename = "resources")]
    Resources,
    #[serde(rename = "sleep")]
    Sleep,
    #[serde(rename = "wake")]
    Wake,
    #[serde(rename = "shutdown")]
    Shutdown,
    #[serde(rename = "main_thread_stall")]
    MainThreadStall,
    #[serde(rename = "main_thread_delay")]
    MainThreadDelay,
    #[serde(rename = "slow_transcript")]
    SlowTranscript,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct TranscriptPerformance {
    pub reads: usize,
    pub earlier_reads: usize,
    pub shell_reads: usize,
    pub total_ms: f64,
    pub max_ms: f64,
    pub max_items: usize,
}

impl TranscriptPerformance {
    pub fn add(&mut self, seconds: f64, items: usize, earlier: bool, shell: bool) {
        self.reads += 1;
        if earlier {
            self.earlier_reads += 1;
        }
        if shell {
            self.shell_reads += 1;
        }
        let ms = (seconds * 1_000.0).max(0.0);
        self.total_ms += ms;
        self.max_ms = self.max_ms.max(ms);
        self.max_items = self.max_items.max(items);
    }
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PerformanceEvent {
    pub schema: u32,
    pub time: String,
    pub kind: PerformanceEventKind,
    pub uptime: f64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cpu_percent: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resident_bytes: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub duration_ms: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub context: Option<PerformanceContext>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub transcript: Option<TranscriptPerformance>,
}

impl PerformanceEvent {
    pub fn new(kind: PerformanceEventKind, uptime: f64) -> Self {
        Self {
            schema: 1,
            time: String::new(),
            kind,
            uptime,
            cpu_percent: None,
            resident_bytes: None,
            duration_ms: None,
            context: None,
            transcript: None,
        }
    }
}

pub fn format_local_iso(ts: Timestamp) -> String {
    let z = ts.to_zoned(TimeZone::system());
    let offset_secs = z.offset().seconds();
    if offset_secs == 0 {
        format!(
            "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z",
            z.year(),
            z.month(),
            z.day(),
            z.hour(),
            z.minute(),
            z.second()
        )
    } else {
        let sign = if offset_secs >= 0 { '+' } else { '-' };
        let abs = offset_secs.unsigned_abs();
        let oh = abs / 3600;
        let om = (abs % 3600) / 60;
        format!(
            "{:04}-{:02}-{:02}T{:02}:{:02}:{:02}{sign}{oh:02}:{om:02}",
            z.year(),
            z.month(),
            z.day(),
            z.hour(),
            z.minute(),
            z.second()
        )
    }
}

/// Bounded two-file JSONL journal (`current.jsonl` + `previous.jsonl`).
pub struct PerformanceLog {
    directory: PathBuf,
    byte_limit: usize,
    header: Vec<u8>,
    handle: Option<File>,
    size: usize,
}

impl PerformanceLog {
    pub const BYTE_LIMIT: usize = 2 * 1_024 * 1_024;

    pub fn new(
        directory: &Path,
        metadata: &HashMap<String, String>,
        byte_limit: usize,
    ) -> Result<Self, String> {
        let mut meta_obj = Map::new();
        for (k, v) in metadata {
            meta_obj.insert(k.clone(), Value::String(v.clone()));
        }
        meta_obj.insert("kind".to_string(), json!("launch"));
        meta_obj.insert("schema".to_string(), json!(1));
        meta_obj.insert("time".to_string(), json!(format_local_iso(Timestamp::now())));
        let mut header = to_sorted_compact_string(&Value::Object(meta_obj))
            .map_err(|e| e.to_string())?
            .into_bytes();
        header.push(b'\n');

        std::fs::create_dir_all(directory).map_err(|e| e.to_string())?;
        let _ = std::fs::set_permissions(directory, std::fs::Permissions::from_mode(0o700));

        let mut log = Self {
            directory: directory.to_path_buf(),
            byte_limit,
            header: header.clone(),
            handle: None,
            size: 0,
        };
        log.open()?;
        let mut initial = Vec::with_capacity(header.len() + 1);
        initial.push(b'\n');
        initial.extend_from_slice(&header);
        log.append_bytes(&initial)?;
        Ok(log)
    }

    pub fn current_path(&self) -> PathBuf {
        self.directory.join("current.jsonl")
    }

    pub fn previous_path(&self) -> PathBuf {
        self.directory.join("previous.jsonl")
    }

    fn open(&mut self) -> Result<(), String> {
        let current = self.current_path();
        let existed = current.exists();
        let mut file = OpenOptions::new()
            .create(true)
            .truncate(false)
            .write(true)
            .open(&current)
            .map_err(|e| e.to_string())?;
        if !existed {
            let _ = std::fs::set_permissions(&current, std::fs::Permissions::from_mode(0o600));
        }
        let end = file.seek(SeekFrom::End(0)).map_err(|e| e.to_string())?;
        self.size = end as usize;
        self.handle = Some(file);
        Ok(())
    }

    pub fn append(&mut self, mut event: PerformanceEvent) -> Result<(), String> {
        event.time = format_local_iso(Timestamp::now());
        let mut bytes = serde_json::to_vec(&event).map_err(|e| e.to_string())?;
        bytes.push(b'\n');
        self.append_bytes(&bytes)
    }

    fn append_bytes(&mut self, data: &[u8]) -> Result<(), String> {
        if self.handle.is_none() {
            return Err("Performance log is closed".to_string());
        }
        if data.len() + self.header.len() >= self.byte_limit {
            return Err("Performance event exceeds byte limit".to_string());
        }
        if self.size + data.len() > self.byte_limit {
            self.close();
            let prev = self.previous_path();
            if prev.exists() {
                std::fs::remove_file(&prev).map_err(|e| e.to_string())?;
            }
            std::fs::rename(self.current_path(), &prev).map_err(|e| e.to_string())?;
            self.open()?;
            let header = self.header.clone();
            self.write_raw(&header)?;
        }
        self.write_raw(data)
    }

    fn write_raw(&mut self, data: &[u8]) -> Result<(), String> {
        let file = self
            .handle
            .as_mut()
            .ok_or_else(|| "Performance log is closed".to_string())?;
        file.write_all(data).map_err(|e| e.to_string())?;
        file.flush().map_err(|e| e.to_string())?;
        self.size += data.len();
        Ok(())
    }

    pub fn close(&mut self) {
        self.handle = None;
    }
}

/// Pure state machine for tracking one outstanding main-thread responsiveness probe.
#[derive(Debug, Clone, Default)]
pub struct PerformanceProbeState {
    sequence: u64,
    pending: Option<MainThreadProbe>,
    reported: bool,
    pub sleeping: bool,
    pub max_delay: f64,
}

#[derive(Debug, Clone, Copy, PartialEq)]
pub struct MainThreadProbe {
    pub id: u64,
    pub sent: f64,
}

impl PerformanceProbeState {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn pending(&self) -> Option<MainThreadProbe> {
        self.pending
    }

    pub fn begin(&mut self, now: f64) -> Option<MainThreadProbe> {
        if self.sleeping || self.pending.is_some() {
            return None;
        }
        self.sequence = self.sequence.wrapping_add(1);
        let probe = MainThreadProbe {
            id: self.sequence,
            sent: now,
        };
        self.pending = Some(probe);
        self.reported = false;
        Some(probe)
    }

    pub fn stalled(&mut self, now: f64) -> Option<f64> {
        let pending = self.pending?;
        if self.reported || self.sleeping || now - pending.sent < 1.0 {
            return None;
        }
        self.reported = true;
        Some(now - pending.sent)
    }

    pub fn finish(&mut self, probe: MainThreadProbe, now: f64) -> Option<f64> {
        if self.sleeping || self.pending.map(|p| p.id) != Some(probe.id) {
            return None;
        }
        self.pending = None;
        let delay = (now - probe.sent).max(0.0);
        self.max_delay = self.max_delay.max(delay);
        Some(delay)
    }

    pub fn set_sleeping(&mut self, value: bool) {
        self.sleeping = value;
        self.pending = None;
        self.max_delay = 0.0;
    }
}
