use std::collections::HashMap;

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use uuid::Uuid;

use crate::model::serde_ext::uppercase_uuid;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct QuestionOption {
    pub id: String,
    pub label: String,
    #[serde(default)]
    pub detail: String,
}

impl QuestionOption {
    pub fn new(id: impl Into<String>, label: impl Into<String>) -> Self {
        Self {
            id: id.into(),
            label: label.into(),
            detail: String::new(),
        }
    }

    pub fn with_detail(id: impl Into<String>, label: impl Into<String>, detail: impl Into<String>) -> Self {
        Self {
            id: id.into(),
            label: label.into(),
            detail: detail.into(),
        }
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub enum QuestionFieldKind {
    #[default]
    Text,
    Secret,
    Boolean,
    Number,
    Integer,
    Choice,
    Multiple,
}

fn default_true() -> bool {
    true
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct QuestionField {
    pub id: String,
    pub title: String,
    #[serde(default)]
    pub detail: String,
    #[serde(default)]
    pub kind: QuestionFieldKind,
    #[serde(default)]
    pub options: Vec<QuestionOption>,
    #[serde(default = "default_true")]
    pub required: bool,
    #[serde(default = "default_true")]
    pub allows_other: bool,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub schema: Option<String>,
}

impl QuestionField {
    pub fn new(id: impl Into<String>, title: impl Into<String>) -> Self {
        Self {
            id: id.into(),
            title: title.into(),
            detail: String::new(),
            kind: QuestionFieldKind::Text,
            options: Vec::new(),
            required: true,
            allows_other: true,
            schema: None,
        }
    }

    pub fn validate(&self, values: &[String]) -> Result<(), String> {
        let constraints: Value = self
            .schema
            .as_deref()
            .and_then(|s| serde_json::from_str(s).ok())
            .unwrap_or_else(|| json!({}));
        let invalid = || format!("Check the value for {}.", self.title);
        for value in values {
            match self.kind {
                QuestionFieldKind::Boolean => {
                    if value != "true" && value != "false" {
                        return Err(invalid());
                    }
                }
                QuestionFieldKind::Number => {
                    let num = value.parse::<f64>().map_err(|_| invalid())?;
                    if !num.is_finite() {
                        return Err(invalid());
                    }
                    if let Some(min) = constraints.get("minimum").and_then(Value::as_f64)
                        && num < min
                    {
                        return Err(invalid());
                    }
                    if let Some(max) = constraints.get("maximum").and_then(Value::as_f64)
                        && num > max
                    {
                        return Err(invalid());
                    }
                }
                QuestionFieldKind::Integer => {
                    let int_val = value.parse::<i128>().map_err(|_| invalid())?;
                    if let Some(min) = constraints.get("minimum") {
                        let min_ok = if let Some(m) = min.as_i64() {
                            int_val >= i128::from(m)
                        } else if let Some(m) = min.as_f64() {
                            (int_val as f64) >= m
                        } else {
                            true
                        };
                        if !min_ok {
                            return Err(invalid());
                        }
                    }
                    if let Some(max) = constraints.get("maximum") {
                        let max_ok = if let Some(m) = max.as_i64() {
                            int_val <= i128::from(m)
                        } else if let Some(m) = max.as_f64() {
                            (int_val as f64) <= m
                        } else {
                            true
                        };
                        if !max_ok {
                            return Err(invalid());
                        }
                    }
                }
                _ => {
                    let scalar_len = value.chars().count();
                    if let Some(min) = constraints.get("minLength").and_then(Value::as_u64)
                        && (scalar_len as u64) < min
                    {
                        return Err(invalid());
                    }
                    if let Some(max) = constraints.get("maxLength").and_then(Value::as_u64)
                        && (scalar_len as u64) > max
                    {
                        return Err(invalid());
                    }
                    if let Some(fmt) = constraints.get("format").and_then(Value::as_str) {
                        match fmt {
                            "email"
                                if !value.contains('@') || value.starts_with('@') || value.ends_with('@') =>
                            {
                                return Err(invalid());
                            }
                            "uri" if !value.contains("://") => return Err(invalid()),
                            "date" if jiff::civil::Date::strptime("%Y-%m-%d", value).is_err() => {
                                return Err(invalid());
                            }
                            _ => {}
                        }
                    }
                }
            }
        }
        if let Some(min_items) = constraints.get("minItems").and_then(Value::as_u64)
            && (values.len() as u64) < min_items
        {
            return Err(invalid());
        }
        if let Some(max_items) = constraints.get("maxItems").and_then(Value::as_u64)
            && (values.len() as u64) > max_items
        {
            return Err(invalid());
        }
        Ok(())
    }

    pub fn content(&self, values: &[String]) -> Option<Value> {
        let first = values.first()?;
        match self.kind {
            QuestionFieldKind::Boolean => Some(Value::Bool(first == "true")),
            QuestionFieldKind::Integer => {
                if let Ok(v) = first.parse::<i64>() {
                    Some(Value::Number(v.into()))
                } else if let Ok(v) = first.parse::<u64>() {
                    Some(Value::Number(v.into()))
                } else {
                    serde_json::from_str::<Value>(first).ok()
                }
            }
            QuestionFieldKind::Number => first
                .parse::<f64>()
                .ok()
                .and_then(serde_json::Number::from_f64)
                .map(Value::Number),
            QuestionFieldKind::Multiple => {
                Some(Value::Array(values.iter().cloned().map(Value::String).collect()))
            }
            _ => Some(Value::String(first.clone())),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AgentQuestion {
    pub id: String,
    pub title: String,
    pub detail: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub context: Option<String>,
    pub fields: Vec<QuestionField>,
    pub actions: Vec<QuestionOption>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub url: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub allows_decline: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub reply_via_message: Option<bool>,
}

impl AgentQuestion {
    pub fn new(title: impl Into<String>) -> Self {
        Self {
            id: uppercase_uuid(Uuid::new_v4()),
            title: title.into(),
            detail: String::new(),
            context: None,
            fields: Vec::new(),
            actions: vec![QuestionOption::new("accept", "Send Answer")],
            url: None,
            allows_decline: Some(false),
            reply_via_message: None,
        }
    }

    pub fn validate(&self, answer: &QuestionAnswer) -> Result<(), String> {
        if answer.action == "cancel" || answer.action == "decline" {
            return Ok(());
        }
        if !self.actions.iter().any(|a| a.id == answer.action) {
            return Err("Choose an answer.".to_string());
        }
        for field in &self.fields {
            let empty_vec = Vec::new();
            let values = answer.values.get(&field.id).unwrap_or(&empty_vec);
            if values.is_empty() || values.iter().all(String::is_empty) {
                if field.required {
                    return Err(format!("Answer {}.", field.title));
                }
                continue;
            }
            if field.kind != QuestionFieldKind::Multiple && values.len() != 1 {
                return Err(format!("Choose one answer for {}.", field.title));
            }
            if !field.allows_other
                && !field.options.is_empty()
                && values
                    .iter()
                    .any(|val| !field.options.iter().any(|opt| &opt.id == val))
            {
                return Err(format!("Choose a listed answer for {}.", field.title));
            }
            field.validate(values)?;
        }
        Ok(())
    }

    pub fn validation_message(&self, answer: &QuestionAnswer) -> Option<String> {
        self.validate(answer).err()
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct QuestionAnswer {
    pub action: String,
    pub values: HashMap<String, Vec<String>>,
}

impl Default for QuestionAnswer {
    fn default() -> Self {
        Self {
            action: "accept".to_string(),
            values: HashMap::new(),
        }
    }
}

impl QuestionAnswer {
    pub fn new(action: impl Into<String>, values: HashMap<String, Vec<String>>) -> Self {
        Self {
            action: action.into(),
            values,
        }
    }

    pub fn cancel() -> Self {
        Self::new("cancel", HashMap::new())
    }
}
