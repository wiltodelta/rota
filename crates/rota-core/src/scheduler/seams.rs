use std::collections::HashMap;
use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::atomic::Ordering;

use jiff::Timestamp;
use jiff::tz::TimeZone;
use rota_platform::open_terminal_script;

use crate::model::{Harness, RunRecord};
use crate::runners::{ClaudeUserSettings, NativeTranscript, ScreenRun};
use crate::scheduler::{Scheduler, ServiceProbe, ServiceProbeFn};
use crate::storage::RunHistory;

pub type ClockFn = Arc<dyn Fn() -> Timestamp + Send + Sync>;
pub type OnlineFn = Arc<dyn Fn() -> bool + Send + Sync>;
pub type SessionAliveFn = Arc<dyn Fn(&str) -> bool + Send + Sync>;
pub type TranscriptLookupFn = Arc<dyn Fn(Harness, &str) -> Option<PathBuf> + Send + Sync>;
pub type ClaudeSettingsFn = Arc<dyn Fn() -> ClaudeUserSettings + Send + Sync>;
pub type TerminalOpenerFn = Arc<dyn Fn(&Path, Option<&str>) -> Result<(), String> + Send + Sync>;
pub type HistoryReaderFn = Arc<dyn Fn(&RunHistory, &str) -> Vec<RunRecord> + Send + Sync>;

pub(crate) struct SchedulerSeams {
    pub now: ClockFn,
    pub tz: TimeZone,
    pub is_online: Option<OnlineFn>,
    pub probe: ServiceProbeFn,
    pub session_alive: SessionAliveFn,
    pub terminal_transcript: TranscriptLookupFn,
    pub claude_settings: ClaudeSettingsFn,
    pub terminal_opener: TerminalOpenerFn,
    pub read_history: HistoryReaderFn,
}

impl Default for SchedulerSeams {
    fn default() -> Self {
        Self {
            now: Arc::new(Timestamp::now),
            tz: TimeZone::system(),
            is_online: None,
            probe: Arc::new(ServiceProbe::check),
            session_alive: Arc::new(ScreenRun::alive),
            terminal_transcript: Arc::new(NativeTranscript::locate),
            claude_settings: Arc::new(ClaudeUserSettings::read),
            terminal_opener: Arc::new(open_terminal_script),
            read_history: Arc::new(|h, id| h.records(id)),
        }
    }
}

impl Scheduler {
    pub fn set_claude_interactive(&self, interactive: bool) {
        self.claude_interactive.store(interactive, Ordering::Release);
    }

    pub fn claude_interactive(&self) -> bool {
        self.claude_interactive.load(Ordering::Acquire)
    }

    pub fn set_executable_overrides(&self, map: HashMap<Harness, String>) {
        self.state.lock().unwrap().executable_overrides = map;
    }

    pub fn set_completion_notifications(&self, enabled: bool) {
        self.completion_notifications.store(enabled, Ordering::Release);
    }

    pub fn completion_notifications(&self) -> bool {
        self.completion_notifications.load(Ordering::Acquire)
    }

    pub fn set_command_path(&self, path: Option<String>) {
        self.state.lock().unwrap().command_path = path;
    }

    pub fn set_clock(&self, now_fn: ClockFn) {
        self.seams.lock().unwrap().now = now_fn;
    }

    pub fn set_time_zone(&self, tz: TimeZone) {
        self.seams.lock().unwrap().tz = tz;
    }

    pub fn set_online_provider(&self, is_online: OnlineFn) {
        self.seams.lock().unwrap().is_online = Some(is_online);
    }

    pub fn set_service_probe(&self, probe: ServiceProbeFn) {
        self.seams.lock().unwrap().probe = probe;
    }

    pub fn set_service_probe_sync<F>(&self, probe: F)
    where
        F: Fn(Harness) -> bool + Send + Sync + 'static,
    {
        self.set_service_probe(Arc::new(move |h, done| done(probe(h))));
    }

    pub fn set_session_alive(&self, alive: SessionAliveFn) {
        self.seams.lock().unwrap().session_alive = alive;
    }

    pub fn set_terminal_transcript(&self, lookup: TranscriptLookupFn) {
        self.seams.lock().unwrap().terminal_transcript = lookup;
    }

    pub fn set_claude_settings_provider(&self, provider: ClaudeSettingsFn) {
        self.seams.lock().unwrap().claude_settings = provider;
    }

    pub fn set_terminal_opener(&self, opener: TerminalOpenerFn) {
        self.seams.lock().unwrap().terminal_opener = opener;
    }

    pub fn set_history_reader(&self, reader: HistoryReaderFn) {
        self.seams.lock().unwrap().read_history = reader;
    }

    pub(crate) fn now(&self) -> Timestamp {
        let f = Arc::clone(&self.seams.lock().unwrap().now);
        f()
    }

    pub(crate) fn time_zone(&self) -> TimeZone {
        self.seams.lock().unwrap().tz.clone()
    }

    pub(crate) fn is_online(&self) -> bool {
        let custom = self.seams.lock().unwrap().is_online.clone();
        custom.map_or_else(|| self.online.load(Ordering::Acquire), |f| f())
    }

    pub(crate) fn probe_fn(&self) -> ServiceProbeFn {
        Arc::clone(&self.seams.lock().unwrap().probe)
    }

    pub(crate) fn check_session_alive(&self, name: &str) -> bool {
        let f = Arc::clone(&self.seams.lock().unwrap().session_alive);
        f(name)
    }

    pub(crate) fn lookup_terminal_transcript(&self, harness: Harness, session: &str) -> Option<PathBuf> {
        let f = Arc::clone(&self.seams.lock().unwrap().terminal_transcript);
        f(harness, session)
    }

    pub(crate) fn claude_settings(&self) -> ClaudeUserSettings {
        let f = Arc::clone(&self.seams.lock().unwrap().claude_settings);
        f()
    }

    pub(crate) fn terminal_opener_fn(&self) -> TerminalOpenerFn {
        Arc::clone(&self.seams.lock().unwrap().terminal_opener)
    }

    pub(crate) fn history_reader_fn(&self) -> HistoryReaderFn {
        Arc::clone(&self.seams.lock().unwrap().read_history)
    }

    pub(crate) fn executable_for(&self, harness: Harness) -> String {
        self.state
            .lock()
            .unwrap()
            .executable_overrides
            .get(&harness)
            .cloned()
            .unwrap_or_else(|| harness.default_executable())
    }

    pub fn tail_of_file(path: &Path, characters: usize) -> (String, bool) {
        let Ok(mut file) = File::open(path) else {
            return (String::new(), false);
        };
        let size = file.seek(SeekFrom::End(0)).unwrap_or(0);
        let limit_u64 = characters as u64;
        let start = if limit_u64 < size / 4 {
            size - limit_u64 * 4
        } else {
            0
        };
        let _ = file.seek(SeekFrom::Start(start));
        let mut buf = Vec::new();
        let _ = file.read_to_end(&mut buf);
        let text = String::from_utf8_lossy(&buf);
        let char_count = text.chars().count();
        if char_count <= characters {
            (text.into_owned(), start > 0)
        } else {
            let skip = char_count - characters;
            let suffix: String = text.chars().skip(skip).collect();
            (suffix, true)
        }
    }
}
