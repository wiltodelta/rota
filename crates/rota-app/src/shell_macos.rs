//! macOS AppKit shell: single-instance guard, `NSStatusItem`, `LSUIElement` `.accessory`/`.regular` policy, Dock badge, dynamic window title, and AppleEvent reopen.

use std::sync::mpsc::Sender;

use rota_platform::Logger;

use crate::actions::ShellEvent;
use crate::app_state::AppState;

const LOG: Logger = Logger::new("app");

/// If another live process with the same bundle ID is already running, activates it and exits `0`.
pub fn activate_existing_instance_and_exit_if_running() {
    #[cfg(target_os = "macos")]
    {
        use objc2_app_kit::{NSApplicationActivationOptions, NSRunningApplication};
        use objc2_foundation::NSString;

        let Some(bundle_id) = rota_platform::app_bundle_identifier() else {
            return;
        };
        let self_pid = std::process::id() as i32;
        let apps =
            NSRunningApplication::runningApplicationsWithBundleIdentifier(&NSString::from_str(&bundle_id));
        for idx in 0..apps.count() {
            let app = apps.objectAtIndex(idx);
            if !app.isTerminated() && app.processIdentifier() != self_pid {
                LOG.info("Another instance is running; activating existing instance and quitting");
                #[allow(deprecated)]
                let _ = app.activateWithOptions(
                    NSApplicationActivationOptions::ActivateAllWindows
                        | NSApplicationActivationOptions::ActivateIgnoringOtherApps,
                );
                std::process::exit(0);
            }
        }
    }
}

/// Thread-safely wakes `NSApplication`'s run loop when `WindowRunner` is in `ControlFlow::Wait`.
pub fn wake_app_event_loop() {
    #[cfg(target_os = "macos")]
    {
        use objc2::msg_send;
        use objc2::runtime::{AnyClass, AnyObject};
        use objc2_app_kit::{NSEvent, NSEventModifierFlags, NSEventType};
        use objc2_foundation::NSPoint;

        // SAFETY: `NSEvent::otherEventWithType:...` and `[NSApp postEvent:atStart:]` are thread-safe in AppKit.
        unsafe {
            let Some(app_cls) = AnyClass::get(c"NSApplication") else {
                return;
            };
            let ns_app: *mut AnyObject = msg_send![app_cls, sharedApplication];
            if ns_app.is_null() {
                return;
            }
            if let Some(ev) =
                NSEvent::otherEventWithType_location_modifierFlags_timestamp_windowNumber_context_subtype_data1_data2(
                    NSEventType::ApplicationDefined,
                    NSPoint::new(0.0, 0.0),
                    NSEventModifierFlags::empty(),
                    0.0,
                    0,
                    None,
                    0,
                    0,
                    0,
                )
            {
                let _: () = msg_send![ns_app, postEvent: &*ev, atStart: false];
            }
        }
    }
}

pub fn system_is_dark() -> bool {
    #[cfg(target_os = "macos")]
    {
        use objc2::MainThreadMarker;
        use objc2_app_kit::{NSAppearanceNameAqua, NSAppearanceNameDarkAqua, NSApplication};
        use objc2_foundation::NSArray;

        let Some(mtm) = MainThreadMarker::new() else {
            return false;
        };
        let app = NSApplication::sharedApplication(mtm);
        let eff = app.effectiveAppearance();
        // SAFETY: AppKit appearance name constants are immortal globals.
        unsafe {
            let names = NSArray::from_slice(&[NSAppearanceNameAqua, NSAppearanceNameDarkAqua]);
            if let Some(best) = eff.bestMatchFromAppearancesWithNames(&names) {
                return &*best == NSAppearanceNameDarkAqua;
            }
        }
        false
    }
    #[cfg(not(target_os = "macos"))]
    {
        false
    }
}

#[cfg(target_os = "macos")]
mod macos {
    use super::*;
    use objc2::rc::Retained;
    use objc2::runtime::{AnyClass, AnyObject};
    use objc2::{AnyThread, ClassType, MainThreadMarker, msg_send, sel};
    use objc2_app_kit::{
        NSAccessibility, NSAccessibilityCustomAction, NSApplication, NSApplicationActivationPolicy,
        NSEventMask, NSImage, NSPanel, NSStatusBar, NSStatusItem, NSVariableStatusItemLength, NSWindow,
        NSWindowButton, NSWindowStyleMask, NSWindowTabbingMode,
    };
    use objc2_foundation::{NSArray, NSData, NSObjectProtocol, NSSize, NSString};

    use crate::menus_macos::{RotaShellTarget, install_main_menu};
    use crate::panel_macos::MenuBarPanel;

    pub struct MacShell {
        target: Retained<RotaShellTarget>,
        status_item: Retained<NSStatusItem>,
        panel: MenuBarPanel,
        last_title: String,
        last_visible: Option<bool>,
        last_active_icon: Option<bool>,
        last_badge: String,
        close_hooked: bool,
        open_panel_at_top_pending: bool,
    }

    impl MacShell {
        pub fn new(tx: Sender<ShellEvent>, open_panel_on_launch: bool) -> Option<Self> {
            let mtm = MainThreadMarker::new()?;
            let app = NSApplication::sharedApplication(mtm);
            app.setActivationPolicy(NSApplicationActivationPolicy::Accessory);
            NSWindow::setAllowsAutomaticWindowTabbing(false, mtm);

            let target = RotaShellTarget::new(mtm, tx.clone());

            let status_bar = NSStatusBar::systemStatusBar();
            let status_item = status_bar.statusItemWithLength(NSVariableStatusItemLength);
            target.set_status_item(&status_item);
            if let Some(btn) = status_item.button(mtm) {
                unsafe {
                    btn.setTarget(Some(&target));
                    btn.setAction(Some(sel!(statusItemClicked:)));
                }
                btn.sendActionOn(NSEventMask::LeftMouseUp | NSEventMask::RightMouseUp);
                btn.setAccessibilityLabel(Some(&NSString::from_str("Rota")));
                unsafe {
                    let action_name = NSString::from_str("Show Menu");
                    let show_menu_act: objc2::rc::Retained<NSAccessibilityCustomAction> = objc2::msg_send![
                        <NSAccessibilityCustomAction as objc2::AnyThread>::alloc(),
                        initWithName: &*action_name,
                        target: &*target,
                        selector: sel!(showStatusMenuAction)
                    ];
                    let acts = NSArray::from_slice(&[&*show_menu_act]);
                    btn.setAccessibilityCustomActions(Some(&acts));
                }
                if let Some(img) = load_status_icon(mtm, false) {
                    btn.setImage(Some(&img));
                }
            }

            let panel = MenuBarPanel::new(mtm, tx);
            Some(Self {
                target,
                status_item,
                panel,
                last_title: String::new(),
                last_visible: None,
                last_active_icon: None,
                last_badge: String::new(),
                close_hooked: false,
                open_panel_at_top_pending: open_panel_on_launch,
            })
        }

        pub fn ensure_main_menu(&self) {
            install_reopen_apple_event_handler(&self.target);
            if let Some(mtm) = MainThreadMarker::new() {
                install_main_menu(mtm, &self.target);
            }
        }

        pub fn sync(&mut self, state: &mut AppState) {
            let Some(mtm) = MainThreadMarker::new() else {
                return;
            };
            self.target.sync_validation(state);
            let app = NSApplication::sharedApplication(mtm);

            // 1. Update status item icon, tooltip, and accessibility value
            let active = state.running_count > 0 || state.attention_count > 0;
            if self.last_active_icon != Some(active) {
                self.last_active_icon = Some(active);
                if let Some(btn) = self.status_item.button(mtm)
                    && let Some(img) = load_status_icon(mtm, active)
                {
                    btn.setImage(Some(&img));
                }
            }
            if let Some(btn) = self.status_item.button(mtm) {
                let status_val = match (state.running_count, state.attention_count) {
                    (0, 0) => "Idle".to_string(),
                    (n, 0) => format!("{n} running"),
                    (0, a) => format!("{a} need reply"),
                    (n, a) => format!("{n} running, {a} need reply"),
                };
                let tip = if state.running_count == 0 && state.attention_count == 0 {
                    "Rota".to_string()
                } else {
                    format!("Rota: {status_val}")
                };
                btn.setToolTip(Some(&NSString::from_str(&tip)));
                let ns_val = NSString::from_str(&status_val);
                unsafe {
                    let _: () = msg_send![&*btn, setAccessibilityValue: &*ns_val];
                }
            }

            // 2. Sync main NSWindow visibility, activation policy, Dock badge, and dynamic title
            if let Some(main_win) = find_main_ns_window(&app) {
                if !self.close_hooked {
                    self.close_hooked = true;
                    main_win.setTabbingMode(NSWindowTabbingMode::Disallowed);
                    main_win.setMinSize(NSSize::new(820.0, 520.0));
                    if let Some(close_btn) = main_win.standardWindowButton(NSWindowButton::CloseButton) {
                        unsafe {
                            close_btn.setTarget(Some(&self.target));
                            close_btn.setAction(Some(sel!(hideMainWindow:)));
                        }
                    }
                }
                let title = state.window_title();
                if title != self.last_title {
                    self.last_title = title.clone();
                    main_win.setTitle(&NSString::from_str(&title));
                }
                if self.last_visible != Some(state.main_window_visible) {
                    self.last_visible = Some(state.main_window_visible);
                    if state.main_window_visible {
                        app.setActivationPolicy(NSApplicationActivationPolicy::Regular);
                        #[allow(deprecated)]
                        app.activateIgnoringOtherApps(true);
                        main_win.makeKeyAndOrderFront(None);
                    } else {
                        main_win.orderOut(None);
                        app.setActivationPolicy(NSApplicationActivationPolicy::Accessory);
                    }
                }
            }

            let badge_total = state.unread_count + state.attention_count;
            let badge_str = if state.main_window_visible && badge_total > 0 {
                format!("{badge_total}")
            } else {
                String::new()
            };
            if badge_str != self.last_badge {
                self.last_badge = badge_str.clone();
                let dock = app.dockTile();
                if badge_str.is_empty() {
                    dock.setBadgeLabel(None);
                } else {
                    dock.setBadgeLabel(Some(&NSString::from_str(&badge_str)));
                }
            }

            // 3. Sync menu bar panel
            if self.open_panel_at_top_pending {
                self.open_panel_at_top_pending = false;
                state.panel_visible = true;
                let win_num = self.panel.show_at_top_of_screen(mtm, state);
                LOG.info(&format!("panel window {win_num}"));
            } else if state.panel_visible {
                self.panel.sync_and_present(mtm, &self.status_item, state);
            } else {
                self.panel.hide();
            }
        }
    }

    fn find_main_ns_window(app: &NSApplication) -> Option<Retained<NSWindow>> {
        let wins = app.windows();
        for idx in 0..wins.count() {
            let w = wins.objectAtIndex(idx);
            if !w.isKindOfClass(NSPanel::class()) && w.styleMask().contains(NSWindowStyleMask::Titled) {
                return Some(w);
            }
        }
        None
    }

    fn install_reopen_apple_event_handler(target: &RotaShellTarget) {
        let Some(cls) = AnyClass::get(c"NSAppleEventManager") else {
            return;
        };
        // SAFETY: Registers Cocoa reopen handler (`'aevt'` / `'rapp'`) on shared `NSAppleEventManager`.
        unsafe {
            let mgr: *mut AnyObject = msg_send![cls, sharedAppleEventManager];
            if !mgr.is_null() {
                let _: () = msg_send![
                    mgr,
                    setEventHandler: target,
                    andSelector: sel!(handleReopenAppleEvent:withReplyEvent:),
                    forEventClass: 0x6165_7674u32,
                    andEventID: 0x7261_7070u32
                ];
            }
        }
    }

    fn load_status_icon(_mtm: MainThreadMarker, active: bool) -> Option<Retained<NSImage>> {
        let name = if active { "MenuIconActive" } else { "MenuIcon" };
        if let Some(img) = NSImage::imageNamed(&NSString::from_str(name)) {
            img.setSize(NSSize::new(18.0, 18.0));
            img.setTemplate(true);
            return Some(img);
        }
        let px = 36u32;
        let rgba = rota_ui::rasterize_icon_rgba(
            if active {
                rota_ui::IconKind::Play
            } else {
                rota_ui::IconKind::Clock
            },
            px,
        );
        let tmp = std::env::temp_dir().join(format!("rota-menu-{active}-{}.png", std::process::id()));
        let _ = rota_ui::save_png(&tmp, px, px, &rgba);
        let bytes = std::fs::read(&tmp).ok()?;
        let _ = std::fs::remove_file(&tmp);
        let data = NSData::with_bytes(&bytes);
        let img = NSImage::initWithData(NSImage::alloc(), &data)?;
        img.setSize(NSSize::new(18.0, 18.0));
        img.setTemplate(true);
        Some(img)
    }
}

#[cfg(target_os = "macos")]
pub use macos::MacShell;

#[cfg(not(target_os = "macos"))]
pub struct MacShell;

#[cfg(not(target_os = "macos"))]
impl MacShell {
    pub fn new(_tx: Sender<ShellEvent>, _open_panel_on_launch: bool) -> Option<Self> {
        None
    }
    pub fn ensure_main_menu(&self) {}
    pub fn sync(&mut self, _state: &mut AppState) {}
}
