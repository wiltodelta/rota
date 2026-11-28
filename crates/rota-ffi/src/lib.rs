//! C FFI boundary exposing `rota-core` and `rota-platform` to the native SwiftUI/AppKit shell.

mod control_ffi;
mod scheduler_ffi;
mod services_ffi;
mod transcript_ffi;

use std::ffi::{CStr, CString, c_char};

use rota_core::Harness;
use serde::Serialize;
use serde::de::DeserializeOwned;
use serde_json::{Map, Value, json};

pub use control_ffi::{
    RotaControlReplyFn, RotaControlRequestCallback, RotaControlServerHandle, rota_control_server_free,
    rota_control_server_start,
};
pub use scheduler_ffi::{
    RotaEventCallback, RotaSchedulerHandle, rota_scheduler_call, rota_scheduler_create, rota_scheduler_free,
    rota_scheduler_snapshot,
};
pub use services_ffi::rota_core_call;
pub use transcript_ffi::{
    RotaJournalHandle, RotaReaderHandle, rota_journal_create, rota_journal_finish, rota_journal_free,
    rota_journal_record, rota_reader_create, rota_reader_free, rota_reader_preview, rota_reader_read,
};

#[derive(Serialize)]
struct OkEnvelope<'a, T: Serialize> {
    ok: &'a T,
}

pub(crate) fn into_c_string(s: String) -> *mut c_char {
    match CString::new(s) {
        Ok(cs) => cs.into_raw(),
        Err(_) => CString::new("{\"error\":\"Embedded NUL byte in FFI string\"}")
            .unwrap()
            .into_raw(),
    }
}

pub(crate) fn ok_envelope<T: Serialize>(val: T) -> *mut c_char {
    match serde_json::to_string(&OkEnvelope { ok: &val }) {
        Ok(text) => into_c_string(text),
        Err(err) => err_envelope(err.to_string()),
    }
}

pub(crate) fn err_envelope(msg: impl Into<String>) -> *mut c_char {
    into_c_string(json!({ "error": msg.into() }).to_string())
}

pub(crate) unsafe fn cstr_to_str<'a>(ptr: *const c_char) -> Option<&'a str> {
    if ptr.is_null() {
        return None;
    }
    // SAFETY: Caller guarantees `ptr` points to a valid NUL-terminated C string.
    unsafe { CStr::from_ptr(ptr) }.to_str().ok()
}

pub(crate) unsafe fn parse_json_map(ptr: *const c_char) -> Result<Map<String, Value>, String> {
    let Some(raw) = (unsafe { cstr_to_str(ptr) }) else {
        return Ok(Map::new());
    };
    if raw.trim().is_empty() {
        return Ok(Map::new());
    }
    match serde_json::from_str::<Value>(raw).map_err(|e| format!("Invalid FFI JSON argument: {e}"))? {
        Value::Object(map) => Ok(map),
        _ => Ok(Map::new()),
    }
}

pub(crate) fn take_field<T: DeserializeOwned>(map: &mut Map<String, Value>, key: &str) -> Result<T, String> {
    let val = map.remove(key).ok_or_else(|| format!("Missing {key}."))?;
    serde_json::from_value(val).map_err(|e| e.to_string())
}

pub(crate) fn take_or_default<T: DeserializeOwned + Default>(
    map: &mut Map<String, Value>,
    key: &str,
) -> Result<T, String> {
    match map.remove(key) {
        Some(val) if !val.is_null() => serde_json::from_value(val).map_err(|e| e.to_string()),
        _ => Ok(T::default()),
    }
}

pub(crate) fn parse_harness_field(map: &Map<String, Value>, key: &str) -> Result<Harness, String> {
    let raw = map
        .get(key)
        .and_then(Value::as_str)
        .ok_or_else(|| format!("Missing {key}."))?;
    Harness::parse(raw).ok_or_else(|| format!("Unknown harness {raw}."))
}

pub(crate) unsafe fn write_out_error(out_error: *mut *mut c_char, msg: impl Into<String>) {
    if !out_error.is_null() {
        // SAFETY: Caller provided a valid writable out-pointer.
        unsafe {
            *out_error = into_c_string(msg.into());
        }
    }
}

/// Frees a heap string previously allocated by `rota_*`. Safe to pass `NULL`.
///
/// # Safety
/// `ptr` must be either `NULL` or a pointer returned by one of this crate's `rota_*` functions
/// that has not yet been freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn rota_string_free(ptr: *mut c_char) {
    if !ptr.is_null() {
        // SAFETY: `ptr` was allocated by `CString::into_raw` in this crate.
        unsafe {
            let _ = CString::from_raw(ptr);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::ffi::CString;
    use std::ptr;
    use std::sync::atomic::{AtomicUsize, Ordering};

    static CALLBACK_HITS: AtomicUsize = AtomicUsize::new(0);

    extern "C" fn record_event(_ctx: usize, kind: u32, _payload: *const c_char) {
        if kind == 1 {
            CALLBACK_HITS.fetch_add(1, Ordering::SeqCst);
        }
    }

    #[test]
    fn scheduler_ffi_roundtrip_saves_routine_and_emits_revision_callback() {
        CALLBACK_HITS.store(0, Ordering::SeqCst);
        let tmp = std::env::temp_dir().join(format!("rota-ffi-test-{}", uuid::Uuid::new_v4()));
        let logs = tmp.join("Logs");
        std::fs::create_dir_all(&logs).unwrap();
        let root_c = CString::new(tmp.to_string_lossy().as_ref()).unwrap();
        let logs_c = CString::new(logs.to_string_lossy().as_ref()).unwrap();
        let mut err_ptr: *mut c_char = ptr::null_mut();

        let handle = unsafe {
            rota_scheduler_create(
                root_c.as_ptr(),
                logs_c.as_ptr(),
                false,
                0,
                Some(record_event),
                &raw mut err_ptr,
            )
        };
        assert!(!handle.is_null(), "scheduler handle must be created");
        assert!(err_ptr.is_null());

        let method = CString::new("saveRoutine").unwrap();
        let params = CString::new(
            r#"{"routine":{"id":"daily-check","name":"Daily Check","workingDirectory":"/tmp","schedule":"0 9 * * *","repeats":true,"harness":"codex","enabled":true,"prompt":"Check status","scheduledRunCount":0}}"#,
        )
        .unwrap();
        let resp_ptr = unsafe { rota_scheduler_call(handle, method.as_ptr(), params.as_ptr()) };
        let resp_str = unsafe { CStr::from_ptr(resp_ptr).to_str().unwrap().to_owned() };
        unsafe { rota_string_free(resp_ptr) };

        let parsed: Value = serde_json::from_str(&resp_str).unwrap();
        assert_eq!(parsed["ok"]["id"], "daily-check");
        assert_eq!(parsed["snapshot"]["routines"][0]["id"], "daily-check");
        assert!(
            CALLBACK_HITS.load(Ordering::SeqCst) >= 1,
            "saving a routine must notify the UI observer via RotaEventCallback"
        );

        unsafe { rota_scheduler_free(handle) };
        let _ = std::fs::remove_dir_all(&tmp);
    }

    #[test]
    fn core_call_describes_cron_and_computes_calendar() {
        let method = CString::new("scheduleText.describe").unwrap();
        let params = CString::new(r#"{"expression":"0 9 * * 1-5"}"#).unwrap();
        let out_ptr = unsafe { rota_core_call(method.as_ptr(), params.as_ptr()) };
        let out_str = unsafe { CStr::from_ptr(out_ptr).to_str().unwrap().to_owned() };
        unsafe { rota_string_free(out_ptr) };
        let val: Value = serde_json::from_str(&out_str).unwrap();
        assert_eq!(val["ok"], "Weekdays at 9:00 AM");
    }
}
