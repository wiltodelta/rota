use rota_platform::{NotificationPayload, SystemNotifier};
use uuid::Uuid;

use crate::model::serde_ext::uppercase_uuid;
use crate::model::{Routine, RunOutcome, RunRecord};
use crate::schedule::ScheduleText;

/// Delivers user-facing notifications for run outcomes, auto-paused routines, agent-created
/// routines, and explicit `notify` / structured-question prompts.
pub trait SchedulerNotifier: Send + Sync {
    fn notify(&self, payload: NotificationPayload);

    fn run_ended(&self, record: &RunRecord, routine: &Routine, notify_on_success: bool) {
        if let Some(payload) = build_run_ended_payload(record, routine, notify_on_success) {
            self.notify(payload);
        }
    }

    fn routine_paused(&self, routine: &Routine, failures: usize) {
        self.notify(build_routine_paused_payload(routine, failures));
    }

    fn routine_added(&self, routine: &Routine) {
        self.notify(build_routine_added_payload(routine));
    }

    fn session_notified(
        &self,
        record: Option<&RunRecord>,
        routine: Option<&Routine>,
        title: Option<&str>,
        text: &str,
        needs_reply: bool,
        can_reply: bool,
    ) {
        self.notify(build_session_notified_payload(
            record,
            routine,
            title,
            text,
            needs_reply,
            can_reply,
        ));
    }
}

impl SchedulerNotifier for SystemNotifier {
    fn notify(&self, payload: NotificationPayload) {
        self.post(payload);
    }
}

fn requires_attention(record: Option<&RunRecord>) -> bool {
    record.is_some_and(|r| {
        r.attention.is_some()
            || r.questions.as_ref().is_some_and(|qs| !qs.is_empty())
            || r.outcome.is_failure()
    })
}

fn identifier_for(base: &str, temporary: bool) -> String {
    if temporary {
        format!("{base}-{}", uppercase_uuid(Uuid::new_v4()))
    } else {
        base.to_string()
    }
}

pub fn build_run_ended_payload(
    record: &RunRecord,
    routine: &Routine,
    notify_on_success: bool,
) -> Option<NotificationPayload> {
    if !record.outcome.is_failure() && !(record.outcome == RunOutcome::Succeeded && notify_on_success) {
        return None;
    }
    let temporary = !requires_attention(Some(record));
    let base_id = uppercase_uuid(record.id);
    let (session_id, routine_id) = if record.is_skip() {
        (None, Some(routine.id.clone()))
    } else {
        (Some(base_id.clone()), None)
    };
    Some(NotificationPayload {
        id: identifier_for(&base_id, temporary),
        title: routine.name.clone(),
        subtitle: None,
        body: format!("{} on {}", record.outcome.title(), record.harness.title()),
        sound: record.outcome.is_failure(),
        session_id,
        routine_id,
        allow_inline_reply: false,
        temporary,
    })
}

pub fn build_routine_paused_payload(routine: &Routine, failures: usize) -> NotificationPayload {
    NotificationPayload {
        id: format!("paused-{}", routine.id),
        title: routine.name.clone(),
        subtitle: None,
        body: format!("Paused after {failures} failed runs in a row. Turn it on again once it is fixed."),
        sound: true,
        session_id: None,
        routine_id: Some(routine.id.clone()),
        allow_inline_reply: false,
        temporary: false,
    }
}

pub fn build_routine_added_payload(routine: &Routine) -> NotificationPayload {
    let state = if routine.enabled {
        if routine.repeats {
            ScheduleText::describe(&routine.schedule).unwrap_or_else(|| routine.schedule.clone())
        } else {
            routine.schedule_description()
        }
    } else {
        "turned off".to_string()
    };
    NotificationPayload {
        id: identifier_for(&format!("added-{}", routine.id), true),
        title: routine.name.clone(),
        subtitle: None,
        body: format!("Added by an agent: {}, {state}.", routine.harness.title()),
        sound: false,
        session_id: None,
        routine_id: Some(routine.id.clone()),
        allow_inline_reply: false,
        temporary: true,
    }
}

pub fn build_session_notified_payload(
    record: Option<&RunRecord>,
    routine: Option<&Routine>,
    title: Option<&str>,
    text: &str,
    needs_reply: bool,
    can_reply: bool,
) -> NotificationPayload {
    let temporary = !(needs_reply || requires_attention(record));
    let base_id = format!(
        "notify-{}-{}",
        record.map_or_else(|| "rota".to_string(), |r| uppercase_uuid(r.id)),
        uppercase_uuid(Uuid::new_v4()),
    );
    let subtitle = needs_reply.then(|| {
        if record.is_some() && can_reply {
            "Needs your reply".to_string()
        } else {
            "Needs your attention".to_string()
        }
    });
    let allow_inline_reply =
        record.is_some_and(|r| can_reply && r.questions.as_ref().is_none_or(Vec::is_empty));
    NotificationPayload {
        id: identifier_for(&base_id, temporary),
        title: title
            .map(ToOwned::to_owned)
            .or_else(|| routine.map(|r| r.name.clone()))
            .unwrap_or_else(|| "Rota".to_string()),
        subtitle,
        body: text.to_string(),
        sound: true,
        session_id: record.map(|r| uppercase_uuid(r.id)),
        routine_id: None,
        allow_inline_reply,
        temporary,
    }
}
