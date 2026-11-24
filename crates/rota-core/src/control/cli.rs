use std::collections::{HashMap, HashSet};

use rota_platform::expand_tilde;
use serde_json::{Map, Value, json};

use crate::control::{ControlError, ControlInterface, ControlMethod};

#[derive(Debug, Clone, Default)]
pub struct CliArguments {
    pub positional: Vec<String>,
    pub options: HashMap<String, String>,
    pub attachments: Vec<String>,
    pub flags: HashSet<String>,
}

impl CliArguments {
    const FLAG_NAMES: [&'static str; 12] = [
        "json",
        "off",
        "disabled",
        "no-time-limit",
        "default-model",
        "help",
        "version",
        "needs-reply",
        "once",
        "repeat",
        "no-run-limit",
        "paused",
    ];

    pub fn parse(raw: &[String]) -> Result<Self, ControlError> {
        let mut args = Self::default();
        let mut index = 0usize;
        while index < raw.len() {
            let word = &raw[index];
            if word == "-h" {
                args.flags.insert("help".to_string());
            } else if word == "-V" {
                args.flags.insert("version".to_string());
            } else if let Some(name) = word.strip_prefix("--") {
                if Self::FLAG_NAMES.contains(&name) {
                    args.flags.insert(name.to_string());
                } else {
                    index += 1;
                    let Some(value) = raw.get(index) else {
                        return Err(ControlError::new(format!("--{name} needs a value.")));
                    };
                    if name == "attach" {
                        args.attachments.push(value.clone());
                    } else {
                        args.options.insert(name.to_string(), value.clone());
                    }
                }
            } else {
                args.positional.push(word.clone());
            }
            index += 1;
        }
        Ok(args)
    }
}

/// Translates CLI invocations into control-socket `(method, params)` requests.
pub struct ControlCli;

impl ControlCli {
    /// Maps aliases (`get` -> `show`, `create` -> `add`, `enable` -> `on`, `disable` -> `off`,
    /// `delete` -> `remove`, `read` -> `mark-read`, `unread` -> `mark-unread`, `message` -> `send`)
    /// to canonical CLI verb names.
    pub fn canonical_command(command: &str) -> &str {
        match command {
            "get" => "show",
            "create" => "add",
            "enable" => "on",
            "disable" => "off",
            "delete" => "remove",
            "read" => "mark-read",
            "unread" => "mark-unread",
            "message" => "send",
            other => other,
        }
    }

    pub fn request(
        command: &str,
        arguments: &CliArguments,
        environment: &HashMap<String, String>,
    ) -> Result<(String, Value), ControlError> {
        let canonical = Self::canonical_command(command);
        let lookup = if canonical == "off" { "on" } else { canonical };
        let Some(tool) = ControlInterface::tools()
            .into_iter()
            .find(|t| t.command == lookup)
        else {
            return Err(ControlError::new(format!(
                "Unknown command {command}. Run rota help."
            )));
        };

        if tool.method == ControlMethod::RoutinesList {
            return Ok((tool.method.as_str().to_string(), json!({})));
        }
        if tool.method == ControlMethod::RoutinesCalendar {
            return Ok((
                tool.method.as_str().to_string(),
                Value::Object(Self::calendar_params(arguments)?),
            ));
        }
        if tool.method == ControlMethod::Notify {
            let words = arguments.positional.get(1..).unwrap_or(&[]);
            let params = Self::notify_params(words, arguments)?;
            let bound = ControlInterface::session_arguments(params, tool.method, environment);
            return Ok((tool.method.as_str().to_string(), Value::Object(bound)));
        }

        let Some(id) = arguments.positional.get(1) else {
            return Err(ControlError::new(format!("{command} needs a routine id.")));
        };
        let mut params = Map::new();
        params.insert("id".to_string(), Value::String(id.clone()));
        if let Some(session) = arguments.options.get("session") {
            params.insert("session".to_string(), Value::String(session.clone()));
        }
        if let Some(limit) = arguments.options.get("limit") {
            let number: i64 = limit
                .parse()
                .map_err(|_| ControlError::new("--limit needs an integer."))?;
            params.insert("limit".to_string(), json!(number));
        }
        for (k, v) in Self::command_fields(tool.method, canonical, arguments)? {
            params.insert(k, v);
        }
        if tool.method == ControlMethod::SessionsDelete && !params.contains_key("session") {
            return Err(ControlError::new(
                "delete-session needs an explicit --session ID.",
            ));
        }
        let bound = ControlInterface::session_arguments(params, tool.method, environment);
        Ok((tool.method.as_str().to_string(), Value::Object(bound)))
    }

    fn command_fields(
        method: ControlMethod,
        canonical_command: &str,
        arguments: &CliArguments,
    ) -> Result<Map<String, Value>, ControlError> {
        let mut params = Map::new();
        match method {
            ControlMethod::RoutinesCreate | ControlMethod::RoutinesUpdate => {
                for (k, v) in Self::routine_fields(arguments)? {
                    params.insert(k, v);
                }
            }
            ControlMethod::RoutinesSetEnabled => {
                params.insert("enabled".to_string(), Value::Bool(canonical_command == "on"));
            }
            ControlMethod::SessionsMessage => {
                let text = arguments.positional.get(2..).unwrap_or(&[]).join(" ");
                if text.is_empty() && arguments.attachments.is_empty() {
                    return Err(ControlError::new("send needs a message or --attach FILE."));
                }
                let expanded: Vec<Value> = arguments
                    .attachments
                    .iter()
                    .map(|p| Value::String(expand_tilde(p)))
                    .collect();
                params.insert("text".to_string(), Value::String(text));
                params.insert("attachments".to_string(), Value::Array(expanded));
            }
            ControlMethod::SessionsAnswer => {
                return Self::answer_fields(arguments);
            }
            _ => {}
        }
        Ok(params)
    }

    fn routine_fields(arguments: &CliArguments) -> Result<Map<String, Value>, ControlError> {
        let mut fields = Map::new();
        const NAMES: [(&str, &str); 9] = [
            ("name", "name"),
            ("folder", "workingDirectory"),
            ("schedule", "schedule"),
            ("harness", "harness"),
            ("prompt", "prompt"),
            ("skill", "skill"),
            ("model", "model"),
            ("effort", "effort"),
            ("at", "scheduledAt"),
        ];
        for (opt, field) in NAMES {
            if let Some(val) = arguments.options.get(opt) {
                fields.insert(field.to_string(), Value::String(val.clone()));
            }
        }
        for (k, v) in Self::scheduling_fields(arguments)? {
            fields.insert(k, v);
        }
        if let Some(limit) = arguments.options.get("time-limit") {
            let v = limit
                .parse::<i64>()
                .map_or_else(|_| Value::String(limit.clone()), |n| json!(n));
            fields.insert("timeLimitMinutes".to_string(), v);
        }
        if arguments.flags.contains("no-time-limit") {
            fields.insert("timeLimitMinutes".to_string(), Value::Null);
        }
        if arguments.flags.contains("default-model") {
            fields.insert("model".to_string(), Value::Null);
            fields.insert("effort".to_string(), Value::Null);
        }
        if arguments.flags.contains("off") || arguments.flags.contains("disabled") {
            fields.insert("enabled".to_string(), Value::Bool(false));
        }
        Ok(fields)
    }

    fn scheduling_fields(arguments: &CliArguments) -> Result<Map<String, Value>, ControlError> {
        let mut fields = Map::new();
        if arguments.flags.contains("once") && arguments.flags.contains("repeat") {
            return Err(ControlError::new("Choose --once or --repeat."));
        }
        if let Some(runs) = arguments.options.get("runs") {
            let v = runs
                .parse::<i64>()
                .map_or_else(|_| Value::String(runs.clone()), |n| json!(n));
            fields.insert("runLimit".to_string(), v);
        }
        if arguments.options.contains_key("runs") && arguments.flags.contains("no-run-limit") {
            return Err(ControlError::new("Choose --runs or --no-run-limit."));
        }
        if arguments.flags.contains("no-run-limit") {
            fields.insert("runLimit".to_string(), Value::Null);
        }
        if arguments.flags.contains("once") {
            fields.insert("repeats".to_string(), Value::Bool(false));
        }
        if arguments.flags.contains("repeat") {
            fields.insert("repeats".to_string(), Value::Bool(true));
        }
        Ok(fields)
    }

    fn answer_fields(arguments: &CliArguments) -> Result<Map<String, Value>, ControlError> {
        let (Some(question), Some(action)) =
            (arguments.options.get("question"), arguments.options.get("action"))
        else {
            return Err(ControlError::new(
                "answer needs --question ID and --action ACTION. Run rota questions first.",
            ));
        };
        let mut params = Map::new();
        params.insert("question".to_string(), Value::String(question.clone()));
        params.insert("action".to_string(), Value::String(action.clone()));
        if let Some(values_raw) = arguments.options.get("values") {
            let parsed: HashMap<String, Vec<String>> = serde_json::from_str(values_raw)
                .map_err(|_| ControlError::new("--values must map field ids to arrays of strings."))?;
            params.insert(
                "values".to_string(),
                serde_json::to_value(parsed).unwrap_or_else(|_| json!({})),
            );
        }
        Ok(params)
    }

    fn notify_params(words: &[String], arguments: &CliArguments) -> Result<Map<String, Value>, ControlError> {
        let text = words.join(" ");
        if text.is_empty() {
            return Err(ControlError::new("notify needs the message."));
        }
        let mut params = Map::new();
        params.insert("message".to_string(), Value::String(text));
        params.insert(
            "needsReply".to_string(),
            Value::Bool(arguments.flags.contains("needs-reply")),
        );
        if let Some(title) = arguments.options.get("title") {
            params.insert("title".to_string(), Value::String(title.clone()));
        }
        if let Some(routine) = arguments.options.get("routine") {
            params.insert("routine".to_string(), Value::String(routine.clone()));
        } else if let Some(session) = arguments.options.get("session") {
            params.insert("session".to_string(), Value::String(session.clone()));
        }
        Ok(params)
    }

    fn calendar_params(arguments: &CliArguments) -> Result<Map<String, Value>, ControlError> {
        let mut params = Map::new();
        if let Some(id) = arguments.positional.get(1) {
            params.insert("id".to_string(), Value::String(id.clone()));
        }
        if let Some(from) = arguments.options.get("from") {
            params.insert("from".to_string(), Value::String(from.clone()));
        }
        if let Some(days) = arguments.options.get("days") {
            let number: i64 = days
                .parse()
                .map_err(|_| ControlError::new("--days needs an integer."))?;
            params.insert("days".to_string(), json!(number));
        }
        if arguments.flags.contains("paused") {
            params.insert("includePaused".to_string(), Value::Bool(true));
        }
        Ok(params)
    }
}
