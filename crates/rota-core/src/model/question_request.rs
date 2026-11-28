use std::collections::HashSet;
use std::sync::Arc;

use serde_json::{Map, Value, json};

use crate::model::serde_ext::sort_json_value;
use crate::model::{AgentQuestion, QuestionAnswer, QuestionField, QuestionFieldKind, QuestionOption};

pub struct QuestionRequest {
    pub question: AgentQuestion,
    pub response: Arc<dyn Fn(&QuestionAnswer) -> Value + Send + Sync>,
}

impl QuestionRequest {
    pub fn json(value: &Value) -> String {
        let sorted = sort_json_value(value.clone());
        serde_json::to_string_pretty(&sorted).unwrap_or_default()
    }

    pub fn choices(input: &[Value], codex: bool) -> Vec<QuestionField> {
        input
            .iter()
            .enumerate()
            .map(|(index, field)| {
                let text = field
                    .get("question")
                    .and_then(Value::as_str)
                    .unwrap_or("Question")
                    .to_string();
                let options: Vec<QuestionOption> = field
                    .get("options")
                    .and_then(Value::as_array)
                    .map(|arr| {
                        arr.iter()
                            .map(|opt| {
                                let label =
                                    opt.get("label").and_then(Value::as_str).unwrap_or("").to_string();
                                let detail = ["description", "preview"]
                                    .into_iter()
                                    .filter_map(|k| opt.get(k).and_then(Value::as_str))
                                    .filter(|s| !s.is_empty())
                                    .collect::<Vec<_>>()
                                    .join("\n\n");
                                QuestionOption::with_detail(label.clone(), label, detail)
                            })
                            .collect()
                    })
                    .unwrap_or_default();
                let kind = if field.get("isSecret").and_then(Value::as_bool) == Some(true) {
                    QuestionFieldKind::Secret
                } else if field.get("multiSelect").and_then(Value::as_bool) == Some(true)
                    || field.get("multi_select").and_then(Value::as_bool) == Some(true)
                {
                    QuestionFieldKind::Multiple
                } else if options.is_empty() {
                    QuestionFieldKind::Text
                } else {
                    QuestionFieldKind::Choice
                };
                let id = if codex {
                    field
                        .get("id")
                        .and_then(Value::as_str)
                        .map(ToOwned::to_owned)
                        .unwrap_or_else(|| index.to_string())
                } else {
                    text.clone()
                };
                QuestionField {
                    id,
                    title: text,
                    detail: field
                        .get("header")
                        .and_then(Value::as_str)
                        .unwrap_or("")
                        .to_string(),
                    kind,
                    options,
                    required: true,
                    allows_other: !codex || field.get("isOther").and_then(Value::as_bool) == Some(true),
                    schema: None,
                }
            })
            .collect()
    }

    pub fn codex_message(item: &Value) -> Option<AgentQuestion> {
        if item.get("type").and_then(Value::as_str) != Some("agentMessage") {
            return None;
        }
        let id = item.get("id").and_then(Value::as_str)?;
        let questions = item.get("questions").and_then(Value::as_array)?;
        if questions.is_empty() {
            return None;
        }
        let fields = questions
            .iter()
            .enumerate()
            .map(|(index, q)| {
                let opts: Vec<QuestionOption> = q
                    .get("options")
                    .and_then(Value::as_array)
                    .map(|arr| {
                        arr.iter()
                            .filter_map(Value::as_str)
                            .map(|s| QuestionOption::new(s, s))
                            .collect()
                    })
                    .unwrap_or_default();
                QuestionField {
                    id: index.to_string(),
                    title: q
                        .get("title")
                        .and_then(Value::as_str)
                        .unwrap_or("Question")
                        .to_string(),
                    detail: String::new(),
                    kind: if opts.is_empty() {
                        QuestionFieldKind::Text
                    } else {
                        QuestionFieldKind::Choice
                    },
                    options: opts,
                    required: true,
                    allows_other: true,
                    schema: None,
                }
            })
            .collect();
        let mut question = AgentQuestion::new("Codex needs your reply");
        question.id = id.to_string();
        question.fields = fields;
        question.reply_via_message = Some(true);
        Some(question)
    }

    pub fn elicitation(params: &Value) -> Option<Self> {
        let mode = params.get("mode").and_then(Value::as_str).unwrap_or("form");
        if mode == "openai/userVerification" {
            return Some(Self::device_verification(params));
        }
        if !matches!(mode, "form" | "openai/form" | "openaiForm" | "url") {
            return None;
        }
        let empty = json!({});
        let schema = params
            .get("requestedSchema")
            .or_else(|| params.get("requested_schema"))
            .unwrap_or(&empty);
        if mode != "url" && !Self::supports_form(schema) {
            return Some(Self::unsupported_form(params));
        }
        let fields = Self::elicitation_fields(schema);
        let mut question = AgentQuestion::new("A tool needs your reply");
        question.detail = params
            .get("message")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string();
        question.fields = fields.clone();
        question.actions = vec![QuestionOption::new(
            "accept",
            if mode == "url" {
                "I've Finished"
            } else {
                "Send Answer"
            },
        )];
        question.url = params.get("url").and_then(Value::as_str).map(ToOwned::to_owned);
        question.allows_decline = Some(true);
        Some(Self {
            question,
            response: Arc::new(move |answer| {
                if answer.action == "accept" {
                    let mut content = Map::new();
                    for field in &fields {
                        let vals = answer.values.get(&field.id).cloned().unwrap_or_default();
                        if let Some(val) = field.content(&vals) {
                            content.insert(field.id.clone(), val);
                        }
                    }
                    json!({"action": answer.action, "content": content})
                } else {
                    json!({"action": answer.action, "content": Value::Null})
                }
            }),
        })
    }

    fn elicitation_fields(schema: &Value) -> Vec<QuestionField> {
        let required: HashSet<&str> = schema
            .get("required")
            .and_then(Value::as_array)
            .map(|arr| arr.iter().filter_map(Value::as_str).collect())
            .unwrap_or_default();
        let Some(props) = schema.get("properties").and_then(Value::as_object) else {
            return Vec::new();
        };
        let mut keys: Vec<&String> = props.keys().collect();
        keys.sort();
        keys.into_iter()
            .map(|key| {
                let prop = &props[key];
                let prop_type = prop.get("type").and_then(Value::as_str).unwrap_or("string");
                let multiple = prop_type == "array";
                let source = if multiple {
                    prop.get("items").unwrap_or(&Value::Null)
                } else {
                    prop
                };
                let enums: Vec<String> = source
                    .get("enum")
                    .and_then(Value::as_array)
                    .map(|a| {
                        a.iter()
                            .filter_map(Value::as_str)
                            .map(ToOwned::to_owned)
                            .collect()
                    })
                    .unwrap_or_default();
                let names: Vec<String> = source
                    .get("enumNames")
                    .and_then(Value::as_array)
                    .map(|a| {
                        a.iter()
                            .filter_map(Value::as_str)
                            .map(ToOwned::to_owned)
                            .collect()
                    })
                    .unwrap_or_else(|| enums.clone());
                let mut options: Vec<QuestionOption> = enums
                    .iter()
                    .enumerate()
                    .map(|(i, v)| {
                        QuestionOption::new(v.clone(), names.get(i).cloned().unwrap_or_else(|| v.clone()))
                    })
                    .collect();
                if let Some(union) = source
                    .get("oneOf")
                    .or_else(|| source.get("anyOf"))
                    .and_then(Value::as_array)
                {
                    for item in union {
                        if let Some(val) = item.get("const").and_then(Value::as_str) {
                            let label = item.get("title").and_then(Value::as_str).unwrap_or(val);
                            options.push(QuestionOption::new(val, label));
                        }
                    }
                }
                let kind = if prop_type == "string"
                    && (prop.get("writeOnly").and_then(Value::as_bool) == Some(true)
                        || prop.get("format").and_then(Value::as_str) == Some("password"))
                {
                    QuestionFieldKind::Secret
                } else if multiple {
                    QuestionFieldKind::Multiple
                } else if !options.is_empty() {
                    QuestionFieldKind::Choice
                } else {
                    match prop_type {
                        "boolean" => QuestionFieldKind::Boolean,
                        "integer" => QuestionFieldKind::Integer,
                        "number" => QuestionFieldKind::Number,
                        _ => QuestionFieldKind::Text,
                    }
                };
                let allows_other = options.is_empty();
                QuestionField {
                    id: key.clone(),
                    title: prop
                        .get("title")
                        .and_then(Value::as_str)
                        .unwrap_or(key.as_str())
                        .to_string(),
                    detail: prop
                        .get("description")
                        .and_then(Value::as_str)
                        .unwrap_or("")
                        .to_string(),
                    kind,
                    options,
                    required: required.contains(key.as_str()),
                    allows_other,
                    schema: Some(Self::json(prop)),
                }
            })
            .collect()
    }

    fn supports_form(schema: &Value) -> bool {
        let Some(obj) = schema.as_object() else {
            return true;
        };
        if let Some(t) = obj.get("type").and_then(Value::as_str)
            && t != "object"
        {
            return false;
        }
        if obj.contains_key("oneOf") || obj.contains_key("anyOf") || obj.contains_key("$ref") {
            return false;
        }
        let Some(props) = obj.get("properties").and_then(Value::as_object) else {
            return true;
        };
        for prop in props.values() {
            let Some(t) = prop.get("type").and_then(Value::as_str) else {
                return false;
            };
            if !matches!(t, "string" | "number" | "integer" | "boolean" | "array")
                || prop.get("$ref").is_some()
            {
                return false;
            }
            if t == "array" {
                let Some(items) = prop.get("items").and_then(Value::as_object) else {
                    return false;
                };
                let ok_enum = items
                    .get("enum")
                    .and_then(Value::as_array)
                    .is_some_and(|a| a.iter().all(Value::is_string));
                let ok_any = items
                    .get("anyOf")
                    .and_then(Value::as_array)
                    .is_some_and(|a| a.iter().all(Value::is_object));
                if !ok_enum && !ok_any {
                    return false;
                }
            }
        }
        true
    }

    fn unsupported_form(params: &Value) -> Self {
        let msg = params.get("message").and_then(Value::as_str).unwrap_or("");
        let mut q = AgentQuestion::new("This form needs the provider's app");
        q.detail = format!(
            "{msg}\n\nThis form uses a schema Rota cannot display. Cancel here and continue in the provider's app."
        );
        q.actions = Vec::new();
        q.allows_decline = Some(true);
        Self {
            question: q,
            response: Arc::new(
                |ans| json!({"action": if ans.action == "decline" { "decline" } else { "cancel" }}),
            ),
        }
    }

    fn device_verification(params: &Value) -> Self {
        let title = params
            .get("title")
            .and_then(Value::as_str)
            .unwrap_or("Device verification required");
        let desc = params.get("description").and_then(Value::as_str).unwrap_or("");
        let mut q = AgentQuestion::new(title);
        q.detail = format!(
            "{desc}\n\nThis request requires device verification in the provider's app. \
Rota cannot produce the required proof. Cancel here and continue in the provider's app."
        );
        q.actions = Vec::new();
        q.allows_decline = Some(true);
        Self {
            question: q,
            response: Arc::new(
                |ans| json!({"action": if ans.action == "decline" { "decline" } else { "cancel" }}),
            ),
        }
    }

    pub fn codex(method: &str, params: &Value) -> Option<Self> {
        match method {
            "item/tool/requestUserInput" | "tool/requestUserInput" => {
                let qs = params
                    .get("questions")
                    .and_then(Value::as_array)
                    .cloned()
                    .unwrap_or_default();
                let mut question = AgentQuestion::new("Codex needs your reply");
                question.fields = Self::choices(&qs, true);
                Some(Self {
                    question,
                    response: Arc::new(|ans| {
                        if ans.action == "accept" {
                            let mut map = Map::new();
                            for (k, v) in &ans.values {
                                map.insert(k.clone(), json!({"answers": v}));
                            }
                            json!({"answers": map})
                        } else {
                            json!({"answers": {}})
                        }
                    }),
                })
            }
            "mcpServer/elicitation/request" => Self::elicitation(params),
            "item/commandExecution/requestApproval" | "item/fileChange/requestApproval" => {
                let decisions = params
                    .get("availableDecisions")
                    .and_then(Value::as_array)
                    .cloned()
                    .unwrap_or_else(|| {
                        vec![
                            json!("accept"),
                            json!("acceptForSession"),
                            json!("decline"),
                            json!("cancel"),
                        ]
                    });
                let options: Vec<QuestionOption> = decisions
                    .iter()
                    .enumerate()
                    .filter_map(|(i, val)| {
                        if matches!(val.as_str(), Some("decline" | "cancel")) {
                            return None;
                        }
                        Some(QuestionOption::with_detail(
                            i.to_string(),
                            Self::decision_title(val),
                            Self::json(val),
                        ))
                    })
                    .collect();
                let mut question = AgentQuestion::new("Codex requests approval");
                question.detail = Self::approval_detail(params);
                question.actions = options;
                question.allows_decline = Some(true);
                Some(Self {
                    question,
                    response: Arc::new(move |ans| {
                        if ans.action == "decline" || ans.action == "cancel" {
                            return json!({"decision": ans.action});
                        }
                        let val = ans
                            .action
                            .parse::<usize>()
                            .ok()
                            .and_then(|idx| decisions.get(idx))
                            .cloned()
                            .unwrap_or_else(|| json!("cancel"));
                        json!({"decision": val})
                    }),
                })
            }
            "item/permissions/requestApproval" => {
                let mut question = AgentQuestion::new("Codex requests permissions");
                question.detail = Self::approval_detail(params);
                question.actions = vec![
                    QuestionOption::new("turn", "Allow for This Turn"),
                    QuestionOption::new("session", "Allow for This Session"),
                ];
                question.allows_decline = Some(true);
                let perms = params.get("permissions").cloned().unwrap_or_else(|| json!({}));
                Some(Self {
                    question,
                    response: Arc::new(move |ans| {
                        let granted = if ans.action == "turn" || ans.action == "session" {
                            perms.clone()
                        } else {
                            json!({})
                        };
                        let scope = if ans.action == "session" {
                            "session"
                        } else {
                            "turn"
                        };
                        json!({"permissions": granted, "scope": scope})
                    }),
                })
            }
            "execCommandApproval" | "applyPatchApproval" => {
                let mut question = AgentQuestion::new("Codex requests approval");
                question.detail = Self::approval_detail(params);
                question.actions = vec![
                    QuestionOption::new("approved", "Allow Once"),
                    QuestionOption::new("approved_for_session", "Allow for This Session"),
                ];
                question.allows_decline = Some(true);
                Some(Self {
                    question,
                    response: Arc::new(|ans| {
                        if ans.action == "approved" || ans.action == "approved_for_session" {
                            json!({"decision": ans.action})
                        } else if ans.action == "decline" {
                            json!({"decision": {"denied": {"rejection": "The user declined."}}})
                        } else {
                            json!({"decision": "abort"})
                        }
                    }),
                })
            }
            _ => None,
        }
    }
}
