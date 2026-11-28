use std::ffi::c_char;
use std::fs::OpenOptions;
use std::path::Path;
use std::ptr;
use std::sync::Arc;

use rota_core::{
    Harness, RunEvents, RunJournal, RunOutcome, RunRecord, SessionPreview, TranscriptItemKind,
    TranscriptJournal, TranscriptReader,
};
use serde::Serialize;

use crate::{cstr_to_str, err_envelope, ok_envelope};

pub struct RotaReaderHandle {
    reader: TranscriptReader,
}

pub struct RotaJournalHandle {
    journal: Arc<RunJournal>,
}

#[derive(Serialize)]
struct PreviewReply {
    preview: String,
    items: usize,
}

/// Creates a stateful `TranscriptReader` (`page_size <= 0` means unpaged).
#[unsafe(no_mangle)]
pub extern "C" fn rota_reader_create(page_size: i64, settle_writes: bool) -> *mut RotaReaderHandle {
    let ps = usize::try_from(page_size).ok().filter(|&n| n > 0);
    Box::into_raw(Box::new(RotaReaderHandle {
        reader: TranscriptReader::new(ps, settle_writes),
    }))
}

/// Reads or pages `<log_path>.chat.jsonl` (falling back to `<log_path>` when unstructured).
///
/// # Safety
/// `handle` must be a valid `RotaReaderHandle*`, and `log_path` a valid NUL-terminated string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn rota_reader_read(
    handle: *mut RotaReaderHandle,
    log_path: *const c_char,
    shell: bool,
    finished: bool,
    earlier: bool,
) -> *mut c_char {
    if handle.is_null() {
        return err_envelope("Null reader handle.");
    }
    let Some(path_str) = (unsafe { cstr_to_str(log_path) }) else {
        return err_envelope("Invalid log path.");
    };
    let h = unsafe { &mut *handle };
    let path = Path::new(path_str);
    let snap = if earlier && !shell {
        h.reader.read_earlier(path, finished)
    } else {
        h.reader.read(path, shell, finished)
    };
    ok_envelope(snap)
}

/// Computes the 1-line sidebar preview for `record` inside Rust without serializing full items.
///
/// # Safety
/// `handle` must be a valid `RotaReaderHandle*`, and `record_json` a valid NUL-terminated string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn rota_reader_preview(
    handle: *mut RotaReaderHandle,
    record_json: *const c_char,
) -> *mut c_char {
    if handle.is_null() {
        return err_envelope("Null reader handle.");
    }
    let Some(raw) = (unsafe { cstr_to_str(record_json) }) else {
        return err_envelope("Invalid record JSON.");
    };
    let record: RunRecord = match serde_json::from_str(raw) {
        Ok(r) => r,
        Err(e) => return err_envelope(format!("Invalid RunRecord JSON: {e}")),
    };
    let h = unsafe { &mut *handle };
    let mut item_count = 0usize;
    let snapshot = if !record.is_skip()
        && let Some(path) = &record.log_path
    {
        let snap = h.reader.read(
            Path::new(path),
            record.harness == Harness::Shell,
            record.outcome != RunOutcome::Running,
        );
        item_count = snap.items.len();
        Some(snap)
    } else {
        None
    };
    let preview = SessionPreview::text(&record, snapshot.as_ref());
    ok_envelope(PreviewReply {
        preview,
        items: item_count,
    })
}

/// # Safety
/// `handle` must be null or an un-freed pointer returned by `rota_reader_create`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn rota_reader_free(handle: *mut RotaReaderHandle) {
    if !handle.is_null() {
        unsafe {
            let _ = Box::from_raw(handle);
        }
    }
}

/// Opens a `RunJournal` + `TranscriptJournal` pair writing to `log_path` and `<log_path>.chat.jsonl`.
///
/// # Safety
/// `log_path` must be a valid NUL-terminated UTF-8 string.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn rota_journal_create(
    log_path: *const c_char,
    resuming: bool,
) -> *mut RotaJournalHandle {
    let Some(path_str) = (unsafe { cstr_to_str(log_path) }) else {
        return ptr::null_mut();
    };
    let path = Path::new(path_str);
    if let Some(parent) = path.parent() {
        let _ = std::fs::create_dir_all(parent);
    }
    let Ok(output) = OpenOptions::new().create(true).append(true).open(path) else {
        return ptr::null_mut();
    };
    let log_size = output.metadata().map(|m| m.len()).unwrap_or(0);
    let Ok(transcript) = TranscriptJournal::open(path, resuming, log_size) else {
        return ptr::null_mut();
    };
    let events = RunEvents::new(|_| {}, |_| {});
    let journal = RunJournal::new(output, events, Some(transcript), None);
    Box::into_raw(Box::new(RotaJournalHandle { journal }))
}

/// # Safety
/// `handle`, `kind`, and `text` must be valid pointers.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn rota_journal_record(
    handle: *const RotaJournalHandle,
    kind: *const c_char,
    text: *const c_char,
) {
    if handle.is_null() {
        return;
    }
    let (Some(k_str), Some(t_str)) = (unsafe { cstr_to_str(kind) }, unsafe { cstr_to_str(text) }) else {
        return;
    };
    let item_kind = TranscriptItemKind::parse(k_str).unwrap_or(TranscriptItemKind::Status);
    let h = unsafe { &*handle };
    h.journal.record(item_kind, t_str);
}

/// # Safety
/// `handle` and `outcome_json` must be valid pointers.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn rota_journal_finish(handle: *const RotaJournalHandle, outcome_json: *const c_char) {
    if handle.is_null() {
        return;
    }
    let outcome = unsafe { cstr_to_str(outcome_json) }
        .and_then(|s| serde_json::from_str::<RunOutcome>(s).ok())
        .unwrap_or(RunOutcome::Succeeded);
    let h = unsafe { &*handle };
    h.journal.finish(outcome);
}

/// # Safety
/// `handle` must be null or an un-freed pointer returned by `rota_journal_create`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn rota_journal_free(handle: *mut RotaJournalHandle) {
    if !handle.is_null() {
        unsafe {
            let _ = Box::from_raw(handle);
        }
    }
}
