use std::collections::HashMap;
use std::ffi::c_char;
use std::path::{Path, PathBuf};
use std::time::Duration;

use jiff::Timestamp;
use jiff::tz::TimeZone;
use rota_core::model::serde_ext::{format_iso_timestamp, parse_iso_timestamp};
use rota_core::{
    AgentAccess, CalendarDay, CalendarEntry, CalendarEntryKind, CalendarQuery, ClaudeConfiguration,
    CliArguments, ControlCli, ControlClient, ExecutableDiscovery, Harness, ImportCandidate,
    InstalledExecutable, ModelCatalog, Routine, RoutineImport, RunRecord, ScheduleCalendar, ScheduleText,
    SessionRestart, TranscriptItem,
};
use serde_json::{Map, Value, json};

use crate::{
    cstr_to_str, err_envelope, ok_envelope, parse_harness_field, parse_json_map, take_field, take_or_default,
};

fn serialize_calendar_entry(entry: CalendarEntry) -> Value {
    let kind_val = match entry.kind {
        CalendarEntryKind::Record(rec) => json!({ "type": "record", "record": rec }),
        CalendarEntryKind::Scheduled { paused } => json!({ "type": "scheduled", "paused": paused }),
    };
    json!({
        "id": entry.id,
        "routineID": entry.routine_id,
        "routineName": entry.routine_name,
        "harness": entry.harness,
        "start": format_iso_timestamp(entry.start),
        "end": entry.end.map(format_iso_timestamp),
        "count": entry.count,
        "scheduleSummary": entry.schedule_summary,
        "kind": kind_val,
    })
}

fn serialize_calendar_day(day: CalendarDay) -> Value {
    json!({
        "id": day.id,
        "date": format_iso_timestamp(day.date),
        "isToday": day.is_today,
        "entries": day.entries.into_iter().map(serialize_calendar_entry).collect::<Vec<_>>(),
    })
}

fn resolve_tz(params: &Map<String, Value>) -> TimeZone {
    params
        .get("timeZone")
        .and_then(Value::as_str)
        .and_then(|id| TimeZone::get(id).ok())
        .unwrap_or_else(TimeZone::system)
}

fn resolve_home(params: &Map<String, Value>) -> PathBuf {
    params
        .get("home")
        .and_then(Value::as_str)
        .map(PathBuf::from)
        .unwrap_or_else(rota_platform::home_dir)
}

fn req_ts(params: &Map<String, Value>, key: &str) -> Result<Timestamp, String> {
    let raw = params
        .get(key)
        .and_then(Value::as_str)
        .ok_or_else(|| format!("Missing timestamp {key}"))?;
    parse_iso_timestamp(raw).ok_or_else(|| format!("Invalid ISO timestamp {raw}"))
}

fn dispatch_core(method: &str, params: &mut Map<String, Value>) -> Result<Value, String> {
    match method {
        "scheduleText.describe" => {
            let expr = params.get("expression").and_then(Value::as_str).unwrap_or("");
            Ok(json!(ScheduleText::describe(expr)))
        }
        "calendar.parseAnchor" => {
            let text = params.get("text").and_then(Value::as_str).unwrap_or("");
            let tz = resolve_tz(params);
            Ok(json!(
                ScheduleCalendar::parse_calendar_anchor(text, &tz).map(format_iso_timestamp)
            ))
        }
        "calendar.agendaInterval" => {
            let anchor = req_ts(params, "anchor")?;
            let days = params.get("days").and_then(Value::as_i64).unwrap_or(7).max(1) as usize;
            let tz = resolve_tz(params);
            let (start, end) = ScheduleCalendar::agenda_interval(anchor, days, &tz);
            Ok(json!({
                "start": format_iso_timestamp(start),
                "end": format_iso_timestamp(end),
            }))
        }
        "calendar.dayIdentifier" => {
            let date = req_ts(params, "date")?;
            let tz = resolve_tz(params);
            Ok(json!(ScheduleCalendar::day_identifier(date, &tz)))
        }
        "calendar.days" => {
            let query = CalendarQuery {
                start: req_ts(params, "start")?,
                end: req_ts(params, "end")?,
                now: req_ts(params, "now")?,
                include_paused: params
                    .get("includePaused")
                    .and_then(Value::as_bool)
                    .unwrap_or(false),
                routine_id: params
                    .get("routineID")
                    .and_then(Value::as_str)
                    .map(ToOwned::to_owned),
                tz: resolve_tz(params),
            };
            let routines: Vec<Routine> = take_or_default(params, "routines")?;
            let records: Vec<RunRecord> = take_or_default(params, "records")?;
            let days = ScheduleCalendar::days(&query, &routines, &records);
            Ok(Value::Array(
                days.into_iter().map(serialize_calendar_day).collect(),
            ))
        }
        "import.scanAll" => {
            let home = resolve_home(params);
            serde_json::to_value(RoutineImport::scan_all_in(&home)).map_err(|e| e.to_string())
        }
        "import.isImported" => {
            let cand: ImportCandidate = take_field(params, "candidate")?;
            let routines: Vec<Routine> = take_or_default(params, "routines")?;
            Ok(json!(RoutineImport::is_imported(&cand, &routines)))
        }
        "import.routineToImport" => {
            let cand: ImportCandidate = take_field(params, "candidate")?;
            let existing: Vec<Routine> = take_or_default(params, "existing")?;
            serde_json::to_value(RoutineImport::routine_to_import(&cand, &existing))
                .map_err(|e| e.to_string())
        }
        "discovery.installedAgents" => {
            let map: HashMap<String, Vec<InstalledExecutable>> = ExecutableDiscovery::installed_agents()
                .into_iter()
                .map(|(h, list)| (h.as_str().to_string(), list))
                .collect();
            serde_json::to_value(map).map_err(|e| e.to_string())
        }
        "catalog.models" => {
            let h_raw = params.get("harness").and_then(Value::as_str).unwrap_or("");
            let Some(harness) = Harness::parse(h_raw) else {
                return Ok(json!([]));
            };
            let exe = params.get("executable").and_then(Value::as_str).unwrap_or("");
            serde_json::to_value(ModelCatalog::models(harness, exe)).map_err(|e| e.to_string())
        }
        "claudeConfig.read" => {
            let exe = params.get("executable").and_then(Value::as_str).unwrap_or("");
            let dir = params.get("directory").and_then(Value::as_str).unwrap_or("/tmp");
            let model = params.get("model").and_then(Value::as_str);
            let effort = params.get("effort").and_then(Value::as_str);
            let resume = params.get("resume").and_then(Value::as_str);
            let secs = params
                .get("timeoutSecs")
                .and_then(Value::as_f64)
                .unwrap_or(8.0)
                .max(0.1);
            let found = ClaudeConfiguration::read(
                exe,
                Path::new(dir),
                model,
                effort,
                resume,
                Duration::from_secs_f64(secs),
            );
            Ok(match found {
                Some(cfg) => json!({ "session": cfg.session, "models": cfg.models }),
                None => Value::Null,
            })
        }
        "agentAccess.isAdded" => {
            let h_raw = params.get("harness").and_then(Value::as_str).unwrap_or("");
            let Some(harness) = Harness::parse(h_raw) else {
                return Ok(json!(false));
            };
            let exe = params.get("executable").and_then(Value::as_str).unwrap_or("");
            Ok(json!(AgentAccess::is_added(harness, exe)))
        }
        "agentAccess.change" => {
            let harness = parse_harness_field(params, "harness")?;
            let add = params.get("add").and_then(Value::as_bool).unwrap_or(false);
            let exe = params.get("executable").and_then(Value::as_str).unwrap_or("");
            let cmd = params.get("command").and_then(Value::as_str).unwrap_or("");
            Ok(json!(AgentAccess::change(harness, add, exe, cmd)))
        }
        "agentAccess.installCommand" => {
            let link = params
                .get("link")
                .and_then(Value::as_str)
                .ok_or("Missing link.")?;
            let helper = params
                .get("helper")
                .and_then(Value::as_str)
                .ok_or("Missing helper.")?;
            AgentAccess::install_command(Path::new(link), Path::new(helper))?;
            Ok(json!(true))
        }
        "agentAccess.commandInstalled" => {
            let link = params.get("link").and_then(Value::as_str).unwrap_or("");
            let helper = params.get("helper").and_then(Value::as_str).unwrap_or("");
            Ok(json!(AgentAccess::command_installed(
                Path::new(link),
                Path::new(helper)
            )))
        }
        "sessionRestart.hitUsageLimit" => {
            let items: Vec<TranscriptItem> = take_or_default(params, "items")?;
            Ok(json!(SessionRestart::hit_usage_limit(&items)))
        }
        "control.cliRequest" => {
            let cmd = params
                .remove("command")
                .and_then(|v| v.as_str().map(ToOwned::to_owned))
                .unwrap_or_default();
            let raw: Vec<String> = take_or_default(params, "arguments")?;
            let parsed = CliArguments::parse(&raw).map_err(|e| e.message)?;
            let (method, req_params) =
                ControlCli::request(&cmd, &parsed, &HashMap::new()).map_err(|e| e.message)?;
            Ok(json!({ "method": method, "params": req_params }))
        }
        "control.clientCall" => {
            let m = params
                .remove("method")
                .and_then(|v| v.as_str().map(ToOwned::to_owned))
                .unwrap_or_default();
            let p = params.remove("params").unwrap_or_else(|| json!({}));
            let sock = params
                .remove("socket")
                .and_then(|v| v.as_str().map(ToOwned::to_owned))
                .unwrap_or_default();
            let secs = params
                .get("timeoutSecs")
                .and_then(Value::as_f64)
                .unwrap_or(5.0)
                .max(0.1);
            ControlClient::call(&m, p, Path::new(&sock), Duration::from_secs_f64(secs)).map_err(|e| e.message)
        }
        other => Err(format!("Unknown FFI core method: {other}")),
    }
}

/// # Safety
/// `method` and `params_json` must be valid NUL-terminated UTF-8 strings (or `params_json` NULL).
#[unsafe(no_mangle)]
pub unsafe extern "C" fn rota_core_call(method: *const c_char, params_json: *const c_char) -> *mut c_char {
    let Some(method_str) = (unsafe { cstr_to_str(method) }) else {
        return err_envelope("Invalid method string.");
    };
    let mut map = match unsafe { parse_json_map(params_json) } {
        Ok(m) => m,
        Err(e) => return err_envelope(e),
    };
    match dispatch_core(method_str, &mut map) {
        Ok(val) => ok_envelope(val),
        Err(err) => err_envelope(err),
    }
}
