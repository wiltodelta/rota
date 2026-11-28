use serde_json::{Map, Value, json};

use crate::control::{ControlInterface, ControlMethod, ControlTool};
use crate::model::Harness;

impl ControlInterface {
    pub fn tools() -> Vec<ControlTool> {
        let id = Self::prop(json!("string"), "The routine's id, such as weekly-report.");
        let session = Self::prop(json!("string"), "A session id; the latest session when left out.");
        let fields = Self::routine_fields(&id);
        let mut out = Self::routine_tools(&id, &fields);
        out.extend(Self::question_tools(&id, &session));
        out.extend(Self::session_tools(&id, &session));
        out
    }

    fn routine_fields(id: &Value) -> Map<String, Value> {
        let harness_enum: Vec<&str> = Harness::ALL.iter().map(|h| h.as_str()).collect();
        let mut m = Map::new();
        m.insert("id".into(), id.clone());
        m.insert(
            "name".into(),
            Self::prop(json!("string"), "A title for people; the id when left out."),
        );
        m.insert(
            "workingDirectory".into(),
            Self::prop(
                json!("string"),
                "The project folder the routine runs in, an absolute path.",
            ),
        );
        m.insert(
            "schedule".into(),
            Self::prop(
                json!("string"),
                "Five-field cron in the Mac's local time, such as \"0 9 * * 1-5\" for weekdays at 9:00.",
            ),
        );
        m.insert(
            "scheduledAt".into(),
            Self::prop(
                json!(["string", "null"]),
                "ISO 8601 date and time with Z or an offset. Without schedule, runs once. \
With a repeating schedule, this is its earliest start; null clears that bound.",
            ),
        );
        m.insert(
            "repeats".into(),
            Self::prop(
                json!("boolean"),
                "False for one time (scheduledAt required); true for cron repetition.",
            ),
        );
        m.insert(
            "runLimit".into(),
            Self::prop(
                json!(["integer", "null"]),
                "End repetition after this many scheduled attempts in total; null is unlimited. \
Manual runs and skipped slots do not count. Changing scheduling fields resets the count.",
            ),
        );
        m.insert(
            "harness".into(),
            json!({
                "type": "string",
                "description": "Where it runs: claude (Claude Code), codex, grok (Grok Build), antigravity (agy) or shell (a zsh command).",
                "enum": harness_enum,
            }),
        );
        m.insert(
            "prompt".into(),
            Self::prop(
                json!("string"),
                "What the agent is asked each run, or the command for shell.",
            ),
        );
        m.insert(
            "skill".into(),
            Self::prop(
                json!("string"),
                "A project skill in .claude/skills/<skill>/SKILL.md; writes the usual prompt that runs it.",
            ),
        );
        m.insert(
            "model".into(),
            Self::prop(
                json!(["string", "null"]),
                "A model the harness's CLI lists; null for its default.",
            ),
        );
        m.insert(
            "effort".into(),
            Self::prop(
                json!(["string", "null"]),
                "Reasoning effort, such as low, medium or high; null for the model's default.",
            ),
        );
        m.insert(
            "timeLimitMinutes".into(),
            Self::prop(
                json!(["integer", "null"]),
                "Stop a run after this many minutes; null (the default) lets it take as long as it needs.",
            ),
        );
        m.insert(
            "enabled".into(),
            Self::prop(
                json!("boolean"),
                "Whether it runs on its schedule. New routines are on unless this is false.",
            ),
        );
        m
    }

    fn routine_tools(id: &Value, fields: &Map<String, Value>) -> Vec<ControlTool> {
        vec![
            ControlTool {
                name: "list_routines",
                method: ControlMethod::RoutinesList,
                command: "list",
                description:
                    "List Rota's scheduled routines with their schedules, harness, state and latest session."
                        .into(),
                properties: Map::new(),
                required: Vec::new(),
            },
            ControlTool {
                name: "get_calendar",
                method: ControlMethod::RoutinesCalendar,
                command: "calendar",
                description:
                    "Show Rota's schedule calendar of recorded runs and upcoming scheduled slots by local day."
                        .into(),
                properties: Self::map_of(&[
                    (
                        "id",
                        Self::prop(json!("string"), "Optional routine id to filter to one routine."),
                    ),
                    (
                        "from",
                        Self::prop(
                            json!("string"),
                            "Start date in YYYY-MM-DD (local time) or ISO 8601; today by default.",
                        ),
                    ),
                    (
                        "days",
                        Self::prop(
                            json!("integer"),
                            "Number of local calendar days to cover (1 to 366; 7 by default).",
                        ),
                    ),
                    (
                        "includePaused",
                        Self::prop(
                            json!("boolean"),
                            "Include projected slots of paused routines (false by default).",
                        ),
                    ),
                ]),
                required: Vec::new(),
            },
            ControlTool {
                name: "get_routine",
                method: ControlMethod::RoutinesGet,
                command: "show",
                description: "Show one routine.".into(),
                properties: Self::map_of(&[("id", id.clone())]),
                required: vec!["id"],
            },
            ControlTool {
                name: "create_routine",
                method: ControlMethod::RoutinesCreate,
                command: "add",
                description: "Schedule a new routine in Rota. It runs unattended on its schedule with approvals bypassed, \
and Rota notifies the user that an agent added it. Give a prompt or a skill, and either \
scheduledAt for one time or schedule for repetition."
                    .into(),
                properties: fields.clone(),
                required: vec!["id", "workingDirectory"],
            },
            ControlTool {
                name: "update_routine",
                method: ControlMethod::RoutinesUpdate,
                command: "update",
                description: "Change a routine; only the fields given change.".into(),
                properties: fields.clone(),
                required: vec!["id"],
            },
            ControlTool {
                name: "set_routine_enabled",
                method: ControlMethod::RoutinesSetEnabled,
                command: "on",
                description: "Turn a routine on or off.".into(),
                properties: Self::map_of(&[
                    ("id", id.clone()),
                    ("enabled", fields["enabled"].clone()),
                ]),
                required: vec!["id", "enabled"],
            },
            ControlTool {
                name: "run_routine",
                method: ControlMethod::RoutinesRun,
                command: "run",
                description: "Start a run of a routine now.".into(),
                properties: Self::map_of(&[("id", id.clone())]),
                required: vec!["id"],
            },
            ControlTool {
                name: "stop_routine",
                method: ControlMethod::RoutinesStop,
                command: "stop",
                description: "Stop all running sessions of a routine.".into(),
                properties: Self::map_of(&[("id", id.clone())]),
                required: vec!["id"],
            },
            ControlTool {
                name: "delete_routine",
                method: ControlMethod::RoutinesDelete,
                command: "remove",
                description: "Delete a routine and its session history. Ask the user first.".into(),
                properties: Self::map_of(&[("id", id.clone())]),
                required: vec!["id"],
            },
        ]
    }

    fn question_tools(id: &Value, session: &Value) -> Vec<ControlTool> {
        let both = Self::map_of(&[("id", id.clone()), ("session", session.clone())]);
        vec![
            ControlTool {
                name: "get_session",
                method: ControlMethod::SessionsGet,
                command: "session",
                description:
                    "Get session state, model, unread status, available actions and pending questions.".into(),
                properties: both.clone(),
                required: vec!["id"],
            },
            ControlTool {
                name: "delete_session",
                method: ControlMethod::SessionsDelete,
                command: "delete-session",
                description:
                    "Delete a finished session and its local logs and attachments. Ask the user first. \
An explicit session id is required; the harness's own history is kept."
                        .into(),
                properties: both.clone(),
                required: vec!["id", "session"],
            },
            ControlTool {
                name: "dismiss_session_attention",
                method: ControlMethod::SessionsDismiss,
                command: "dismiss",
                description:
                    "Dismiss an attention mark without sending a reply. Pending questions must be answered."
                        .into(),
                properties: both.clone(),
                required: vec!["id"],
            },
            ControlTool {
                name: "mark_session_read",
                method: ControlMethod::SessionsMarkRead,
                command: "mark-read",
                description: "Mark a session as read without changing its attention or pending questions."
                    .into(),
                properties: both.clone(),
                required: vec!["id"],
            },
            ControlTool {
                name: "mark_session_unread",
                method: ControlMethod::SessionsMarkUnread,
                command: "mark-unread",
                description: "Mark a finished, read session as unread so it stays in the user's inbox."
                    .into(),
                properties: both.clone(),
                required: vec!["id"],
            },
            ControlTool {
                name: "list_session_questions",
                method: ControlMethod::SessionsQuestions,
                command: "questions",
                description:
                    "Read the session's pending structured questions, fields, options and action ids.".into(),
                properties: both,
                required: vec!["id"],
            },
            ControlTool {
                name: "answer_session_question",
                method: ControlMethod::SessionsAnswer,
                command: "answer",
                description:
                    "Submit the user's explicit answer to a pending question. Never invent consent. \
Read questions first and use their field, option and action ids."
                        .into(),
                properties: Self::map_of(&[
                    ("id", id.clone()),
                    ("session", session.clone()),
                    (
                        "question",
                        Self::prop(json!("string"), "The pending question id."),
                    ),
                    (
                        "action",
                        Self::prop(
                            json!("string"),
                            "An offered action id, cancel or decline; required.",
                        ),
                    ),
                    (
                        "values",
                        json!({
                            "type": "object",
                            "additionalProperties": {"type": "array", "items": {"type": "string"}},
                            "description": "Field ids mapped to selected option ids or text values.",
                        }),
                    ),
                ]),
                required: vec!["id", "question", "action"],
            },
        ]
    }

    fn session_tools(id: &Value, session: &Value) -> Vec<ControlTool> {
        vec![
            ControlTool {
                name: "list_sessions",
                method: ControlMethod::SessionsList,
                command: "sessions",
                description: "A routine's recent sessions, newest first.".into(),
                properties: Self::map_of(&[
                    ("id", id.clone()),
                    ("limit", Self::prop(json!("integer"), "How many; 10 by default.")),
                ]),
                required: vec!["id"],
            },
            ControlTool {
                name: "read_session",
                method: ControlMethod::SessionsRead,
                command: "log",
                description: "A session's chat log: [you] lines are the prompt and messages, -> lines tools, the rest the agent.".into(),
                properties: Self::map_of(&[
                    ("id", id.clone()),
                    ("session", session.clone()),
                    ("limit", Self::prop(json!("integer"), "Characters from the end; 20000 by default.")),
                ]),
                required: vec!["id"],
            },
            ControlTool {
                name: "notify_user",
                method: ControlMethod::Notify,
                command: "notify",
                description: "Show the user a Mac notification from Rota. Inside a routine it opens this session; set \
needsReply when the user has to answer or confirm something, and the session stays marked until they reply in its chat.".into(),
                properties: Self::map_of(&[
                    ("message", Self::prop(json!("string"), "What the user should know or decide, in a sentence or two.")),
                    ("title", Self::prop(json!("string"), "A short title; the routine's name when left out.")),
                    ("needsReply", Self::prop(json!("boolean"), "Marks attention; this does not block the agent or grant approval.")),
                    ("session", session.clone()),
                    ("routine", Self::prop(json!("string"), "The routine to notify from when session is omitted.")),
                ]),
                required: vec!["message"],
            },
            ControlTool {
                name: "message_session",
                method: ControlMethod::SessionsMessage,
                command: "send",
                description: "Send a message to a routine's session: it joins a running turn, or continues a finished session.".into(),
                properties: Self::map_of(&[
                    ("id", id.clone()),
                    ("session", session.clone()),
                    ("text", Self::prop(json!("string"), "The message; may be empty with attachments.")),
                    ("attachments", json!({
                        "type": "array",
                        "items": {"type": "string"},
                        "description": "Absolute paths of regular files to copy into the session.",
                    })),
                ]),
                required: vec!["id", "text"],
            },
        ]
    }
}
