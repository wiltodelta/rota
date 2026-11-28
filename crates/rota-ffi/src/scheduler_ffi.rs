use std::collections::HashMap;
use std::ffi::{CString, c_char};
use std::path::PathBuf;
use std::ptr;
use std::sync::Arc;

use jiff::Timestamp;
use jiff::tz::TimeZone;
use rota_core::model::serde_ext::{format_iso_timestamp, parse_iso_timestamp, uppercase_uuid};
use rota_core::{
    AgentLauncher, Harness, LaunchError, LaunchSpec, QuestionAnswer, Routine, RoutineLaunching, RunControl,
    RunEvents, RunRecord, RunTrigger, Scheduler, SchedulerNotifier, StorageLocation,
};
use serde::Serialize;
use serde_json::{Map, Value, json};
use uuid::Uuid;

use crate::{
    cstr_to_str, err_envelope, into_c_string, parse_harness_field, parse_json_map, take_field,
    write_out_error,
};

pub type RotaEventCallback = Option<unsafe extern "C" fn(ctx: usize, kind: u32, payload_json: *const c_char)>;

const EVENT_REVISION_CHANGED: u32 = 1;
const EVENT_RUN_ENDED: u32 = 2;
const EVENT_ROUTINE_PAUSED: u32 = 3;
const EVENT_ROUTINE_ADDED: u32 = 4;
const EVENT_SESSION_NOTIFIED: u32 = 5;

pub struct RotaSchedulerHandle {
    scheduler: Arc<Scheduler>,
}

struct FfiNotifier {
    ctx: usize,
    callback: RotaEventCallback,
}

impl FfiNotifier {
    fn emit(&self, kind: u32, payload: Value) {
        let Some(cb) = self.callback else {
            return;
        };
        let Ok(cstr) = CString::new(payload.to_string()) else {
            return;
        };
        unsafe {
            cb(self.ctx, kind, cstr.as_ptr());
        }
    }
}

impl SchedulerNotifier for FfiNotifier {
    fn on_revision_changed(&self, revision: u64) {
        self.emit(EVENT_REVISION_CHANGED, json!({ "revision": revision }));
    }

    fn run_ended(&self, record: &RunRecord, routine: &Routine, _notify_on_success: bool) {
        self.emit(EVENT_RUN_ENDED, json!({ "record": record, "routine": routine }));
    }

    fn routine_paused(&self, routine: &Routine, failures: usize) {
        self.emit(
            EVENT_ROUTINE_PAUSED,
            json!({ "routine": routine, "failures": failures }),
        );
    }

    fn routine_added(&self, routine: &Routine) {
        self.emit(EVENT_ROUTINE_ADDED, json!({ "routine": routine }));
    }

    fn session_notified(
        &self,
        record: Option<&RunRecord>,
        routine: Option<&Routine>,
        title: Option<&str>,
        text: &str,
        needs_reply: bool,
        _can_reply: bool,
    ) {
        self.emit(
            EVENT_SESSION_NOTIFIED,
            json!({
                "record": record,
                "routine": routine,
                "title": title,
                "text": text,
                "needsReply": needs_reply,
            }),
        );
    }
}

struct DisabledTestLauncher;

impl RoutineLaunching for DisabledTestLauncher {
    fn launch(&self, _spec: LaunchSpec, _events: RunEvents) -> Result<Arc<dyn RunControl>, LaunchError> {
        Err(LaunchError::Message(
            "Test scheduler was configured without ProcessLauncher.".to_string(),
        ))
    }
}

fn serialize_record_map(records: HashMap<Uuid, RunRecord>) -> Map<String, Value> {
    records
        .into_iter()
        .filter_map(|(k, v)| serde_json::to_value(v).ok().map(|val| (uppercase_uuid(k), val)))
        .collect()
}

fn build_snapshot(scheduler: &Scheduler) -> Value {
    let revision = scheduler.revision();
    let maps = scheduler.snapshot_maps();
    let starts_json: Map<String, Value> = maps
        .run_starts
        .into_iter()
        .map(|(k, ts)| (uppercase_uuid(k), Value::String(format_iso_timestamp(ts))))
        .collect();
    json!({
        "revision": revision,
        "routines": maps.routines,
        "active": serialize_record_map(maps.active),
        "survivingSessions": serialize_record_map(maps.surviving_sessions),
        "openingTerminals": maps.opening_terminals.into_iter().map(uppercase_uuid).collect::<Vec<_>>(),
        "runStarts": starts_json,
        "lastError": maps.last_error,
    })
}

fn apply_seams(scheduler: &Scheduler, seams: &Map<String, Value>) {
    if let Some(exes) = seams.get("executables").and_then(Value::as_object) {
        let map: HashMap<Harness, String> = exes
            .iter()
            .filter_map(|(k, v)| Some((Harness::parse(k)?, v.as_str()?.to_string())))
            .collect();
        scheduler.set_executable_overrides(map);
    }
    if let Some(interactive) = seams.get("claudeInteractive").and_then(Value::as_bool) {
        scheduler.set_claude_interactive(interactive);
    }
    if let Some(online) = seams.get("online").and_then(Value::as_bool) {
        scheduler.set_online_flag(online);
    }
    if seams.contains_key("commandPath") {
        scheduler.set_command_path(
            seams
                .get("commandPath")
                .and_then(Value::as_str)
                .map(ToOwned::to_owned),
        );
    }
    if seams.contains_key("now") {
        if let Some(iso) = seams.get("now").and_then(Value::as_str)
            && let Some(ts) = parse_iso_timestamp(iso)
        {
            scheduler.set_clock(Arc::new(move || ts));
        } else {
            scheduler.set_clock(Arc::new(Timestamp::now));
        }
    }
    if let Some(tz_id) = seams.get("timeZone").and_then(Value::as_str)
        && let Ok(tz) = TimeZone::get(tz_id)
    {
        scheduler.set_time_zone(tz);
    }
}

fn parse_uuid_field(params: &Map<String, Value>, key: &str) -> Result<Uuid, String> {
    let raw = params
        .get(key)
        .and_then(Value::as_str)
        .ok_or_else(|| format!("Missing {key}."))?;
    Uuid::parse_str(raw).map_err(|e| format!("Invalid UUID {raw}: {e}"))
}

fn opt_string(params: &Map<String, Value>, key: &str) -> Option<String> {
    params.get(key).and_then(Value::as_str).map(ToOwned::to_owned)
}

fn to_json<T: Serialize>(val: T) -> Result<Value, String> {
    serde_json::to_value(val).map_err(|e| e.to_string())
}

fn dispatch_method(
    scheduler: &Scheduler,
    method: &str,
    params: &mut Map<String, Value>,
) -> Result<Value, String> {
    if let Some(Value::Object(seams)) = params.remove("seams") {
        apply_seams(scheduler, &seams);
    }
    match method {
        "start" => {
            scheduler.recover_orphans();
            scheduler.tick();
            scheduler.resume_pending();
            Ok(json!(true))
        }
        "tick" => {
            scheduler.tick();
            Ok(json!(true))
        }
        "systemWillSleep" => {
            scheduler.system_will_sleep();
            Ok(json!(true))
        }
        "networkBecameAvailable" => {
            scheduler.network_became_available();
            Ok(json!(true))
        }
        "setLastError" => {
            scheduler.set_last_error(opt_string(params, "error"));
            Ok(json!(true))
        }
        "saveRoutine" => to_json(scheduler.save_routine(take_field(params, "routine")?)?),
        "setEnabled" => {
            let id = params.get("id").and_then(Value::as_str).ok_or("Missing id.")?;
            let enabled = params
                .get("enabled")
                .and_then(Value::as_bool)
                .ok_or("Missing enabled.")?;
            to_json(scheduler.set_enabled(id, enabled)?)
        }
        "deleteRoutine" => {
            let id = params.get("id").and_then(Value::as_str).ok_or("Missing id.")?;
            scheduler.delete_routine(id)?;
            Ok(json!(true))
        }
        "deleteSession" => {
            scheduler.delete_session(parse_uuid_field(params, "id")?)?;
            Ok(json!(true))
        }
        "runRoutine" => {
            let routine: Routine = take_field(params, "routine")?;
            let trigger: RunTrigger = match params.remove("trigger") {
                Some(v) => serde_json::from_value(v).map_err(|e| e.to_string())?,
                None => RunTrigger::Manual,
            };
            let consume = params
                .get("consumingScheduledSlot")
                .and_then(Value::as_bool)
                .unwrap_or(true);
            to_json(scheduler.run_routine(&routine, trigger, consume)?)
        }
        "stopRoutine" => {
            let id = params.get("id").and_then(Value::as_str).ok_or("Missing id.")?;
            to_json(scheduler.stop_routine(id)?)
        }
        "stopSession" => to_json(scheduler.stop_session(parse_uuid_field(params, "id")?)?),
        "stopAll" => {
            scheduler.stop_all();
            Ok(json!(true))
        }
        "markRead" => to_json(scheduler.mark_read(parse_uuid_field(params, "id")?)?),
        "markUnread" => to_json(scheduler.mark_unread(parse_uuid_field(params, "id")?)?),
        "dismissAttention" => to_json(scheduler.dismiss_attention(parse_uuid_field(params, "id")?)?),
        "configureSession" => to_json(scheduler.configure_session(
            parse_uuid_field(params, "id")?,
            opt_string(params, "model"),
            opt_string(params, "effort"),
        )?),
        "messageEncoded" => {
            let id = parse_uuid_field(params, "id")?;
            let msg = params
                .get("message")
                .and_then(Value::as_str)
                .ok_or("Missing message.")?;
            to_json(scheduler.message_encoded(id, msg)?)
        }
        "answerQuestion" => {
            let id = parse_uuid_field(params, "sessionID")?;
            let qid = params
                .remove("questionID")
                .and_then(|v| v.as_str().map(ToOwned::to_owned))
                .ok_or("Missing questionID.")?;
            let ans: QuestionAnswer = take_field(params, "answer")?;
            to_json(scheduler.answer_question(id, &qid, ans)?)
        }
        "notify" => {
            let text = params.get("text").and_then(Value::as_str).unwrap_or("");
            let needs_reply = params.get("needsReply").and_then(Value::as_bool).unwrap_or(false);
            to_json(scheduler.notify_session(
                text,
                params.get("title").and_then(Value::as_str),
                params.get("session").and_then(Value::as_str),
                params.get("routineID").and_then(Value::as_str),
                needs_reply,
            )?)
        }
        "restart" => {
            let id = parse_uuid_field(params, "id")?;
            let harness = parse_harness_field(params, "harness")?;
            to_json(scheduler.restart_session(
                id,
                harness,
                opt_string(params, "model"),
                opt_string(params, "effort"),
            )?)
        }
        "discuss" => {
            let id = parse_uuid_field(params, "id")?;
            let harness = parse_harness_field(params, "harness")?;
            let prompt = params.get("prompt").and_then(Value::as_str).unwrap_or("");
            to_json(scheduler.discuss_shell_session(
                id,
                harness,
                prompt,
                opt_string(params, "model"),
                opt_string(params, "effort"),
            )?)
        }
        "discussions" => to_json(scheduler.discussions_of(parse_uuid_field(params, "id")?)),
        "terminalCommand" => {
            let rec: RunRecord = take_field(params, "record")?;
            Ok(match scheduler.terminal_command(&rec) {
                Some((exe, args)) => json!({ "executable": exe, "arguments": args }),
                None => Value::Null,
            })
        }
        "continueInTerminal" => to_json(scheduler.continue_in_terminal(parse_uuid_field(params, "id")?)?),
        "controlRequest" => {
            let ctrl_method = params
                .remove("method")
                .and_then(|v| v.as_str().map(ToOwned::to_owned))
                .ok_or("Missing control method.")?;
            let ctrl_params = params.remove("params").unwrap_or_else(|| json!({}));
            scheduler
                .control_request(&ctrl_method, ctrl_params)
                .map_err(|e| e.message)
        }
        other => Err(format!("Unknown FFI scheduler method: {other}")),
    }
}

/// # Safety
/// `root_dir` and `logs_dir` must be valid NUL-terminated UTF-8 paths; `out_error` may be NULL.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn rota_scheduler_create(
    root_dir: *const c_char,
    logs_dir: *const c_char,
    use_real_launcher: bool,
    callback_ctx: usize,
    callback: RotaEventCallback,
    out_error: *mut *mut c_char,
) -> *mut RotaSchedulerHandle {
    let (Some(root_str), Some(logs_str)) =
        (unsafe { cstr_to_str(root_dir) }, unsafe { cstr_to_str(logs_dir) })
    else {
        unsafe { write_out_error(out_error, "Invalid storage directory paths.") };
        return ptr::null_mut();
    };
    let location = StorageLocation::new(PathBuf::from(root_str), PathBuf::from(logs_str));
    let launcher: Arc<dyn RoutineLaunching> = if use_real_launcher {
        Arc::new(AgentLauncher::new())
    } else {
        Arc::new(DisabledTestLauncher)
    };
    let notifier: Option<Arc<dyn SchedulerNotifier>> = callback.is_some().then(|| {
        Arc::new(FfiNotifier {
            ctx: callback_ctx,
            callback,
        }) as Arc<dyn SchedulerNotifier>
    });
    match Scheduler::new(location, launcher, notifier) {
        Ok(scheduler) => Box::into_raw(Box::new(RotaSchedulerHandle { scheduler })),
        Err(err) => {
            unsafe { write_out_error(out_error, err) };
            ptr::null_mut()
        }
    }
}

/// # Safety
/// `handle` must be a valid pointer returned by `rota_scheduler_create`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn rota_scheduler_snapshot(handle: *const RotaSchedulerHandle) -> *mut c_char {
    if handle.is_null() {
        return err_envelope("Null scheduler handle");
    }
    let h = unsafe { &*handle };
    into_c_string(build_snapshot(&h.scheduler).to_string())
}

/// # Safety
/// `handle`, `method`, and `params_json` must be valid pointers.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn rota_scheduler_call(
    handle: *const RotaSchedulerHandle,
    method: *const c_char,
    params_json: *const c_char,
) -> *mut c_char {
    if handle.is_null() {
        return err_envelope("Null scheduler handle");
    }
    let h = unsafe { &*handle };
    let Some(method_str) = (unsafe { cstr_to_str(method) }) else {
        return err_envelope("Invalid method string");
    };
    let mut map = match unsafe { parse_json_map(params_json) } {
        Ok(m) => m,
        Err(e) => return err_envelope(e),
    };
    let rev_before = h.scheduler.revision();
    let res = dispatch_method(&h.scheduler, method_str, &mut map);
    let snap_opt = (h.scheduler.revision() != rev_before).then(|| build_snapshot(&h.scheduler));
    let mut envelope = Map::new();
    match res {
        Ok(val) => {
            envelope.insert("ok".into(), val);
        }
        Err(err) => {
            envelope.insert("error".into(), Value::String(err));
        }
    }
    if let Some(snap) = snap_opt {
        envelope.insert("snapshot".into(), snap);
    }
    into_c_string(Value::Object(envelope).to_string())
}

/// # Safety
/// `handle` must be either `NULL` or an un-freed pointer returned by `rota_scheduler_create`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn rota_scheduler_free(handle: *mut RotaSchedulerHandle) {
    if !handle.is_null() {
        unsafe {
            let _ = Box::from_raw(handle);
        }
    }
}
