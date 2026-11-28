use std::collections::HashMap;
use std::path::Path;
use std::sync::Arc;

use serde_json::{Value, json};
use uuid::Uuid;

use crate::control::ControlError;
use crate::model::serde_ext::uppercase_uuid;
use crate::model::{AgentQuestion, Harness, QuestionAnswer, QuestionReceipt, RunRecord};
use crate::runners::{AntigravityQuestionArchive, QuestionReplyFn};
use crate::scheduler::Scheduler;

impl Scheduler {
    pub(crate) fn receive_question(&self, question: AgentQuestion, run_id: Uuid, reply: QuestionReplyFn) {
        let Some(mut record) = self.current_record(run_id) else {
            reply(QuestionAnswer::cancel());
            return;
        };
        if !self.is_session_active(run_id) {
            reply(QuestionAnswer::cancel());
            return;
        }
        {
            let mut g = self.state.lock().unwrap();
            if let Some(deliv) = g.question_deliveries.get_mut(&run_id) {
                deliv.remove(&question.id);
            }
        }
        if record
            .questions
            .as_ref()
            .is_some_and(|qs| qs.iter().any(|q| q.id == question.id))
        {
            return;
        }
        if question.reply_via_message != Some(true) {
            self.state
                .lock()
                .unwrap()
                .question_replies
                .entry(run_id)
                .or_default()
                .insert(question.id.clone(), reply);
        }
        let body_text = question
            .fields
            .first()
            .map(|f| f.title.clone())
            .unwrap_or_else(|| question.title.clone());
        let q_title = question.title.clone();
        let mut qs = record.questions.unwrap_or_default();
        qs.push(question);
        record.questions = Some(qs);
        let marked = self.apply_attention(&record, Some(q_title));
        if let Some(notifier) = &self.notifier {
            let routine = self.routine(&marked.routine_id);
            let can_reply = self.accepts_message(&marked);
            notifier.session_notified(Some(&marked), routine.as_ref(), None, &body_text, true, can_reply);
        }
    }

    pub fn answer_question(
        &self,
        session_id: Uuid,
        question_id: &str,
        answer: QuestionAnswer,
    ) -> Result<RunRecord, String> {
        let Some(current) = self.current_record(session_id) else {
            return Err("This question is no longer waiting for an answer.".to_string());
        };
        let Some(question) = current
            .questions
            .as_ref()
            .and_then(|qs| qs.iter().find(|q| q.id == question_id))
            .cloned()
        else {
            return Err("This question is no longer waiting for an answer.".to_string());
        };
        question.validate(&answer)?;
        if question.reply_via_message == Some(true) {
            self.answer_message_question(&question, &current, &answer)?;
            return self
                .current_record(session_id)
                .ok_or_else(|| "No session found.".to_string());
        }
        let reply = {
            if !self.is_session_active(session_id) {
                return Err("This question is no longer waiting for an answer.".to_string());
            }
            let g = self.state.lock().unwrap();
            g.question_replies
                .get(&session_id)
                .and_then(|m| m.get(question_id))
                .cloned()
        };
        let Some(reply) = reply else {
            return Err("This question is no longer waiting for an answer.".to_string());
        };
        self.resolve_question(question_id, session_id);
        reply(answer);
        self.current_record(session_id)
            .ok_or_else(|| "No session found.".to_string())
    }

    fn answer_message_question(
        &self,
        question: &AgentQuestion,
        record: &RunRecord,
        answer: &QuestionAnswer,
    ) -> Result<(), String> {
        if !self.can_message(record) {
            return Err(
                "Answer the blocking question or wait for this session to become available first."
                    .to_string(),
            );
        }
        {
            let mut g = self.state.lock().unwrap();
            if g.question_replies.get(&record.id).is_some_and(|m| !m.is_empty()) {
                return Err(
                    "Answer the blocking question or wait for this session to become available first."
                        .to_string(),
                );
            }
            if g.question_deliveries
                .get(&record.id)
                .is_some_and(|s| s.contains(&question.id))
            {
                return Err("This answer is still being delivered.".to_string());
            }
            if record.harness == Harness::Codex {
                g.question_deliveries
                    .entry(record.id)
                    .or_default()
                    .insert(question.id.clone());
            }
        }
        let text = QuestionReceipt::message(question, answer);
        let mut next = record.clone();
        if record.harness != Harness::Codex {
            if let Some(qs) = &mut next.questions {
                qs.retain(|q| q.id != question.id);
            }
            next.attention = next.next_question().map(|q| q.title.clone());
        }
        if !self.deliver_message(&text, &next) {
            {
                let mut g = self.state.lock().unwrap();
                if let Some(s) = g.question_deliveries.get_mut(&record.id) {
                    s.remove(&question.id);
                }
            }
            let mut failed = self.current_record(record.id).unwrap_or_else(|| record.clone());
            failed.questions = record.questions.clone();
            failed.attention = record.attention.clone();
            self.save_record(&failed);
            return Err("Could not continue the session. Your question is still pending.".into());
        }
        Ok(())
    }

    pub fn resolve_question(&self, id: &str, run_id: Uuid) {
        {
            let mut g = self.state.lock().unwrap();
            if let Some(s) = g.question_deliveries.get_mut(&run_id) {
                s.remove(id);
            }
            if let Some(m) = g.question_replies.get_mut(&run_id) {
                m.remove(id);
            }
        }
        let Some(mut record) = self.current_record(run_id) else {
            return;
        };
        if !record
            .questions
            .as_ref()
            .is_some_and(|qs| qs.iter().any(|q| q.id == id))
        {
            return;
        }
        record.updated_at = Some(self.now());
        if let Some(qs) = &mut record.questions {
            qs.retain(|q| q.id != id);
        }
        record.attention = record.next_question().map(|q| q.title.clone());
        {
            let mut g = self.state.lock().unwrap();
            if g.active.contains_key(&run_id) {
                g.active.insert(run_id, record.clone());
            }
        }
        self.save_record(&record);
    }

    pub(crate) fn cancel_questions(&self, record: &RunRecord) {
        let replies: HashMap<String, QuestionReplyFn> = {
            let mut g = self.state.lock().unwrap();
            g.question_deliveries.remove(&record.id);
            let prefix = format!("{}/", uppercase_uuid(record.id));
            g.hook_answers.retain(|k, _| !k.starts_with(&prefix));
            g.question_replies.remove(&record.id).unwrap_or_default()
        };
        if !replies.is_empty()
            && let Some(mut current) = self.current_record(record.id)
        {
            if let Some(qs) = &mut current.questions {
                qs.retain(|q| q.reply_via_message == Some(true));
                if qs.is_empty() {
                    current.questions = None;
                }
            }
            current.attention = current.next_question().map(|q| q.title.clone());
            {
                let mut g = self.state.lock().unwrap();
                if g.active.contains_key(&current.id) {
                    g.active.insert(current.id, current.clone());
                }
            }
            self.save_record(&current);
        }
        for (_, reply) in replies {
            reply(QuestionAnswer::cancel());
        }
    }

    pub(crate) fn question_command(
        &self,
        method: &str,
        params: &serde_json::Map<String, Value>,
    ) -> Result<Option<Value>, ControlError> {
        if !method.starts_with("questions.") {
            return Ok(None);
        }
        let Some(session_str) = params.get("session").and_then(Value::as_str) else {
            return Err(ControlError::new("The session is no longer running."));
        };
        let Some(record) = self.current_record_str(session_str, None) else {
            return Err(ControlError::new("The session is no longer running."));
        };
        if !self.is_session_active(record.id) {
            return Err(ControlError::new("The session is no longer running."));
        }
        let prefix = uppercase_uuid(record.id);
        match method {
            "questions.create" => {
                let q_val = params.get("question").cloned().unwrap_or_else(|| json!({}));
                let question: AgentQuestion =
                    serde_json::from_value(q_val).map_err(|e| ControlError::new(e.to_string()))?;
                let qid = question.id.clone();
                let key = format!("{prefix}/{qid}");
                let weak = self.self_weak.clone();
                self.receive_question(
                    question,
                    record.id,
                    Arc::new(move |ans| {
                        if let Some(s) = weak.upgrade() {
                            s.state.lock().unwrap().hook_answers.insert(key.clone(), ans);
                        }
                    }),
                );
                Ok(Some(json!({"question": qid})))
            }
            "questions.poll" => {
                let Some(qid) = params.get("question").and_then(Value::as_str) else {
                    return Err(ControlError::new("Missing question id."));
                };
                let key = format!("{prefix}/{qid}");
                let (answered, still_waiting) = {
                    let mut g = self.state.lock().unwrap();
                    let ans = g.hook_answers.remove(&key);
                    let waiting = g
                        .question_replies
                        .get(&record.id)
                        .is_some_and(|m| m.contains_key(qid));
                    (ans, waiting)
                };
                if let Some(ans) = answered {
                    let val = serde_json::to_value(ans).map_err(|e| ControlError::new(e.to_string()))?;
                    return Ok(Some(val));
                }
                if !still_waiting {
                    return Err(ControlError::new("The question has expired."));
                }
                Ok(Some(json!({"pending": true})))
            }
            _ => Err(ControlError::new("Unknown question method.")),
        }
    }

    pub fn restore_antigravity_questions(&self, home: &Path) {
        let needs_fields = |q: &AgentQuestion| q.fields.is_empty() && q.reply_via_message == Some(true);
        for snapshot in self.all_sessions() {
            if snapshot.harness != Harness::Antigravity {
                continue;
            }
            let Some(mut record) = self.current_record_in(snapshot.id, Some(&snapshot.routine_id)) else {
                continue;
            };
            let Some(questions) = record.questions.clone() else {
                continue;
            };
            if !questions.iter().any(needs_fields) {
                continue;
            }
            let Some(session) = &record.session_id else {
                continue;
            };
            let Some(mut archive) = AntigravityQuestionArchive::open(session, home, false) else {
                continue;
            };
            let Ok(native) = archive.read(false) else {
                continue;
            };
            let mut updated_questions = Vec::with_capacity(questions.len());
            for q in &questions {
                if needs_fields(q)
                    && let Some(rep) = native.iter().find(|n| n.id == q.id && !n.fields.is_empty())
                {
                    if record.attention.as_deref() == Some(q.title.as_str()) {
                        record.attention = Some(rep.title.clone());
                    }
                    updated_questions.push(rep.clone());
                } else {
                    updated_questions.push(q.clone());
                }
            }
            if updated_questions == questions {
                continue;
            }
            record.questions = Some(updated_questions);
            {
                let mut g = self.state.lock().unwrap();
                if g.active.contains_key(&record.id) {
                    g.active.insert(record.id, record.clone());
                }
            }
            self.save_record(&record);
        }
    }
}
