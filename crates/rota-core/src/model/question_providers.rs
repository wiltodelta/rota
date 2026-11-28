use std::collections::HashSet;
use std::sync::Arc;

use serde_json::{Map, Value, json};

use crate::model::{AgentQuestion, QuestionField, QuestionFieldKind, QuestionOption, QuestionRequest};
use crate::transcript::shell_quote;

impl QuestionRequest {
    pub fn claude(event: &Value) -> Option<Self> {
        let name = event.get("hook_event_name").and_then(Value::as_str).unwrap_or("");
        let input = event.get("tool_input").cloned().unwrap_or_else(|| json!({}));
        if name == "Elicitation"
            && let Some(req) = Self::elicitation(event)
        {
            let inner = req.response;
            return Some(Self {
                question: req.question,
                response: Arc::new(move |ans| {
                    let mut out = inner(ans);
                    if let Some(obj) = out.as_object_mut() {
                        obj.insert("hookEventName".to_string(), json!("Elicitation"));
                    }
                    json!({"hookSpecificOutput": out})
                }),
            });
        }
        if name == "PermissionRequest" {
            let tool = event.get("tool_name").and_then(Value::as_str).unwrap_or("Tool");
            let mut q = AgentQuestion::new(format!("Claude requests approval for {tool}"));
            q.detail = Self::json(&input);
            q.actions = vec![QuestionOption::new("accept", "Allow Once")];
            q.allows_decline = Some(true);
            return Some(Self {
                question: q,
                response: Arc::new(move |ans| {
                    let decision = if ans.action == "accept" {
                        json!({"behavior": "allow", "updatedInput": input})
                    } else {
                        json!({"behavior": "deny", "message": "The user declined this request."})
                    };
                    json!({"hookSpecificOutput": {"hookEventName": "PermissionRequest", "decision": decision}})
                }),
            });
        }
        let tool = event
            .get("tool_name")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_string();
        if tool != "AskUserQuestion" && tool != "ExitPlanMode" {
            return None;
        }
        let question = if tool == "AskUserQuestion" {
            let qs = input
                .get("questions")
                .and_then(Value::as_array)
                .cloned()
                .unwrap_or_default();
            let mut q = AgentQuestion::new("Claude needs your reply");
            q.fields = Self::choices(&qs, false);
            q
        } else {
            let mut q = AgentQuestion::new("Approve Claude's plan?");
            q.detail = input
                .get("plan")
                .and_then(Value::as_str)
                .unwrap_or("Review the plan in the conversation above before approving it.")
                .to_string();
            q.actions = vec![QuestionOption::new("accept", "Approve Plan")];
            q
        };
        Some(Self {
            question,
            response: Arc::new(move |ans| {
                let mut out = Map::new();
                out.insert("hookEventName".into(), json!("PreToolUse"));
                if ans.action == "accept" {
                    let mut updated = input.clone();
                    if tool == "AskUserQuestion"
                        && let Some(obj) = updated.as_object_mut()
                    {
                        let mut answers = Map::new();
                        for (k, vals) in &ans.values {
                            answers.insert(k.clone(), json!(vals.join(", ")));
                        }
                        obj.insert("answers".into(), Value::Object(answers));
                    }
                    out.insert("permissionDecision".into(), json!("allow"));
                    out.insert("updatedInput".into(), updated);
                } else {
                    out.insert("permissionDecision".into(), json!("deny"));
                    out.insert(
                        "permissionDecisionReason".into(),
                        json!("The user declined or canceled this request. Do not assume approval."),
                    );
                }
                json!({"hookSpecificOutput": out})
            }),
        })
    }

    pub fn grok(method: &str, params: &Value) -> Option<Self> {
        match method {
            "_x.ai/ask_user_question" | "x.ai/ask_user_question" => {
                let qs = params
                    .get("questions")
                    .and_then(Value::as_array)
                    .cloned()
                    .unwrap_or_default();
                let mut question = AgentQuestion::new("Grok needs your reply");
                question.fields = Self::choices(&qs, false);
                Some(Self {
                    question,
                    response: Arc::new(|ans| {
                        if ans.action == "accept" {
                            json!({"outcome": "accepted", "answers": ans.values})
                        } else {
                            json!({"outcome": "cancelled"})
                        }
                    }),
                })
            }
            "_x.ai/exit_plan_mode" | "x.ai/exit_plan_mode" => {
                let mut q = AgentQuestion::new("Approve Grok's plan?");
                q.detail = params
                    .get("planContent")
                    .and_then(Value::as_str)
                    .unwrap_or("")
                    .to_string();
                q.actions = vec![QuestionOption::new("accept", "Approve Plan")];
                Some(Self {
                    question: q,
                    response: Arc::new(
                        |ans| json!({"outcome": if ans.action == "accept" { "approved" } else { "abandoned" }}),
                    ),
                })
            }
            "_x.ai/mcp/elicit" | "x.ai/mcp/elicit" => {
                let req = Self::elicitation(params)?;
                let inner = req.response;
                Some(Self {
                    question: req.question,
                    response: Arc::new(move |ans| {
                        let mut res = inner(ans);
                        if let Some(obj) = res.as_object_mut()
                            && let Some(act) = obj.remove("action")
                        {
                            obj.insert("outcome".into(), act);
                        }
                        res
                    }),
                })
            }
            "session/request_permission" => {
                let options = params
                    .get("options")
                    .and_then(Value::as_array)
                    .cloned()
                    .unwrap_or_default();
                let mut q = AgentQuestion::new("Grok requests approval");
                q.detail = Self::json(params.get("toolCall").unwrap_or(&json!({})));
                q.actions = options
                    .iter()
                    .filter_map(|opt| {
                        let id = opt.get("optionId").and_then(Value::as_str)?;
                        let label = opt.get("name").and_then(Value::as_str).unwrap_or(id);
                        Some(QuestionOption::new(id, label))
                    })
                    .collect();
                Some(Self {
                    question: q,
                    response: Arc::new(move |ans| {
                        if options
                            .iter()
                            .any(|o| o.get("optionId").and_then(Value::as_str) == Some(&ans.action))
                        {
                            json!({"outcome": {"outcome": "selected", "optionId": ans.action}})
                        } else {
                            json!({"outcome": {"outcome": "cancelled"}})
                        }
                    }),
                })
            }
            _ => None,
        }
    }

    pub fn antigravity(tool: &str, arguments: &Value, id: &str) -> Option<AgentQuestion> {
        if !matches!(tool, "ask_question" | "ask_permission" | "ask_custom_permission") {
            return None;
        }
        let mut question = if tool == "ask_question"
            && let Some(fields) = Self::antigravity_fields(arguments.get("questions"))
            && !fields.is_empty()
        {
            let mut q = AgentQuestion::new("Antigravity needs your reply");
            q.id = id.to_string();
            q.fields = fields;
            q
        } else {
            let permission = tool != "ask_question";
            AgentQuestion {
                id: id.to_string(),
                title: if permission {
                    "Permission request needs Antigravity".to_string()
                } else {
                    "This question needs Antigravity".to_string()
                },
                detail: if permission {
                    "Antigravity handles permissions through its headless execution policy. \
Rota cannot grant or revoke them here. Cancel or decline to send that instruction \
to the conversation; use Antigravity itself to manage permissions."
                        .to_string()
                } else {
                    "Antigravity supplied a question format Rota cannot display. \
Cancel or decline to send that instruction to the conversation."
                        .to_string()
                },
                context: None,
                fields: Vec::new(),
                actions: Vec::new(),
                url: None,
                allows_decline: Some(true),
                reply_via_message: Some(true),
            }
        };
        question.reply_via_message = Some(true);
        Some(question)
    }

    fn antigravity_fields(raw: Option<&Value>) -> Option<Vec<QuestionField>> {
        let parsed: Value;
        let target = match raw? {
            Value::String(s) => {
                parsed = serde_json::from_str(s).ok()?;
                &parsed
            }
            other => other,
        };
        let rows = target.as_array()?;
        let mut fields = Vec::with_capacity(rows.len());
        for (idx, row) in rows.iter().enumerate() {
            let title = row.get("question").and_then(Value::as_str)?;
            if title.is_empty() {
                return None;
            }
            let opts_arr = row.get("options").and_then(Value::as_array)?;
            let mut seen = HashSet::new();
            let mut options = Vec::with_capacity(opts_arr.len());
            for item in opts_arr {
                let s = item.as_str()?;
                if s.is_empty() || !seen.insert(s) {
                    return None;
                }
                options.push(QuestionOption::new(s, s));
            }
            let multi = match row.get("is_multi_select") {
                None | Some(Value::Null) => false,
                Some(Value::Bool(b)) => *b,
                Some(_) => return None,
            };
            let kind = if options.is_empty() {
                QuestionFieldKind::Text
            } else if multi {
                QuestionFieldKind::Multiple
            } else {
                QuestionFieldKind::Choice
            };
            fields.push(QuestionField {
                id: idx.to_string(),
                title: title.to_string(),
                detail: String::new(),
                kind,
                options,
                required: true,
                allows_other: true,
                schema: None,
            });
        }
        Some(fields)
    }

    pub(crate) fn approval_detail(params: &Value) -> String {
        let mut parts = Vec::new();
        if let Some(reason) = params.get("reason").and_then(Value::as_str) {
            parts.push(reason.to_string());
        }
        if let Some(cmd) = params.get("command").and_then(Value::as_str) {
            parts.push(cmd.to_string());
        } else if let Some(arr) = params.get("command").and_then(Value::as_array) {
            let quoted: Vec<String> = arr.iter().filter_map(Value::as_str).map(shell_quote).collect();
            if !quoted.is_empty() {
                parts.push(quoted.join(" "));
            }
        }
        if let Some(cwd) = params.get("cwd").and_then(Value::as_str) {
            parts.push(format!("Folder: {cwd}"));
        }
        if let Some(root) = params.get("grantRoot").and_then(Value::as_str) {
            parts.push(format!("Write access: {root}"));
        }
        for (key, label) in [
            ("fileChanges", "File changes"),
            ("permissions", "Requested permissions"),
            ("additionalPermissions", "Additional permissions"),
            ("networkApprovalContext", "Network access"),
        ] {
            if let Some(val) = params.get(key)
                && !val.is_null()
            {
                parts.push(format!("{label}:\n{}", Self::json(val)));
            }
        }
        parts.join("\n\n")
    }

    pub(crate) fn decision_title(val: &Value) -> String {
        if let Some(obj) = val.as_object() {
            if let Some(amend) = obj
                .get("acceptWithExecpolicyAmendment")
                .and_then(|a| a.get("execpolicy_amendment"))
                .and_then(Value::as_array)
            {
                let cmd = amend
                    .iter()
                    .filter_map(Value::as_str)
                    .map(shell_quote)
                    .collect::<Vec<_>>()
                    .join(" ");
                return format!("Always Allow: {cmd}");
            }
            if let Some(policy) = obj
                .get("applyNetworkPolicyAmendment")
                .and_then(|a| a.get("network_policy_amendment"))
                .and_then(Value::as_object)
                && let Some(host) = policy.get("host").and_then(Value::as_str)
            {
                let prefix = if policy.get("action").and_then(Value::as_str) == Some("deny") {
                    "Always Deny: "
                } else {
                    "Always Allow: "
                };
                return format!("{prefix}{host}");
            }
        }
        match val.as_str() {
            Some("accept") => "Allow Once".to_string(),
            Some("acceptForSession") => "Allow for This Session".to_string(),
            Some("decline") => "Decline".to_string(),
            Some("cancel") => "Cancel".to_string(),
            _ => "Apply Proposed Rule".to_string(),
        }
    }
}
