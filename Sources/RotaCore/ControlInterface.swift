import Foundation

/// Every socket operation is declared here. Public operations must have a CLI command and an MCP tool.
public enum ControlMethod: String, CaseIterable, Sendable {
    case routinesList = "routines.list"
    case routinesGet = "routines.get"
    case routinesCreate = "routines.create"
    case routinesUpdate = "routines.update"
    case routinesSetEnabled = "routines.setEnabled"
    case routinesRun = "routines.run"
    case routinesStop = "routines.stop"
    case routinesDelete = "routines.delete"
    case sessionsList = "sessions.list"
    case sessionsRead = "sessions.read"
    case notify = "notify"
    case sessionsMessage = "sessions.message"
    case sessionsGet = "sessions.get"
    case sessionsDelete = "sessions.delete"
    case sessionsDismiss = "sessions.dismiss"
    case sessionsMarkRead = "sessions.markRead"
    case sessionsQuestions = "sessions.questions"
    case sessionsAnswer = "sessions.answer"
    case questionsCreate = "questions.create"
    case questionsPoll = "questions.poll"

    public var isPublic: Bool {
        switch self {
        case .questionsCreate, .questionsPoll: false  // Private Claude hook transport.
        default: true
        }
    }
}

/// Shared discovery for the terminal and MCP; bundled with the app on every build.
public enum ControlInterface {
    public struct Tool {
        public let name: String
        public let method: ControlMethod
        public let command: String
        public let description: String
        public let properties: [String: [String: Any]]
        public let required: [String]
    }

    /// Bind tools called inside a run to that run, while deletion always needs an explicit session.
    public static func sessionArguments(_ params: [String: Any], method: ControlMethod,
                                        environment: [String: String]) -> [String: Any] {
        var params = params
        guard params["session"] == nil, let session = environment["ROTA_SESSION"],
              method != .sessionsDelete else { return params }
        if method == .notify ? params["routine"] == nil
            : method.rawValue.hasPrefix("sessions.") && params["id"] as? String == environment["ROTA_ROUTINE"] {
            params["session"] = session
        }
        return params
    }

    private static func property(_ type: Any, _ description: String) -> [String: Any] {
        ["type": type, "description": description]
    }

    // Built per call: a stdio CLI answers a handful of requests, and the tables hold
    // JSON values (`[String: Any]`) that are not Sendable as stored statics.
    public static var tools: [Tool] {
        let id = property("string", "The routine's id, such as weekly-report.")
        let session = property("string", "A session id; the latest session when left out.")
        let fields: [String: [String: Any]] = [
            "id": id,
            "name": property("string", "A title for people; the id when left out."),
            "workingDirectory": property("string", "The project folder the routine runs in, an absolute path."),
            "schedule": property(
                "string",
                "Five-field cron in the Mac's local time, such as \"0 9 * * 1-5\" for weekdays at 9:00."),
            "harness": property(
                "string",
                "Where it runs: claude (Claude Code), codex, grok (Grok Build), antigravity (agy) or shell "
                    + "(a zsh command)."
            ).merging(["enum": Harness.allCases.map(\.rawValue)]) { $1 },
            "prompt": property("string", "What the agent is asked each run, or the command for shell."),
            "skill": property(
                "string",
                "A project skill in .claude/skills/<skill>/SKILL.md; writes the usual prompt that runs it."),
            "model": property(["string", "null"], "A model the harness's CLI lists; null for its default."),
            "effort": property(
                ["string", "null"],
                "Reasoning effort, such as low, medium or high; null for the model's default."),
            "timeLimitMinutes": property(
                ["integer", "null"],
                "Stop a run after this many minutes; null (the default) "
                    + "lets it take as long as it needs."),
            "enabled": property(
                "boolean", "Whether it runs on its schedule. New routines are on unless this is false."),
        ]

        return routineTools(id: id, fields: fields) + sessionTools(id: id, session: session)
    }

    private static func routineTools(id: [String: Any], fields: [String: [String: Any]]) -> [Tool] {
        [
            Tool(
                name: "list_routines", method: .routinesList, command: "list",
                description: "List Rota's scheduled routines with their schedules, harness, state and latest session.",
                properties: [:], required: []),
            Tool(
                name: "get_routine", method: .routinesGet, command: "show", description: "Show one routine.",
                properties: ["id": id], required: ["id"]),
            Tool(
                name: "create_routine", method: .routinesCreate, command: "add",
                description:
                    "Schedule a new routine in Rota. It runs unattended on its schedule with approvals bypassed, "
                    + "and Rota notifies the user that an agent added it. Give a prompt or a skill.",
                properties: fields, required: ["id", "workingDirectory", "schedule"]),
            Tool(
                name: "update_routine", method: .routinesUpdate, command: "update",
                description: "Change a routine; only the fields given change.", properties: fields, required: ["id"]),
            Tool(
                name: "set_routine_enabled", method: .routinesSetEnabled, command: "on",
                description: "Turn a routine on or off.",
                properties: ["id": id, "enabled": fields["enabled"]!], required: ["id", "enabled"]),
            Tool(
                name: "run_routine", method: .routinesRun, command: "run", description: "Start a run of a routine now.",
                properties: ["id": id], required: ["id"]),
            Tool(
                name: "stop_routine", method: .routinesStop, command: "stop",
                description: "Stop a routine's running session.",
                properties: ["id": id], required: ["id"]),
            Tool(
                name: "delete_routine", method: .routinesDelete, command: "remove",
                description: "Delete a routine and its session history. Ask the user first.",
                properties: ["id": id], required: ["id"]),
        ]
    }

    private static func sessionTools(id: [String: Any], session: [String: Any]) -> [Tool] {
        questionTools(id: id, session: session) + [
            Tool(
                name: "list_sessions", method: .sessionsList, command: "sessions",
                description: "A routine's recent sessions, newest first.",
                properties: ["id": id, "limit": property("integer", "How many; 10 by default.")],
                required: ["id"]),
            Tool(
                name: "read_session", method: .sessionsRead, command: "log",
                description: "A session's chat log: [you] lines are the prompt and messages, -> lines tools, "
                    + "the rest the agent.",
                properties: [
                    "id": id, "session": session,
                    "limit": property("integer", "Characters from the end; 20000 by default."),
                ],
                required: ["id"]),
            Tool(
                name: "notify_user", method: .notify, command: "notify",
                description: "Show the user a Mac notification from Rota. Inside a routine it opens this session; set "
                    + "needsReply when the user has to answer or confirm something, and the session stays marked until "
                    + "they reply in its chat.",
                properties: [
                    "message": property("string", "What the user should know or decide, in a sentence or two."),
                    "title": property("string", "A short title; the routine's name when left out."),
                    "needsReply": property(
                        "boolean", "Marks attention; this does not block the agent or grant approval."),
                    "session": session,
                    "routine": property("string", "The routine to notify from when session is omitted."),
                ],
                required: ["message"]),
            Tool(
                name: "message_session", method: .sessionsMessage, command: "send",
                description: "Send a message to a routine's session: it joins a running turn, or continues "
                    + "a finished session.",
                properties: [
                    "id": id, "session": session,
                    "text": property("string", "The message; may be empty with attachments."),
                    "attachments": [
                        "type": "array", "items": ["type": "string"],
                        "description": "Absolute paths of regular files to copy into the session.",
                    ],
                ],
                required: ["id", "text"]),
        ]
    }

    private static func questionTools(id: [String: Any], session: [String: Any]) -> [Tool] {
        [
            Tool(
                name: "get_session", method: .sessionsGet, command: "session",
                description: "Get session state, model, unread status, available actions and pending questions.",
                properties: ["id": id, "session": session], required: ["id"]),
            Tool(
                name: "delete_session", method: .sessionsDelete, command: "delete-session",
                description: "Delete a finished session and its local logs and attachments. Ask the user first. "
                    + "An explicit session id is required; the harness's own history is kept.",
                properties: ["id": id, "session": session], required: ["id", "session"]),
            Tool(
                name: "dismiss_session_attention", method: .sessionsDismiss, command: "dismiss",
                description: "Dismiss an attention mark without sending a reply. Pending questions must be answered.",
                properties: ["id": id, "session": session], required: ["id"]),
            Tool(
                name: "mark_session_read", method: .sessionsMarkRead, command: "mark-read",
                description: "Mark a session as read without changing its attention or pending questions.",
                properties: ["id": id, "session": session], required: ["id"]),
            Tool(
                name: "list_session_questions", method: .sessionsQuestions, command: "questions",
                description: "Read the session's pending structured questions, fields, options and action ids.",
                properties: ["id": id, "session": session], required: ["id"]),
            Tool(
                name: "answer_session_question", method: .sessionsAnswer, command: "answer",
                description: "Submit the user's explicit answer to a pending question. Never invent consent. "
                    + "Read questions first and use their field, option and action ids.",
                properties: [
                    "id": id, "session": session,
                    "question": property("string", "The pending question id."),
                    "action": property("string", "An offered action id, cancel or decline; required."),
                    "values": [
                        "type": "object", "additionalProperties": ["type": "array", "items": ["type": "string"]],
                        "description": "Field ids mapped to selected option ids or text values.",
                    ],
                ],
                required: ["id", "question", "action"]),
        ]
    }
}
