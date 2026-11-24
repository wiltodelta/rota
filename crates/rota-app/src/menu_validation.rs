//! Dynamic macOS `NSMenuItemValidation` state and item title/checkmark evaluation.

#![cfg_attr(not(target_os = "macos"), allow(dead_code))]

use rota_core::model::RunOutcome;

use crate::actions::SidebarSelection;
use crate::app_state::AppState;

#[derive(Debug, Clone, Default)]
pub struct MenuValidationState {
    pub main_window_visible: bool,
    pub modal_open: bool,
    pub in_settings: bool,
    pub sidebar_shown: bool,
    pub schedule_shown: bool,
    pub show_paused: bool,
    pub has_routines: bool,
    pub has_selected_routine: bool,
    pub selected_routine_running: bool,
    pub can_stop_selected: bool,
    pub has_selected_session: bool,
    pub selected_session_running: bool,
    pub selected_session_unread: bool,
    pub can_open_terminal: bool,
    pub has_session_log: bool,
    pub has_pending_question: bool,
    pub has_attention: bool,
    pub can_load_earlier: bool,
}

impl MenuValidationState {
    pub fn from_state(state: &AppState) -> Self {
        let sel_routine = state.selected_routine();
        let sel_routine_running = sel_routine.is_some_and(|r| state.scheduler.is_running(&r.id));
        let sel_session = match state.selection {
            Some(SidebarSelection::Session(sid)) => state
                .scheduler
                .current_record(sid)
                .or_else(|| state.sessions.iter().find(|s| s.id == sid).cloned()),
            _ => None,
        };
        let sess_running = sel_session
            .as_ref()
            .is_some_and(|r| r.outcome == RunOutcome::Running);
        let can_term = sel_session.as_ref().is_some_and(|rec| {
            sess_running
                || rec
                    .session_id
                    .as_deref()
                    .is_some_and(|sid| rec.harness.terminal(sid, sess_running).is_some())
        });
        let can_earlier = sel_session
            .as_ref()
            .and_then(|rec| state.transcripts.get(&rec.id))
            .is_some_and(|tr| tr.snapshot.has_earlier);

        Self {
            main_window_visible: state.main_window_visible,
            modal_open: state.has_open_modal(),
            in_settings: state.settings_pane.is_some(),
            sidebar_shown: state.sidebar_shown(),
            schedule_shown: state.selection == Some(SidebarSelection::Schedule),
            show_paused: state.settings.show_paused_in_schedule,
            has_routines: !state.routines.is_empty(),
            has_selected_routine: sel_routine.is_some(),
            selected_routine_running: sel_routine_running,
            can_stop_selected: sel_routine_running || sess_running,
            has_selected_session: sel_session.is_some(),
            selected_session_running: sess_running,
            selected_session_unread: sel_session.as_ref().is_some_and(|r| r.is_unread()),
            can_open_terminal: can_term,
            has_session_log: sel_session.as_ref().is_some_and(|r| r.log_path.is_some()),
            has_pending_question: sel_session.as_ref().is_some_and(|r| r.next_question().is_some()),
            has_attention: sel_session.as_ref().is_some_and(|r| r.needs_attention()),
            can_load_earlier: can_earlier,
        }
    }
}

#[cfg(target_os = "macos")]
pub fn validate_item(v: &MenuValidationState, item: &objc2_app_kit::NSMenuItem) -> bool {
    use objc2::sel;
    use objc2_foundation::NSString;

    let Some(act) = item.action() else {
        return true;
    };
    if act == sel!(editUndo:)
        || act == sel!(editRedo:)
        || act == sel!(editCut:)
        || act == sel!(editCopy:)
        || act == sel!(editPaste:)
        || act == sel!(editSelectAll:)
        || act == sel!(quitRota:)
        || act == sel!(openHelp:)
        || act == sel!(checkForUpdates:)
        || act == sel!(openMain:)
    {
        return true;
    }
    if act == sel!(hideMainWindow:) {
        return v.main_window_visible;
    }
    if v.modal_open {
        return false;
    }
    if act == sel!(toggleSidebar:) {
        let lbl = if v.sidebar_shown {
            "Hide Sidebar"
        } else {
            "Show Sidebar"
        };
        item.setTitle(&NSString::from_str(lbl));
        return !v.in_settings;
    }
    if act == sel!(openSchedule:) {
        item.setState(isize::from(v.schedule_shown));
        return v.has_routines;
    }
    if act == sel!(scheduleToday:) || act == sel!(schedulePrev:) || act == sel!(scheduleNext:) {
        return v.schedule_shown && !v.in_settings;
    }
    if act == sel!(toggleShowPaused:) {
        item.setState(isize::from(v.show_paused));
        return v.has_routines;
    }
    if act == sel!(runNow:) {
        return !v.in_settings && v.has_selected_routine && !v.selected_routine_running;
    }
    if act == sel!(stopRun:) {
        return !v.in_settings && v.can_stop_selected;
    }
    if act == sel!(editRoutine:) {
        return !v.in_settings && v.has_selected_routine;
    }
    if act == sel!(showRoutine:) {
        return !v.in_settings && v.has_selected_session;
    }
    if act == sel!(openTerminal:) {
        let lbl = if v.selected_session_running {
            "Open in Terminal"
        } else {
            "Continue in Terminal"
        };
        item.setTitle(&NSString::from_str(lbl));
        return !v.in_settings && v.can_open_terminal;
    }
    if act == sel!(revealLog:) {
        return !v.in_settings && v.has_session_log;
    }
    if act == sel!(showQuestion:) {
        return !v.in_settings && v.has_pending_question;
    }
    if act == sel!(dismissAttention:) {
        return !v.in_settings && v.has_attention;
    }
    if act == sel!(toggleRead:) {
        let lbl = if v.selected_session_unread {
            "Mark as Read"
        } else {
            "Mark as Unread"
        };
        item.setTitle(&NSString::from_str(lbl));
        return !v.in_settings && v.has_selected_session;
    }
    if act == sel!(loadEarlier:) {
        return !v.in_settings && v.can_load_earlier;
    }
    if act == sel!(deleteSession:) {
        return !v.in_settings && v.has_selected_session && !v.selected_session_running;
    }
    true
}
