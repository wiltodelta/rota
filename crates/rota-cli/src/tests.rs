use std::collections::HashMap;
use std::io::Cursor;

use jiff::tz::TimeZone;
use rota_core::ControlError;
use serde_json::{Value, json};

use crate::format::{format_human, format_sorted_pretty_json};
use crate::mcp::McpServer;

#[test]
fn formatting_matches_cli_and_agent_check_contracts() {
    let tz = TimeZone::UTC;
    assert_eq!(format_human(&json!([]), "list", &tz), "No routines.");

    let routine = json!({
        "id": "cli-shell",
        "enabled": true,
        "running": false,
        "scheduleState": "scheduled",
        "harness": "shell",
        "schedule": "0 9 * * 1-5",
        "scheduleText": "Weekdays at 9:00 AM",
    });
    assert_eq!(
        format_human(&routine, "add", &tz),
        "cli-shell  on  shell  Weekdays at 9:00 AM"
    );

    let session = json!({
        "routine": "cli-shell",
        "outcome": "Running",
        "startedAt": "2026-11-22T17:00:00Z",
        "session": "6F1C2A3B-0001-4C1A-9E1A-52A2D9A4B001",
    });
    let run_out = format_human(&session, "run", &tz);
    assert!(run_out.starts_with("cli-shell  Running  "));
    assert!(run_out.contains("session 6F1C2A3B-0001-4C1A-9E1A-52A2D9A4B001"));

    let sessions_list = json!([{
        "session": "6F1C2A3B-0001-4C1A-9E1A-52A2D9A4B001",
        "startedAt": "2026-11-22T17:00:00Z",
        "outcome": "Succeeded",
        "needsReply": "Approve the invoice?",
    }]);
    let list_out = format_human(&sessions_list, "sessions", &tz);
    assert!(list_out.contains("Succeeded"));
    assert!(!list_out.contains('Z'));

    let pretty = format_sorted_pretty_json(&sessions_list);
    assert!(pretty.contains(r#""needsReply" : "Approve the invoice?""#));
    let reparsed: Value = serde_json::from_str(&pretty).unwrap();
    assert_eq!(reparsed, sessions_list);

    assert_eq!(
        format_human(&json!({"stopping": "cli-shell"}), "stop", &tz),
        "Stopping cli-shell"
    );
    assert_eq!(
        format_human(&json!({"deleted": "cli-shell"}), "remove", &tz),
        "Deleted cli-shell"
    );
}

#[test]
fn mcp_server_ignores_notifications_and_returns_tool_results_and_errors() {
    let mcp_in = [
        r#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#,
        r#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
        r#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
        r#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"get_routine","arguments":{"id":"cli-shell"}}}"#,
        r#"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"get_routine","arguments":{"id":"nope"}}}"#,
    ]
    .join("\n")
        + "\n";

    let mut out_buf = Vec::new();
    let mcp = McpServer::new(
        |method, params| {
            if method == "routines.get" && params.get("id").and_then(Value::as_str) == Some("cli-shell") {
                Ok(json!({"id": "cli-shell", "enabled": true}))
            } else {
                Err(ControlError::new("No routine nope."))
            }
        },
        HashMap::new(),
    );
    mcp.serve(Cursor::new(mcp_in.as_bytes()), &mut out_buf);
    let lines: Vec<&str> = std::str::from_utf8(&out_buf).unwrap().lines().collect();
    assert_eq!(lines.len(), 4);
    assert!(lines[1].contains("\"create_routine\""));
    assert!(lines[2].contains("cli-shell"));
    assert!(lines[3].contains("\"isError\":true"));
}
