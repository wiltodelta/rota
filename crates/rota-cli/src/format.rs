use std::io;

use jiff::tz::TimeZone;
use rota_core::model::serde_ext::{parse_iso_timestamp, sort_json_value};
use rota_core::schedule::ScheduleText;
use serde::Serialize;
use serde_json::{Map, Value};

pub const USAGE: &str = "\
Usage: rota <command> [options]

  list                         routines, their schedules and state
  calendar [<id>] [--from DATE] [--days N] [--paused]
                               recorded runs and upcoming scheduled slots by day
  show <id>                    one routine
  add <id> --folder DIR (--at ISO_DATE | --schedule \"CRON\") (--skill SKILL | --prompt TEXT)
      [--harness claude|codex|grok|antigravity|shell] [--name NAME] [--model M] [--effort E]
      [--repeat --at ISO_DATE] [--runs N] [--time-limit MIN] [--off]
  update <id> [the options of add] [--once] [--no-run-limit] [--no-time-limit] [--default-model]
  on <id> | off <id>           turn a routine on or off
  run <id> | stop <id>         start a run now, or stop the running one
  remove <id>                  delete a routine and its sessions
  sessions <id> [--limit N]    recent sessions
  log <id> [--session ID] [--limit CHARS]
  send <id> [TEXT] [--session ID] [--attach FILE]...   message a session (the latest by default)
  session <id> [--session ID]  state, model, available actions and questions
  questions <id> [--session ID]   pending structured questions
  answer <id> --question ID --action ACTION [--values JSON] [--session ID]
                               submit the user's explicit answer; values maps field ids to string arrays
  dismiss <id> [--session ID]  dismiss attention without answering questions
  mark-read <id> [--session ID]   mark a session as read
  mark-unread <id> [--session ID]   mark a finished session as unread
  delete-session <id> --session ID   delete a finished session and its local files; ask the user first
  tools                        discover commands and MCP schemas as JSON
  notify TEXT [--title T] [--needs-reply]
                               a notification from Rota; inside a routine it opens that
                               session, and --needs-reply marks it until you answer
  mcp                          serve these as MCP tools over stdio

Add --json for the raw answer. --at needs an ISO 8601 date, time and zone.
Repeating schedules use five-field cron in local time. --runs counts scheduled
attempts; manual runs and skips do not count. New routines are on unless --off is given.";

#[derive(Default)]
struct SpacedColonPrettyFormatter {
    indent: usize,
    has_value: bool,
}

impl serde_json::ser::Formatter for SpacedColonPrettyFormatter {
    fn begin_array<W: ?Sized + io::Write>(&mut self, writer: &mut W) -> io::Result<()> {
        self.indent += 1;
        self.has_value = false;
        writer.write_all(b"[")
    }

    fn end_array<W: ?Sized + io::Write>(&mut self, writer: &mut W) -> io::Result<()> {
        self.indent -= 1;
        if self.has_value {
            writer.write_all(b"\n")?;
            write_indent(writer, self.indent)?;
        }
        writer.write_all(b"]")
    }

    fn begin_array_value<W: ?Sized + io::Write>(&mut self, writer: &mut W, first: bool) -> io::Result<()> {
        writer.write_all(if first { b"\n" } else { b",\n" })?;
        write_indent(writer, self.indent)
    }

    fn end_array_value<W: ?Sized + io::Write>(&mut self, _writer: &mut W) -> io::Result<()> {
        self.has_value = true;
        Ok(())
    }

    fn begin_object<W: ?Sized + io::Write>(&mut self, writer: &mut W) -> io::Result<()> {
        self.indent += 1;
        self.has_value = false;
        writer.write_all(b"{")
    }

    fn end_object<W: ?Sized + io::Write>(&mut self, writer: &mut W) -> io::Result<()> {
        self.indent -= 1;
        if self.has_value {
            writer.write_all(b"\n")?;
            write_indent(writer, self.indent)?;
        }
        writer.write_all(b"}")
    }

    fn begin_object_key<W: ?Sized + io::Write>(&mut self, writer: &mut W, first: bool) -> io::Result<()> {
        writer.write_all(if first { b"\n" } else { b",\n" })?;
        write_indent(writer, self.indent)
    }

    fn begin_object_value<W: ?Sized + io::Write>(&mut self, writer: &mut W) -> io::Result<()> {
        writer.write_all(b" : ")
    }

    fn end_object_value<W: ?Sized + io::Write>(&mut self, _writer: &mut W) -> io::Result<()> {
        self.has_value = true;
        Ok(())
    }
}

fn write_indent<W: ?Sized + io::Write>(writer: &mut W, n: usize) -> io::Result<()> {
    for _ in 0..n {
        writer.write_all(b"  ")?;
    }
    Ok(())
}

pub fn format_sorted_pretty_json(value: &Value) -> String {
    let sorted = sort_json_value(value.clone());
    let mut buf = Vec::new();
    let mut ser = serde_json::Serializer::with_formatter(&mut buf, SpacedColonPrettyFormatter::default());
    let _ = sorted.serialize(&mut ser);
    String::from_utf8_lossy(&buf).into_owned()
}

pub fn local_time(value: Option<&Value>, include_date: bool, tz: &TimeZone) -> String {
    let Some(text) = value.and_then(Value::as_str) else {
        return String::new();
    };
    let Some(ts) = parse_iso_timestamp(text) else {
        return String::new();
    };
    if include_date {
        ScheduleText::format_abbreviated_date_time(ts, tz)
    } else {
        ScheduleText::format_short_time(ts, tz)
    }
}

pub fn routine_line(routine: &Map<String, Value>) -> String {
    let inactive = if routine.get("scheduleState").and_then(Value::as_str) == Some("completed") {
        "completed"
    } else if routine.get("enabled").and_then(Value::as_bool) == Some(true) {
        "on"
    } else {
        "off"
    };
    let state = if routine.get("running").and_then(Value::as_bool) == Some(true) {
        "running"
    } else {
        inactive
    };
    let id = routine.get("id").and_then(Value::as_str).unwrap_or("?");
    let harness = routine.get("harness").and_then(Value::as_str).unwrap_or("");
    let sched_text = routine.get("scheduleText").and_then(Value::as_str).unwrap_or("");
    let model = routine.get("model").and_then(Value::as_str).unwrap_or("");
    [id, state, harness, sched_text, model]
        .into_iter()
        .filter(|s| !s.is_empty())
        .collect::<Vec<_>>()
        .join("  ")
}

pub fn session_line(session: &Map<String, Value>, tz: &TimeZone) -> String {
    let routine = session.get("routine").and_then(Value::as_str).unwrap_or("?");
    let outcome = session.get("outcome").and_then(Value::as_str).unwrap_or("");
    let started = local_time(session.get("startedAt"), true, tz);
    let sess_id = session.get("session").and_then(Value::as_str).unwrap_or("");
    let sess_tag = format!("session {sess_id}");
    let mut parts = vec![routine.to_string(), outcome.to_string(), started, sess_tag];
    if let Some(q) = session.get("needsReply").and_then(Value::as_str) {
        parts.push(format!("needs reply: {q}"));
    }
    parts
        .into_iter()
        .filter(|s| !s.is_empty())
        .collect::<Vec<_>>()
        .join("  ")
}

pub fn calendar_text(payload: &Map<String, Value>, tz: &TimeZone) -> String {
    let days: Vec<&Map<String, Value>> = payload
        .get("calendar")
        .and_then(Value::as_array)
        .map(|arr| {
            arr.iter()
                .filter_map(Value::as_object)
                .filter(|d| {
                    d.get("entries")
                        .and_then(Value::as_array)
                        .is_some_and(|e| !e.is_empty())
                })
                .collect()
        })
        .unwrap_or_default();
    if days.is_empty() {
        return "No runs or scheduled slots in this range.".to_string();
    }
    days.into_iter()
        .map(|day| {
            let raw_date = day.get("date").and_then(Value::as_str).unwrap_or("");
            let base_header = ScheduleText::format_day_header(raw_date, tz);
            let header = if day.get("isToday").and_then(Value::as_bool) == Some(true) {
                format!("{base_header} (Today)")
            } else {
                base_header
            };
            let mut lines = vec![header];
            if let Some(entries) = day.get("entries").and_then(Value::as_array) {
                for entry in entries.iter().filter_map(Value::as_object) {
                    let start = local_time(entry.get("startedAt"), false, tz);
                    let count = entry.get("count").and_then(Value::as_u64).unwrap_or(1);
                    let span = if count > 1 {
                        format!("{start} - {}", local_time(entry.get("endedAt"), false, tz))
                    } else {
                        start
                    };
                    let status = entry.get("status").and_then(Value::as_str).unwrap_or("");
                    let suffix = if count > 1 {
                        format!("{status} ({count} runs)")
                    } else {
                        status.to_string()
                    };
                    let routine = entry.get("routine").and_then(Value::as_str).unwrap_or("?");
                    let harness = entry.get("harness").and_then(Value::as_str).unwrap_or("");
                    let name = entry.get("name").and_then(Value::as_str).unwrap_or("");
                    let joined = [span.as_str(), routine, harness, suffix.as_str(), name]
                        .into_iter()
                        .filter(|s| !s.is_empty())
                        .collect::<Vec<_>>()
                        .join("  ");
                    lines.push(format!("  {joined}"));
                }
            }
            lines.join("\n")
        })
        .collect::<Vec<_>>()
        .join("\n\n")
}

pub fn format_human(result: &Value, canonical_command: &str, tz: &TimeZone) -> String {
    match (canonical_command, result) {
        ("list", Value::Array(routines)) => {
            if routines.is_empty() {
                "No routines.".to_string()
            } else {
                routines
                    .iter()
                    .filter_map(Value::as_object)
                    .map(routine_line)
                    .collect::<Vec<_>>()
                    .join("\n")
            }
        }
        ("calendar", Value::Object(overview)) => calendar_text(overview, tz),
        ("sessions", Value::Array(sessions)) => sessions
            .iter()
            .filter_map(Value::as_object)
            .map(|s| {
                let id = s.get("session").and_then(Value::as_str).unwrap_or("");
                let started = local_time(s.get("startedAt"), true, tz);
                let outcome = s.get("outcome").and_then(Value::as_str).unwrap_or("");
                format!("{id}  {started}  {outcome}")
            })
            .collect::<Vec<_>>()
            .join("\n"),
        ("log", Value::Object(session)) => session
            .get("log")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string(),
        (_, Value::Object(obj)) if obj.contains_key("schedule") => routine_line(obj),
        (cmd, Value::Object(obj)) if obj.contains_key("session") && cmd != "notify" && cmd != "session" => {
            session_line(obj, tz)
        }
        (_, Value::Object(obj)) if obj.len() == 1 && obj.values().next().is_some_and(Value::is_string) => {
            let (k, v) = obj.iter().next().unwrap();
            let mut chars = k.chars();
            let cap = match chars.next() {
                Some(first) => format!("{}{}", first.to_ascii_uppercase(), chars.as_str()),
                None => String::new(),
            };
            format!("{cap} {}", v.as_str().unwrap_or(""))
        }
        _ => format_sorted_pretty_json(result),
    }
}
