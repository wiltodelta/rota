//! Native macOS `NSMenu` right-click context menus anchored to `rota-ui` elements.

use std::cell::Cell;

#[cfg(target_os = "macos")]
use objc2::DefinedClass;
use rota_core::model::RunOutcome;
use rota_ui::{EditKey, Modifiers, NativeWindow, Point, Rect};
use uuid::Uuid;

use crate::actions::{AppAction, FocusTarget, MenuId};
use crate::app_state::AppState;
use crate::views::menu_items::entries_for_menu;

#[derive(Debug, Clone)]
pub enum PopupRequest {
    DropdownMenu { menu_id: MenuId, anchor: Rect },
    RoutineContext { rid: String, pt: Point },
    SessionContext { sid: Uuid, pt: Point },
    TranscriptContext { sid: Uuid, pt: Point },
    EditorContext { pt: Point },
}

struct MenuItemSpec {
    title: String,
    checked: bool,
    enabled: bool,
    separator: bool,
}

impl MenuItemSpec {
    fn item(title: impl Into<String>, checked: bool, enabled: bool) -> Self {
        Self {
            title: title.into(),
            checked,
            enabled,
            separator: false,
        }
    }
    fn sep() -> Self {
        Self {
            title: String::new(),
            checked: false,
            enabled: false,
            separator: true,
        }
    }
}

pub fn dispatch_pending_popup(window: &NativeWindow, state: &mut AppState) -> bool {
    let Some(req) = state.pending_popup.take() else {
        return false;
    };

    match req {
        PopupRequest::DropdownMenu { menu_id, anchor } => {
            let theme = state.theme();
            let entries = entries_for_menu(state, &theme, &menu_id);
            if entries.is_empty() {
                return false;
            }
            let specs: Vec<MenuItemSpec> = entries
                .iter()
                .map(|e| {
                    if e.is_separator {
                        MenuItemSpec::sep()
                    } else {
                        MenuItemSpec::item(&e.title, e.checked, e.enabled)
                    }
                })
                .collect();
            if let Some(pick) = show_macos_popup(window, anchor, &specs)
                && let Some(entry) = entries.into_iter().nth(pick)
                && let Some(act) = entry.action
            {
                state.open_menu = None;
                state.execute_action(act);
                return true;
            }
        }
        PopupRequest::RoutineContext { rid, pt } => {
            let Some(r) = state.routines.iter().find(|r| r.id == rid).cloned() else {
                return false;
            };
            let running = state.scheduler.is_running(&rid);
            let specs = vec![
                MenuItemSpec::item(if running { "Stop" } else { "Run Now" }, false, true),
                MenuItemSpec::item(
                    if r.enabled {
                        "Pause Schedule"
                    } else {
                        "Enable Schedule"
                    },
                    false,
                    !r.is_schedule_complete(),
                ),
                MenuItemSpec::sep(),
                MenuItemSpec::item("Edit Routine…", false, true),
                MenuItemSpec::item("Delete Routine…", false, true),
            ];
            if let Some(pick) = show_macos_popup(window, Rect::new(pt.x, pt.y, 1.0, 1.0), &specs) {
                match pick {
                    0 if running => state.execute_action(AppAction::StopRoutine(rid)),
                    0 => state.execute_action(AppAction::RunRoutineNow(rid)),
                    1 => state.execute_action(AppAction::ToggleRoutineEnabled(rid)),
                    3 => state.execute_action(AppAction::EditRoutine(rid)),
                    4 => state.execute_action(AppAction::PromptDeleteRoutine(rid)),
                    _ => {}
                }
                return true;
            }
        }
        PopupRequest::SessionContext { sid, pt } => {
            let Some(rec) = state.scheduler.current_record(sid) else {
                return false;
            };
            let running = rec.outcome == RunOutcome::Running;
            let can_term = rec
                .session_id
                .as_deref()
                .is_some_and(|s| rec.harness.terminal(s, running).is_some());
            let unread_lbl = if rec.is_unread() {
                "Mark as Read"
            } else {
                "Mark as Unread"
            };
            let specs = vec![
                MenuItemSpec::item("Show Routine", false, true),
                MenuItemSpec::item("Continue in Terminal", false, can_term),
                MenuItemSpec::item("Show Log in Finder", false, rec.log_path.is_some()),
                MenuItemSpec::sep(),
                MenuItemSpec::item(unread_lbl, false, true),
                MenuItemSpec::sep(),
                MenuItemSpec::item("Delete Session…", false, !running),
            ];
            if let Some(pick) = show_macos_popup(window, Rect::new(pt.x, pt.y, 1.0, 1.0), &specs) {
                match pick {
                    0 => state.execute_action(AppAction::ShowSessionRoutine(rec.routine_id)),
                    1 => state.execute_action(AppAction::OpenInTerminal(sid)),
                    2 => state.execute_action(AppAction::RevealSessionLog(sid)),
                    4 => state.execute_action(AppAction::ToggleMarkUnread(sid)),
                    6 => state.execute_action(AppAction::PromptDeleteSession(sid)),
                    _ => {}
                }
                return true;
            }
        }
        PopupRequest::TranscriptContext { sid, pt } => {
            let has_sel = state
                .transcripts
                .get(&sid)
                .is_some_and(|t| t.selection.is_active());
            let specs = vec![
                MenuItemSpec::item("Copy Selection", false, has_sel),
                MenuItemSpec::item("Show Log in Finder", false, true),
            ];
            if let Some(pick) = show_macos_popup(window, Rect::new(pt.x, pt.y, 1.0, 1.0), &specs) {
                match pick {
                    0 => {
                        if let Some(tr) = state.transcripts.get_mut(&sid) {
                            let _ = tr.selection.copy_to_clipboard(&tr.selectable_blocks);
                        }
                    }
                    1 => state.execute_action(AppAction::RevealSessionLog(sid)),
                    _ => {}
                }
                return true;
            }
        }
        PopupRequest::EditorContext { pt } => {
            let has_focus = state.focus.is_some() && state.focus != Some(FocusTarget::Sidebar);
            if !has_focus {
                return false;
            }
            let specs = vec![
                MenuItemSpec::item("Cut", false, true),
                MenuItemSpec::item("Copy", false, true),
                MenuItemSpec::item("Paste", false, true),
                MenuItemSpec::sep(),
                MenuItemSpec::item("Select All", false, true),
            ];
            if let Some(pick) = show_macos_popup(window, Rect::new(pt.x, pt.y, 1.0, 1.0), &specs) {
                let key = match pick {
                    0 => Some(EditKey::Cut),
                    1 => Some(EditKey::Copy),
                    2 => Some(EditKey::Paste),
                    4 => Some(EditKey::SelectAll),
                    _ => None,
                };
                if let Some(k) = key {
                    let _ = state.dispatch_key_to_focused_editor(&k, Modifiers::default());
                    return true;
                }
            }
        }
    }
    false
}

#[cfg(target_os = "macos")]
struct PopupIvars {
    chosen: Cell<isize>,
}

#[cfg(target_os = "macos")]
objc2::define_class!(
    #[unsafe(super(objc2_foundation::NSObject))]
    #[thread_kind = objc2::MainThreadOnly]
    #[name = "RotaPopupMenuTarget"]
    #[ivars = PopupIvars]
    struct RotaPopupMenuTarget;

    impl RotaPopupMenuTarget {
        #[unsafe(method(pickMenuItem:))]
        fn pick_menu_item(&self, sender: &objc2_app_kit::NSMenuItem) {
            self.ivars().chosen.set(sender.tag());
        }
    }
);

#[cfg(target_os = "macos")]
fn show_macos_popup(window: &NativeWindow, anchor: Rect, items: &[MenuItemSpec]) -> Option<usize> {
    use objc2::rc::Retained;
    use objc2::sel;
    use objc2_app_kit::{NSControlStateValueOn, NSMenu, NSMenuItem};
    use objc2_foundation::{MainThreadMarker, NSPoint, NSString};

    let mtm = MainThreadMarker::new()?;
    let view = rota_ui::window_macos::macos_ns_view(window)?;

    let target: Retained<RotaPopupMenuTarget> = {
        let this = mtm.alloc::<RotaPopupMenuTarget>().set_ivars(PopupIvars {
            chosen: Cell::new(-1),
        });
        unsafe { objc2::msg_send![super(this), init] }
    };

    let menu = NSMenu::new(mtm);
    menu.setAutoenablesItems(false);
    for (idx, spec) in items.iter().enumerate() {
        if spec.separator {
            menu.addItem(&NSMenuItem::separatorItem(mtm));
            continue;
        }
        let item = unsafe {
            NSMenuItem::initWithTitle_action_keyEquivalent(
                mtm.alloc(),
                &NSString::from_str(&spec.title),
                Some(sel!(pickMenuItem:)),
                &NSString::from_str(""),
            )
        };
        item.setTag(idx as isize);
        item.setEnabled(spec.enabled);
        if spec.checked {
            item.setState(NSControlStateValueOn);
        }
        unsafe { item.setTarget(Some(&target)) };
        menu.addItem(&item);
    }

    let bounds = view.bounds();
    let y = if view.isFlipped() {
        f64::from(anchor.max_y() + 4.0)
    } else {
        (bounds.size.height - f64::from(anchor.max_y() + 4.0)).max(0.0)
    };
    let loc = NSPoint::new(f64::from(anchor.x), y);
    let _ = menu.popUpMenuPositioningItem_atLocation_inView(None, loc, Some(&view));
    let picked = target.ivars().chosen.get();
    (picked >= 0).then_some(picked as usize)
}

#[cfg(not(target_os = "macos"))]
fn show_macos_popup(_window: &NativeWindow, _anchor: Rect, _items: &[MenuItemSpec]) -> Option<usize> {
    None
}
