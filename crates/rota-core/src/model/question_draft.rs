use std::collections::{HashMap, HashSet};

use serde::{Deserialize, Serialize};
use serde_json::{Value, json};

use crate::model::serde_ext::to_sorted_pretty_string;
use crate::model::{AgentQuestion, QuestionAnswer, QuestionField, QuestionFieldKind};

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct QuestionReceiptField {
    pub question: String,
    pub answers: Vec<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct QuestionReceipt {
    pub action: String,
    pub questions: Vec<QuestionReceiptField>,
}

impl QuestionReceipt {
    const PREFIX: &'static str = "Answer to your question ";

    pub fn message(question: &AgentQuestion, answer: &QuestionAnswer) -> String {
        let fields: Vec<Value> = question
            .fields
            .iter()
            .map(|field| {
                let vals = answer.values.get(&field.id).cloned().unwrap_or_default();
                json!({
                    "question": field.title,
                    "answers": vals,
                })
            })
            .collect();
        let payload = json!({
            "action": answer.action,
            "questions": fields,
        });
        let pretty = to_sorted_pretty_string(&payload).unwrap_or_default();
        format!("{}{}:\n{}", Self::PREFIX, question.id, pretty)
    }

    pub fn decode(text: &str) -> Option<Self> {
        let rest = text.strip_prefix(Self::PREFIX)?;
        let (id, body) = rest.split_once(":\n")?;
        if id.is_empty() {
            return None;
        }
        serde_json::from_str(body).ok()
    }

    pub fn answer(text: &str) -> Option<(String, Self)> {
        let rest = text.strip_prefix(Self::PREFIX)?;
        let (id, body) = rest.split_once(":\n")?;
        if id.is_empty() {
            return None;
        }
        let receipt: Self = serde_json::from_str(body).ok()?;
        if !matches!(receipt.action.as_str(), "accept" | "decline" | "cancel") {
            return None;
        }
        Some((id.to_string(), receipt))
    }

    pub fn summary(&self) -> String {
        let answers: Vec<&str> = self
            .questions
            .iter()
            .flat_map(|f| f.answers.iter().map(String::as_str))
            .filter(|s| !s.is_empty())
            .collect();
        if !answers.is_empty() {
            return answers.join("\n");
        }
        match self.action.as_str() {
            "accept" => "Approved".to_string(),
            "decline" => "Declined".to_string(),
            "cancel" => "Cancelled".to_string(),
            other => other.to_string(),
        }
    }
}

/// Interactive question form state for single- and multi-field `AgentQuestion` prompts.
#[derive(Debug, Clone)]
pub struct QuestionDraft {
    pub question: AgentQuestion,
    pub values: HashMap<String, Vec<String>>,
    pub other: HashMap<String, String>,
    pub custom_fields: HashSet<String>,
    pub focus_request: usize,
    field_index: usize,
    pub failure: Option<String>,
}

impl QuestionDraft {
    pub fn new(question: AgentQuestion) -> Self {
        Self {
            question,
            values: HashMap::new(),
            other: HashMap::new(),
            custom_fields: HashSet::new(),
            focus_request: 0,
            field_index: 0,
            failure: None,
        }
    }

    pub fn field_index(&self) -> usize {
        self.field_index
    }

    pub fn current_field(&self) -> Option<&QuestionField> {
        self.question.fields.get(self.field_index)
    }

    pub fn is_last_field(&self) -> bool {
        self.field_index + 1 >= self.question.fields.len()
    }

    pub fn answer(&self) -> QuestionAnswer {
        let mut combined = self.values.clone();
        for field in &self.question.fields {
            if field.options.is_empty() || self.custom_fields.contains(&field.id) {
                let Some(text) = self.other.get(&field.id) else {
                    continue;
                };
                if text.is_empty() {
                    continue;
                }
                if field.kind == QuestionFieldKind::Multiple {
                    combined.entry(field.id.clone()).or_default().push(text.clone());
                } else {
                    combined.insert(field.id.clone(), vec![text.clone()]);
                }
            }
        }
        QuestionAnswer::new("accept", combined)
    }

    pub fn can_advance(&self) -> bool {
        let (Some(field), Some(action)) = (self.current_field(), self.question.actions.first()) else {
            return true;
        };
        let mut step = self.question.clone();
        step.fields = vec![field.clone()];
        let empty_custom = self.custom_fields.contains(&field.id)
            && self.other.get(&field.id).is_none_or(|s| s.trim().is_empty());
        !empty_custom
            && step
                .validation_message(&QuestionAnswer::new(&action.id, self.answer().values))
                .is_none()
    }

    pub fn move_forward(&mut self) {
        if self.can_advance() && !self.is_last_field() {
            self.field_index += 1;
            self.failure = None;
            self.focus_request += 1;
        }
    }

    pub fn move_back(&mut self) {
        if self.field_index > 0 {
            self.field_index -= 1;
            self.failure = None;
            self.focus_request += 1;
        }
    }

    pub fn can_submit(&self, action: &str) -> bool {
        let empty_custom = self
            .custom_fields
            .iter()
            .any(|id| self.other.get(id).is_none_or(|s| s.trim().is_empty()));
        !empty_custom
            && self
                .question
                .validation_message(&QuestionAnswer::new(action, self.answer().values))
                .is_none()
    }

    pub fn select_other(&mut self, selected: bool, field: &QuestionField) {
        if selected {
            self.custom_fields.insert(field.id.clone());
            if field.kind != QuestionFieldKind::Multiple {
                self.values.remove(&field.id);
            }
            self.edit(&field.id);
        } else {
            self.custom_fields.remove(&field.id);
        }
    }

    pub fn edit(&mut self, field_id: &str) {
        if let Some(idx) = self.question.fields.iter().position(|f| f.id == field_id) {
            self.field_index = idx;
            self.focus_request += 1;
        }
    }

    pub fn set_other(&mut self, field_id: &str, text: impl Into<String>) {
        self.other.insert(field_id.to_string(), text.into());
    }

    pub fn send<F>(&mut self, action: &str, submit: F)
    where
        F: FnOnce(QuestionAnswer) -> Result<(), String>,
    {
        match submit(QuestionAnswer::new(action, self.answer().values)) {
            Ok(()) => self.failure = None,
            Err(err) => self.failure = Some(err),
        }
    }
}
