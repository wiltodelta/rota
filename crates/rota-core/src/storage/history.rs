use std::collections::HashSet;
use std::io::ErrorKind;
use std::path::{Path, PathBuf};

use jiff::Timestamp;
use uuid::Uuid;

use crate::model::serde_ext::{format_iso_timestamp, uppercase_uuid};
use crate::model::{RunOutcome, RunRecord};
use crate::runners::DurableStream;
use crate::storage::{
    ChatAttachmentStore, HistoryDeletionError, RunLease, StorageLocation, atomic_write_json,
    normalize_lexical_path, read_json_file, resolve_symlinks_best_effort,
};
use crate::transcript::TranscriptReader;

#[derive(Debug, Clone)]
pub struct RunHistory {
    location: StorageLocation,
}

impl RunHistory {
    pub const LIMIT: usize = 50;
    pub const SKIP_LIMIT: usize = 50;

    pub fn new(location: StorageLocation) -> Self {
        Self { location }
    }

    pub fn location(&self) -> &StorageLocation {
        &self.location
    }

    pub fn terminal_script(&self, id: Uuid) -> PathBuf {
        self.location
            .root
            .join("terminal-scripts")
            .join(format!("{}.command", uppercase_uuid(id)))
    }

    fn file(&self, routine_id: &str) -> PathBuf {
        self.location
            .history_directory()
            .join(format!("{routine_id}.json"))
    }

    pub fn records(&self, routine_id: &str) -> Vec<RunRecord> {
        read_json_file::<Vec<RunRecord>>(&self.file(routine_id))
            .ok()
            .flatten()
            .unwrap_or_default()
    }

    pub fn upsert(&self, record: &RunRecord) -> Result<(), String> {
        let path = self.file(&record.routine_id);
        let mut records = read_json_file::<Vec<RunRecord>>(&path)?.unwrap_or_default();
        if let Some(existing) = records.iter_mut().find(|r| r.id == record.id) {
            *existing = record.clone();
        } else {
            records.insert(0, record.clone());
        }
        records.sort_by_key(|a| std::cmp::Reverse(a.started_at));

        let mut sessions = 0usize;
        let mut skips = 0usize;
        let mut retained = Vec::with_capacity(records.len());
        for item in &records {
            if item.outcome == RunOutcome::Running
                || item.needs_reconciliation == Some(true)
                || item.questions.as_ref().is_some_and(|qs| !qs.is_empty())
            {
                retained.push(item.clone());
                continue;
            }
            if item.is_skip() {
                skips += 1;
                if skips <= Self::SKIP_LIMIT {
                    retained.push(item.clone());
                }
            } else {
                sessions += 1;
                if sessions <= Self::LIMIT {
                    retained.push(item.clone());
                }
            }
        }
        atomic_write_json(&path, &retained)?;
        if retained.len() == records.len() {
            return Ok(());
        }
        let kept_ids: HashSet<Uuid> = retained.iter().map(|r| r.id).collect();
        let kept_logs: HashSet<PathBuf> = retained
            .iter()
            .filter_map(|r| {
                r.log_path
                    .as_deref()
                    .map(|p| resolve_symlinks_best_effort(Path::new(p)))
            })
            .collect();

        for dropped in &records {
            if !kept_ids.contains(&dropped.id) {
                let _ = std::fs::remove_file(self.terminal_script(dropped.id));
                if let Some(log_str) = &dropped.log_path {
                    let resolved = resolve_symlinks_best_effort(Path::new(log_str));
                    if !kept_logs.contains(&resolved) {
                        self.remove_log_best_effort(log_str, &record.routine_id);
                    }
                }
            }
        }
        Ok(())
    }

    pub fn close_orphans(&self, routine_ids: &[String], now: Timestamp) -> Vec<RunRecord> {
        let mut closed = Vec::new();
        for routine_id in routine_ids {
            for mut record in self.records(routine_id) {
                if record.outcome == RunOutcome::Running || record.needs_reconciliation == Some(true) {
                    if record.questions.as_ref().is_some_and(|qs| !qs.is_empty()) {
                        let had_blocking = record.has_blocking_question();
                        if let Some(qs) = &mut record.questions {
                            qs.retain(|q| q.reply_via_message == Some(true));
                        }
                        record.attention = record.next_question().map(|q| q.title.clone());
                        if had_blocking && record.questions.as_ref().is_none_or(Vec::is_empty) {
                            record.attention = Some(
                                "The session was interrupted while waiting for your answer. \
Continue it to ask again."
                                    .to_string(),
                            );
                        }
                    }
                    record.outcome = RunOutcome::Interrupted;
                    record.ended_at = Some(now);
                    let _ = self.upsert(&record);
                    closed.push(record);
                }
            }
        }
        closed
    }

    pub fn remove_all(&self, routine_id: &str) {
        for record in self.records(routine_id) {
            let _ = std::fs::remove_file(self.terminal_script(record.id));
            if let Some(log) = &record.log_path {
                self.remove_log_best_effort(log, routine_id);
            }
        }
        let _ = std::fs::remove_file(self.file(routine_id));
    }

    pub fn remove(&self, id: Uuid, routine_id: &str) -> Result<bool, HistoryDeletionError> {
        let path = self.file(routine_id);
        let records = read_json_file::<Vec<RunRecord>>(&path)
            .map_err(HistoryDeletionError::Io)?
            .unwrap_or_default();
        let Some(record) = records.iter().find(|r| r.id == id) else {
            return Ok(false);
        };
        if record.outcome == RunOutcome::Running || record.needs_reconciliation == Some(true) {
            return Err(HistoryDeletionError::Running);
        }
        let retained: Vec<RunRecord> = records.iter().filter(|r| r.id != id).cloned().collect();
        if let Some(log_str) = &record.log_path {
            let log = self.owned_log(log_str, routine_id)?;
            let resolved_log = resolve_symlinks_best_effort(&log);
            let shared = retained.iter().any(|other| {
                other
                    .log_path
                    .as_deref()
                    .is_some_and(|p| resolve_symlinks_best_effort(Path::new(p)) == resolved_log)
            });
            if !shared {
                let companions = [
                    log.clone(),
                    TranscriptReader::journal_path(&log),
                    ChatAttachmentStore::folder_for(&log),
                    DurableStream::folder(&log),
                    RunLease::path(&log),
                ];
                for url in companions {
                    remove_path_strict(&url).map_err(|e| HistoryDeletionError::Io(e.to_string()))?;
                }
            }
        }
        atomic_write_json(&path, &retained).map_err(HistoryDeletionError::Io)?;
        let _ = std::fs::remove_file(self.terminal_script(id));
        Ok(true)
    }

    pub fn attachments(&self, record: &RunRecord) -> Result<ChatAttachmentStore, HistoryDeletionError> {
        let path = record
            .log_path
            .as_deref()
            .ok_or(HistoryDeletionError::ForeignLog)?;
        let owned = self.owned_log(path, &record.routine_id)?;
        Ok(ChatAttachmentStore::new(&owned))
    }

    pub fn owned_log(&self, path: &str, routine_id: &str) -> Result<PathBuf, HistoryDeletionError> {
        if routine_id.is_empty() || routine_id.contains('/') || routine_id.contains("..") {
            return Err(HistoryDeletionError::ForeignLog);
        }
        let log = normalize_lexical_path(Path::new(path));
        if log.extension().and_then(|e| e.to_str()) != Some("log") {
            return Err(HistoryDeletionError::ForeignLog);
        }
        let routine_dir = self.location.logs.join(routine_id);
        if let Ok(meta) = std::fs::symlink_metadata(&routine_dir)
            && meta.file_type().is_symlink()
        {
            return Err(HistoryDeletionError::ForeignLog);
        }
        let resolved_logs = resolve_symlinks_best_effort(&self.location.logs);
        let resolved_folder = resolve_symlinks_best_effort(&routine_dir);
        if resolved_folder.parent() != Some(resolved_logs.as_path()) {
            return Err(HistoryDeletionError::ForeignLog);
        }
        let log_parent = log.parent().ok_or(HistoryDeletionError::ForeignLog)?;
        if let Ok(meta) = std::fs::symlink_metadata(log_parent)
            && meta.file_type().is_symlink()
        {
            return Err(HistoryDeletionError::ForeignLog);
        }
        if resolve_symlinks_best_effort(log_parent) != resolved_folder {
            return Err(HistoryDeletionError::ForeignLog);
        }
        Ok(log)
    }

    fn remove_log_best_effort(&self, path: &str, routine_id: &str) {
        let Ok(log) = self.owned_log(path, routine_id) else {
            return;
        };
        for target in [
            log.clone(),
            TranscriptReader::journal_path(&log),
            ChatAttachmentStore::folder_for(&log),
            DurableStream::folder(&log),
            RunLease::path(&log),
        ] {
            let _ = remove_path_strict(&target);
        }
    }

    pub fn log_file(&self, record: &RunRecord) -> PathBuf {
        let stamp = format_iso_timestamp(record.started_at).replace(':', "-");
        self.location
            .logs
            .join(&record.routine_id)
            .join(format!("{stamp}-{}.log", uppercase_uuid(record.id)))
    }
}

fn remove_path_strict(path: &Path) -> std::io::Result<()> {
    match std::fs::symlink_metadata(path) {
        Ok(meta) => {
            if meta.is_dir() && !meta.file_type().is_symlink() {
                std::fs::remove_dir_all(path)
            } else {
                std::fs::remove_file(path)
            }
        }
        Err(err) if err.kind() == ErrorKind::NotFound => Ok(()),
        Err(err) => Err(err),
    }
}
