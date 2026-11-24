use std::path::PathBuf;

use uuid::Uuid;

use crate::model::{ChatMessage, RunOutcome, RunRecord};
use crate::runners::LaunchSpec;
use crate::scheduler::Scheduler;

impl Scheduler {
    pub fn mark_read(&self, session_id: Uuid) -> Result<RunRecord, String> {
        let Some(record) = self.current_record(session_id) else {
            return Err(format!("No session {session_id}."));
        };
        if !record.is_unread() {
            return Ok(record);
        }
        let Some(mut stored) = self
            .history
            .records(&record.routine_id)
            .into_iter()
            .find(|r| r.id == session_id)
        else {
            return Ok(record);
        };
        stored.read_at = Some(self.now());
        self.save_record(&stored);
        Ok(stored)
    }

    pub fn mark_unread(&self, session_id: Uuid) -> Result<RunRecord, String> {
        let Some(record) = self.current_record(session_id) else {
            return Err(format!("No session {session_id}."));
        };
        if !record.is_finished_session() {
            return Err("Only a finished session can be marked unread.".to_string());
        }
        if !record.can_mark_unread() {
            return Ok(record);
        }
        let Some(mut stored) = self
            .history
            .records(&record.routine_id)
            .into_iter()
            .find(|r| r.id == session_id)
        else {
            return Ok(record);
        };
        stored.read_at = None;
        self.save_record(&stored);
        Ok(stored)
    }

    pub fn set_attention(&self, session_id: Uuid, message: Option<String>) -> Result<RunRecord, String> {
        let Some(record) = self.current_record(session_id) else {
            return Err(format!("No session {session_id}."));
        };
        Ok(self.apply_attention(&record, message))
    }

    pub(crate) fn apply_attention(&self, record: &RunRecord, message: Option<String>) -> RunRecord {
        let mut updated = record.clone();
        if message.is_some() {
            updated.updated_at = Some(self.now());
        }
        updated.attention = message;
        {
            let mut g = self.state.lock().unwrap();
            if g.active.contains_key(&updated.id) {
                g.active.insert(updated.id, updated.clone());
            }
        }
        self.save_record(&updated);
        updated
    }

    pub fn dismiss_attention(&self, session_id: Uuid) -> Result<RunRecord, String> {
        let Some(record) = self.current_record(session_id) else {
            return Err(format!("No session {session_id}."));
        };
        if record.questions.as_ref().is_some_and(|qs| !qs.is_empty()) {
            return Err("Answer or cancel the pending questions before dismissing attention.".to_string());
        }
        if record.attention.is_none() {
            return Ok(record);
        }
        Ok(self.apply_attention(&record, None))
    }

    pub fn notify_session(
        &self,
        text: &str,
        title: Option<&str>,
        session: Option<&str>,
        routine_id: Option<&str>,
        needs_reply: bool,
    ) -> Result<Option<RunRecord>, String> {
        if text.trim().is_empty() {
            return Err("The notification needs a message.".to_string());
        }
        let mut record = if let Some(sess) = session {
            Some(
                self.current_record_str(sess, None)
                    .ok_or_else(|| format!("No session {sess}."))?,
            )
        } else if let Some(rid) = routine_id {
            if self.routine(rid).is_none() {
                return Err(format!("No routine {rid}."));
            }
            self.active_record(rid)
                .or_else(|| self.history.records(rid).into_iter().find(|r| !r.is_skip()))
        } else {
            None
        };
        if needs_reply {
            let Some(found) = record else {
                return Err("A notification that needs a reply must come from a session.".into());
            };
            record = Some(self.apply_attention(&found, Some(text.to_string())));
        }
        if let Some(notifier) = &self.notifier {
            let routine = record.as_ref().and_then(|r| self.routine(&r.routine_id));
            let can_reply = record.as_ref().is_some_and(|r| self.accepts_message(r));
            notifier.session_notified(
                record.as_ref(),
                routine.as_ref(),
                title,
                text,
                needs_reply,
                can_reply,
            );
        }
        Ok(record)
    }

    pub fn send_message(
        &self,
        session_id: Uuid,
        text: &str,
        attachments: &[PathBuf],
    ) -> Result<RunRecord, String> {
        let Some(record) = self.current_record(session_id) else {
            return Err(format!("No session {session_id}."));
        };
        if !self.can_message(&record) {
            return Err(if record.harness.is_agent() {
                "That session cannot take a message now.".to_string()
            } else {
                "A shell session takes no messages.".to_string()
            });
        }
        if text.trim().is_empty() && attachments.is_empty() {
            return Err("Give a message or attach a file.".to_string());
        }
        if record.has_blocking_question() {
            return Err("Answer the blocking question before sending a message.".to_string());
        }
        if attachments.iter().any(|p| !p.is_absolute()) {
            return Err("Attachments need absolute file paths.".to_string());
        }

        let (payload, staged_cleanup) = if attachments.is_empty() {
            (text.to_string(), None)
        } else {
            let store = self.history.attachments(&record).map_err(|e| e.to_string())?;
            let staged = store.stage(attachments).map_err(|e| e.to_string())?;
            let encoded = ChatMessage::new(text, staged.clone())
                .encoded()
                .map_err(|e| e.to_string())?;
            (encoded, Some((store, staged)))
        };

        let Some(mut latest) = self.current_record(session_id) else {
            if let Some((store, staged)) = staged_cleanup {
                for att in &staged {
                    let _ = store.discard(att);
                }
            }
            return Err(format!("No session {session_id}."));
        };
        if !self.accepts_message(&latest) {
            if let Some((store, staged)) = staged_cleanup {
                for att in &staged {
                    let _ = store.discard(att);
                }
            }
            return Err("That session cannot take a message now. Answer the blocking question first.".into());
        }
        latest.attention = latest.next_question().map(|q| q.title.clone());
        if !self.deliver_message(&payload, &latest) {
            if let Some((store, staged)) = staged_cleanup {
                for att in &staged {
                    let _ = store.discard(att);
                }
            }
            let err = self
                .last_error()
                .unwrap_or_else(|| "The session did not accept the message.".to_string());
            return Err(err);
        }
        self.current_record(session_id)
            .ok_or_else(|| "The session did not accept the message.".to_string())
    }

    pub(crate) fn deliver_message(&self, message: &str, record: &RunRecord) -> bool {
        if !self.can_message(record) {
            return false;
        }
        let live_ctrl = {
            let mut g = self.state.lock().unwrap();
            if g.active.contains_key(&record.id) {
                let Some(ctrl) = g.controls.get(&record.id).cloned() else {
                    return false;
                };
                let mut updated = record.clone();
                updated.updated_at = Some(self.now());
                g.active.insert(record.id, updated.clone());
                Some((ctrl, updated))
            } else {
                None
            }
        };
        if let Some((ctrl, updated)) = live_ctrl {
            ctrl.send(message);
            self.save_record(&updated);
            return true;
        }
        self.continue_session(record, message)
    }

    pub fn continue_session(&self, record: &RunRecord, message: &str) -> bool {
        if self.is_session_active(record.id)
            || self.is_surviving_session(record.id)
            || self.has_native_conflict(record)
        {
            return false;
        }
        let Some((mut reopened, spec)) = self.reopen(record, message) else {
            return false;
        };
        reopened.reported_model = None;
        reopened.reported_model_title = None;
        reopened.reported_effort = None;
        if let Some(qs) = &mut reopened.questions {
            qs.retain(|q| q.reply_via_message == Some(true));
        }
        reopened.terminal_state = None;
        self.start_launch(reopened, spec).is_ok()
    }

    pub(crate) fn reopen(&self, record: &RunRecord, prompt: &str) -> Option<(RunRecord, LaunchSpec)> {
        let routine = self.routine(&record.routine_id)?;
        let session = record.session_id.clone()?;
        let log_path = record.log_path.clone()?;
        let mut next = record.clone();
        next.outcome = RunOutcome::Running;
        next.ended_at = None;
        let spec = self.build_spec(
            &routine,
            &next,
            next.harness,
            prompt,
            PathBuf::from(log_path),
            Some(session),
        );
        Some((next, spec))
    }
}
