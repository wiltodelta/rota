use std::ffi::{CString, c_char};
use std::path::PathBuf;
use std::ptr;
use std::sync::{Arc, mpsc};

use rota_core::{ControlError, ControlServer, ControlServerHandle};
use serde_json::{Value, json};

use crate::{cstr_to_str, write_out_error};

pub type RotaControlReplyFn = unsafe extern "C" fn(reply_ctx: usize, response_json: *const c_char);
pub type RotaControlRequestCallback = Option<
    unsafe extern "C" fn(
        ctx: usize,
        method: *const c_char,
        params_json: *const c_char,
        reply_ctx: usize,
        reply_fn: RotaControlReplyFn,
    ),
>;

pub struct RotaControlServerHandle {
    handle: ControlServerHandle,
}

unsafe extern "C" fn deliver_control_reply(reply_ctx: usize, response_json: *const c_char) {
    if reply_ctx == 0 {
        return;
    }
    let tx = unsafe { &*(reply_ctx as *const mpsc::SyncSender<Result<Value, ControlError>>) };
    let parsed = unsafe { cstr_to_str(response_json) }
        .and_then(|s| serde_json::from_str::<Value>(s).ok())
        .unwrap_or_else(|| json!({ "error": "Invalid control callback reply." }));
    let outcome = if let Some(err) = parsed.get("error").and_then(Value::as_str) {
        Err(ControlError::new(err))
    } else {
        Ok(parsed.get("ok").cloned().unwrap_or(Value::Null))
    };
    let _ = tx.send(outcome);
}

/// # Safety
/// `socket_path` must be a valid NUL-terminated UTF-8 string; `callback` must be non-null.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn rota_control_server_start(
    socket_path: *const c_char,
    ctx: usize,
    callback: RotaControlRequestCallback,
    out_error: *mut *mut c_char,
) -> *mut RotaControlServerHandle {
    let (Some(sock_str), Some(cb)) = (unsafe { cstr_to_str(socket_path) }, callback) else {
        unsafe { write_out_error(out_error, "Invalid control server arguments.") };
        return ptr::null_mut();
    };
    let res = ControlServer::start(
        PathBuf::from(sock_str),
        Arc::new(move |method, params| {
            let m_c = CString::new(method).map_err(|e| ControlError::new(e.to_string()))?;
            let p_c = CString::new(params.to_string()).map_err(|e| ControlError::new(e.to_string()))?;
            let (tx, rx) = mpsc::sync_channel::<Result<Value, ControlError>>(1);
            let tx_ptr = (&raw const tx) as usize;
            unsafe {
                cb(ctx, m_c.as_ptr(), p_c.as_ptr(), tx_ptr, deliver_control_reply);
            }
            rx.recv()
                .unwrap_or_else(|_| Err(ControlError::new("Control handler closed without replying.")))
        }),
    );
    match res {
        Ok(handle) => Box::into_raw(Box::new(RotaControlServerHandle { handle })),
        Err(err) => {
            unsafe { write_out_error(out_error, err.message) };
            ptr::null_mut()
        }
    }
}

/// # Safety
/// `handle` must be null or an un-freed pointer returned by `rota_control_server_start`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn rota_control_server_free(handle: *mut RotaControlServerHandle) {
    if !handle.is_null() {
        unsafe {
            let box_h = Box::from_raw(handle);
            box_h.handle.stop();
        }
    }
}
