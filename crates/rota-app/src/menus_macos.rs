//! Native macOS `NSMenu` bar (`Rota`, `File`, `Edit`, `Routine`, `Session`, `View`, `Help`), `validateMenuItem:`, and `RotaShellTarget`.

#![cfg_attr(not(target_os = "macos"), allow(dead_code))]

#[cfg(target_os = "macos")]
mod macos {
    use std::sync::Mutex;
    use std::sync::mpsc::Sender;

    use objc2::rc::Retained;
    use objc2::runtime::{AnyObject, Bool, Sel};
    use objc2::{DefinedClass, MainThreadMarker, MainThreadOnly, Message, define_class, msg_send, sel};
    use objc2_app_kit::{
        NSAppearanceCustomization, NSApplication, NSEventModifierFlags, NSEventType, NSMenu, NSMenuItem,
        NSStatusItem,
    };
    use objc2_foundation::{NSObject, NSString};

    use crate::actions::{PanelInput, ShellEvent};
    use crate::app_state::AppState;
    use crate::menu_validation::{MenuValidationState, validate_item};
    use crate::shell_macos::wake_app_event_loop;

    pub struct ShellTargetIvars {
        tx: Sender<ShellEvent>,
        validation: Mutex<MenuValidationState>,
        status_item: Mutex<Option<Retained<NSStatusItem>>>,
    }

    define_class!(
        #[unsafe(super(NSObject))]
        #[thread_kind = MainThreadOnly]
        #[ivars = ShellTargetIvars]
        pub struct RotaShellTarget;

        impl RotaShellTarget {
            #[unsafe(method(statusItemClicked:))]
            fn status_clicked(&self, _sender: Option<&AnyObject>) {
                let Some(mtm) = MainThreadMarker::new() else {
                    return;
                };
                let app = NSApplication::sharedApplication(mtm);
                let is_right = app
                    .currentEvent()
                    .is_some_and(|ev| ev.r#type() == NSEventType::RightMouseUp);
                if is_right {
                    self.show_status_context_menu(mtm);
                } else {
                    self.emit(ShellEvent::TogglePanel);
                }
            }

            #[unsafe(method(showStatusMenuAction))]
            fn show_status_menu_action(&self) -> Bool {
                let Some(mtm) = MainThreadMarker::new() else {
                    return Bool::NO;
                };
                self.show_status_context_menu(mtm);
                Bool::YES
            }

            #[unsafe(method(validateMenuItem:))]
            fn validate_menu_item(&self, item: &NSMenuItem) -> Bool {
                let v = self.ivars().validation.lock().expect("menu lock").clone();
                Bool::from(validate_item(&v, item))
            }

            #[unsafe(method(handleReopenAppleEvent:withReplyEvent:))]
            fn handle_reopen(&self, _event: Option<&AnyObject>, _reply: Option<&AnyObject>) {
                self.emit(ShellEvent::ReopenMainWindow);
            }

            #[unsafe(method(hideMainWindow:))]
            fn hide_main(&self, _s: Option<&AnyObject>) {
                self.emit(ShellEvent::HideMainWindow);
            }

            #[unsafe(method(openMain:))]
            fn open_main(&self, _s: Option<&AnyObject>) {
                self.emit(ShellEvent::ReopenMainWindow);
            }

            #[unsafe(method(newRoutine:))]
            fn new_routine(&self, _s: Option<&AnyObject>) {
                self.emit(ShellEvent::OpenNewRoutine);
            }

            #[unsafe(method(importRoutines:))]
            fn import_routines(&self, _s: Option<&AnyObject>) {
                self.emit(ShellEvent::OpenImportRoutines);
            }

            #[unsafe(method(openSchedule:))]
            fn open_schedule(&self, _s: Option<&AnyObject>) {
                self.emit(ShellEvent::ShowSchedule);
            }

            #[unsafe(method(scheduleToday:))]
            fn sched_today(&self, _s: Option<&AnyObject>) {
                self.emit(ShellEvent::ScheduleToday);
            }

            #[unsafe(method(schedulePrev:))]
            fn sched_prev(&self, _s: Option<&AnyObject>) {
                self.emit(ShellEvent::ScheduleStep(-1));
            }

            #[unsafe(method(scheduleNext:))]
            fn sched_next(&self, _s: Option<&AnyObject>) {
                self.emit(ShellEvent::ScheduleStep(1));
            }

            #[unsafe(method(toggleShowPaused:))]
            fn toggle_paused(&self, _s: Option<&AnyObject>) {
                self.emit(ShellEvent::ToggleShowPaused);
            }

            #[unsafe(method(openSettings:))]
            fn open_settings(&self, _s: Option<&AnyObject>) {
                self.emit(ShellEvent::OpenSettings(None));
            }

            #[unsafe(method(toggleSidebar:))]
            fn toggle_sidebar(&self, _s: Option<&AnyObject>) {
                self.emit(ShellEvent::ToggleSidebar);
            }

            #[unsafe(method(zoomIn:))]
            fn zoom_in(&self, _s: Option<&AnyObject>) {
                self.emit(ShellEvent::ZoomInterface(1));
            }

            #[unsafe(method(zoomOut:))]
            fn zoom_out(&self, _s: Option<&AnyObject>) {
                self.emit(ShellEvent::ZoomInterface(-1));
            }

            #[unsafe(method(zoomReset:))]
            fn zoom_reset(&self, _s: Option<&AnyObject>) {
                self.emit(ShellEvent::ResetInterfaceZoom);
            }

            #[unsafe(method(chatZoomIn:))]
            fn chat_zoom_in(&self, _s: Option<&AnyObject>) {
                self.emit(ShellEvent::ZoomChat(1));
            }

            #[unsafe(method(chatZoomOut:))]
            fn chat_zoom_out(&self, _s: Option<&AnyObject>) {
                self.emit(ShellEvent::ZoomChat(-1));
            }

            #[unsafe(method(chatZoomReset:))]
            fn chat_zoom_reset(&self, _s: Option<&AnyObject>) {
                self.emit(ShellEvent::ResetChatZoom);
            }

            #[unsafe(method(runNow:))]
            fn run_now(&self, _s: Option<&AnyObject>) {
                self.emit(ShellEvent::RunSelectedRoutine);
            }

            #[unsafe(method(stopRun:))]
            fn stop_run(&self, _s: Option<&AnyObject>) {
                self.emit(ShellEvent::StopSelected);
            }

            #[unsafe(method(editRoutine:))]
            fn edit_routine(&self, _s: Option<&AnyObject>) {
                self.emit(ShellEvent::EditSelectedRoutine);
            }

            #[unsafe(method(showRoutine:))]
            fn show_routine(&self, _s: Option<&AnyObject>) {
                self.emit(ShellEvent::ShowSelectedRoutine);
            }

            #[unsafe(method(openTerminal:))]
            fn open_terminal(&self, _s: Option<&AnyObject>) {
                self.emit(ShellEvent::OpenSelectedInTerminal);
            }

            #[unsafe(method(revealLog:))]
            fn reveal_log(&self, _s: Option<&AnyObject>) {
                self.emit(ShellEvent::RevealSelectedLog);
            }

            #[unsafe(method(showQuestion:))]
            fn show_question(&self, _s: Option<&AnyObject>) {
                self.emit(ShellEvent::RevealSelectedQuestion);
            }

            #[unsafe(method(dismissAttention:))]
            fn dismiss_attention(&self, _s: Option<&AnyObject>) {
                self.emit(ShellEvent::DismissSelectedAttention);
            }

            #[unsafe(method(toggleRead:))]
            fn toggle_read(&self, _s: Option<&AnyObject>) {
                self.emit(ShellEvent::ToggleSelectedRead);
            }

            #[unsafe(method(loadEarlier:))]
            fn load_earlier(&self, _s: Option<&AnyObject>) {
                self.emit(ShellEvent::LoadSelectedEarlier);
            }

            #[unsafe(method(deleteSession:))]
            fn delete_session(&self, _s: Option<&AnyObject>) {
                self.emit(ShellEvent::DeleteSelectedSession);
            }

            #[unsafe(method(openHelp:))]
            fn open_help(&self, _s: Option<&AnyObject>) {
                self.emit(ShellEvent::OpenHelp);
            }

            #[unsafe(method(checkForUpdates:))]
            fn check_updates(&self, _s: Option<&AnyObject>) {
                self.emit(ShellEvent::CheckForUpdates);
            }

            #[unsafe(method(quitRota:))]
            fn quit_rota(&self, _s: Option<&AnyObject>) {
                self.emit(ShellEvent::QuitRequested);
            }

            #[unsafe(method(editUndo:))]
            fn edit_undo(&self, _s: Option<&AnyObject>) {
                self.emit(ShellEvent::EditCommand(rota_ui::EditKey::Undo));
            }

            #[unsafe(method(editRedo:))]
            fn edit_redo(&self, _s: Option<&AnyObject>) {
                self.emit(ShellEvent::EditCommand(rota_ui::EditKey::Redo));
            }

            #[unsafe(method(editCut:))]
            fn edit_cut(&self, _s: Option<&AnyObject>) {
                self.emit(ShellEvent::EditCommand(rota_ui::EditKey::Cut));
            }

            #[unsafe(method(editCopy:))]
            fn edit_copy(&self, _s: Option<&AnyObject>) {
                self.emit(ShellEvent::EditCommand(rota_ui::EditKey::Copy));
            }

            #[unsafe(method(editPaste:))]
            fn edit_paste(&self, _s: Option<&AnyObject>) {
                self.emit(ShellEvent::EditCommand(rota_ui::EditKey::Paste));
            }

            #[unsafe(method(editSelectAll:))]
            fn edit_select_all(&self, _s: Option<&AnyObject>) {
                self.emit(ShellEvent::EditCommand(rota_ui::EditKey::SelectAll));
            }
        }
    );

    impl RotaShellTarget {
        pub fn new(mtm: MainThreadMarker, tx: Sender<ShellEvent>) -> Retained<Self> {
            let this = Self::alloc(mtm).set_ivars(ShellTargetIvars {
                tx,
                validation: Mutex::new(MenuValidationState::default()),
                status_item: Mutex::new(None),
            });
            // SAFETY: Standard `NSObject` `-init`.
            unsafe { msg_send![super(this), init] }
        }

        pub fn set_status_item(&self, item: &NSStatusItem) {
            *self.ivars().status_item.lock().expect("status lock") = Some(item.retain());
        }

        pub fn sync_validation(&self, state: &AppState) {
            *self.ivars().validation.lock().expect("menu lock") = MenuValidationState::from_state(state);
        }

        fn emit(&self, ev: ShellEvent) {
            let _ = self.ivars().tx.send(ev);
            wake_app_event_loop();
        }

        fn show_status_context_menu(&self, mtm: MainThreadMarker) {
            let _ = self
                .ivars()
                .tx
                .send(ShellEvent::PanelAction(PanelInput::ClosePanel));
            let app = NSApplication::sharedApplication(mtm);
            let menu = NSMenu::new(mtm);
            menu.setAppearance(Some(&app.effectiveAppearance()));
            let add = |title: &str, action: Sel, key: &str| {
                let item = unsafe {
                    NSMenuItem::initWithTitle_action_keyEquivalent(
                        mtm.alloc(),
                        &NSString::from_str(title),
                        Some(action),
                        &NSString::from_str(key),
                    )
                };
                unsafe { item.setTarget(Some(self)) };
                menu.addItem(&item);
            };
            add("Open Rota", sel!(openMain:), "");
            add("New Routine…", sel!(newRoutine:), "n");
            add("Schedule", sel!(openSchedule:), "");
            add("Settings…", sel!(openSettings:), ",");
            add("Check for Updates…", sel!(checkForUpdates:), "");
            menu.addItem(&NSMenuItem::separatorItem(mtm));
            add("Quit Rota", sel!(quitRota:), "q");

            let st_opt = self.ivars().status_item.lock().expect("status lock").clone();
            if let Some(st) = st_opt {
                #[allow(deprecated)]
                st.setMenu(Some(&menu));
                if let Some(btn) = st.button(mtm) {
                    unsafe { btn.performClick(None) };
                }
                #[allow(deprecated)]
                st.setMenu(None);
            }
        }
    }

    pub fn install_main_menu(mtm: MainThreadMarker, target: &RotaShellTarget) {
        let app = NSApplication::sharedApplication(mtm);
        let bar = NSMenu::new(mtm);
        let make_sub = |title: &str| -> Retained<NSMenu> {
            let ns_t = NSString::from_str(title);
            let item = unsafe {
                NSMenuItem::initWithTitle_action_keyEquivalent(mtm.alloc(), &ns_t, None, &NSString::new())
            };
            let sub = NSMenu::initWithTitle(mtm.alloc(), &ns_t);
            item.setSubmenu(Some(&sub));
            bar.addItem(&item);
            sub
        };
        let add = |menu: &NSMenu, title: &str, action: Sel, key: &str, mods: NSEventModifierFlags| {
            let item = unsafe {
                NSMenuItem::initWithTitle_action_keyEquivalent(
                    mtm.alloc(),
                    &NSString::from_str(title),
                    Some(action),
                    &NSString::from_str(key),
                )
            };
            item.setKeyEquivalentModifierMask(mods);
            unsafe { item.setTarget(Some(target)) };
            menu.addItem(&item);
        };
        let add_app = |menu: &NSMenu, title: &str, action: Sel, key: &str, mods: NSEventModifierFlags| {
            let item = unsafe {
                NSMenuItem::initWithTitle_action_keyEquivalent(
                    mtm.alloc(),
                    &NSString::from_str(title),
                    Some(action),
                    &NSString::from_str(key),
                )
            };
            item.setKeyEquivalentModifierMask(mods);
            unsafe { item.setTarget(Some(&app)) };
            menu.addItem(&item);
        };
        let cmd = NSEventModifierFlags::Command;
        let cmd_shift = NSEventModifierFlags::Command | NSEventModifierFlags::Shift;
        let cmd_ctrl = NSEventModifierFlags::Command | NSEventModifierFlags::Control;
        let cmd_opt = NSEventModifierFlags::Command | NSEventModifierFlags::Option;

        let app_m = make_sub("Rota");
        add_app(&app_m, "About Rota", sel!(orderFrontStandardAboutPanel:), "", cmd);
        app_m.addItem(&NSMenuItem::separatorItem(mtm));
        add(&app_m, "Settings…", sel!(openSettings:), ",", cmd);
        add(&app_m, "Check for Updates…", sel!(checkForUpdates:), "", cmd);
        app_m.addItem(&NSMenuItem::separatorItem(mtm));
        add_app(&app_m, "Hide Rota", sel!(hide:), "h", cmd);
        add_app(&app_m, "Hide Others", sel!(hideOtherApplications:), "h", cmd_opt);
        add_app(&app_m, "Show All", sel!(unhideAllApplications:), "", cmd);
        app_m.addItem(&NSMenuItem::separatorItem(mtm));
        add(&app_m, "Quit Rota", sel!(quitRota:), "q", cmd);

        let file_m = make_sub("File");
        add(&file_m, "New Routine…", sel!(newRoutine:), "n", cmd);
        add(&file_m, "Import Routines…", sel!(importRoutines:), "", cmd);
        file_m.addItem(&NSMenuItem::separatorItem(mtm));
        add(&file_m, "Close Window", sel!(hideMainWindow:), "w", cmd);

        let edit_m = make_sub("Edit");
        add(&edit_m, "Undo", sel!(editUndo:), "z", cmd);
        add(&edit_m, "Redo", sel!(editRedo:), "z", cmd_shift);
        edit_m.addItem(&NSMenuItem::separatorItem(mtm));
        add(&edit_m, "Cut", sel!(editCut:), "x", cmd);
        add(&edit_m, "Copy", sel!(editCopy:), "c", cmd);
        add(&edit_m, "Paste", sel!(editPaste:), "v", cmd);
        add(&edit_m, "Select All", sel!(editSelectAll:), "a", cmd);

        let routine_m = make_sub("Routine");
        add(&routine_m, "Run Now", sel!(runNow:), "r", cmd);
        add(&routine_m, "Stop", sel!(stopRun:), ".", cmd);
        routine_m.addItem(&NSMenuItem::separatorItem(mtm));
        add(&routine_m, "Edit Routine…", sel!(editRoutine:), "e", cmd);

        let sess_m = make_sub("Session");
        add(&sess_m, "Show Routine", sel!(showRoutine:), "r", cmd_shift);
        add(&sess_m, "Open in Terminal", sel!(openTerminal:), "t", cmd_shift);
        add(&sess_m, "Show Log in Finder", sel!(revealLog:), "l", cmd_shift);
        sess_m.addItem(&NSMenuItem::separatorItem(mtm));
        add(&sess_m, "Show Question", sel!(showQuestion:), "a", cmd_shift);
        add(
            &sess_m,
            "Dismiss Attention",
            sel!(dismissAttention:),
            "d",
            cmd_shift,
        );
        add(&sess_m, "Mark as Unread", sel!(toggleRead:), "u", cmd_shift);
        add(
            &sess_m,
            "Load Earlier Messages",
            sel!(loadEarlier:),
            "e",
            cmd_shift,
        );
        sess_m.addItem(&NSMenuItem::separatorItem(mtm));
        add(&sess_m, "Delete Session…", sel!(deleteSession:), "", cmd);

        let view_m = make_sub("View");
        add(&view_m, "Hide Sidebar", sel!(toggleSidebar:), "s", cmd_ctrl);
        add(&view_m, "Show Schedule", sel!(openSchedule:), "s", cmd_shift);
        add(&view_m, "Today", sel!(scheduleToday:), "", cmd);
        add(&view_m, "Previous Week", sel!(schedulePrev:), "", cmd);
        add(&view_m, "Next Week", sel!(scheduleNext:), "", cmd);
        add(&view_m, "Show Paused Routines", sel!(toggleShowPaused:), "", cmd);
        view_m.addItem(&NSMenuItem::separatorItem(mtm));
        add(&view_m, "Zoom In", sel!(zoomIn:), "+", cmd);
        add(&view_m, "Zoom Out", sel!(zoomOut:), "-", cmd);
        add(&view_m, "Reset", sel!(zoomReset:), "0", cmd);
        view_m.addItem(&NSMenuItem::separatorItem(mtm));
        add(&view_m, "Chat Zoom In", sel!(chatZoomIn:), "+", cmd_opt);
        add(&view_m, "Chat Zoom Out", sel!(chatZoomOut:), "-", cmd_opt);
        add(&view_m, "Chat Reset", sel!(chatZoomReset:), "0", cmd_opt);

        let help_m = make_sub("Help");
        add(&help_m, "Rota Help", sel!(openHelp:), "?", cmd);

        app.setMainMenu(Some(&bar));
    }
}

#[cfg(target_os = "macos")]
pub use macos::{RotaShellTarget, install_main_menu};
