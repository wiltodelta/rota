use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Mutex, OnceLock};

struct UpdaterState {
    pending_version: Mutex<Option<String>>,
    relaunching_for_update: AtomicBool,
    #[cfg(target_os = "macos")]
    controller_ptr: Mutex<usize>,
}

static STATE: OnceLock<UpdaterState> = OnceLock::new();

fn state() -> &'static UpdaterState {
    STATE.get_or_init(|| UpdaterState {
        pending_version: Mutex::new(None),
        relaunching_for_update: AtomicBool::new(false),
        #[cfg(target_os = "macos")]
        controller_ptr: Mutex::new(0),
    })
}

/// Dynamic bridge to `Sparkle.framework` (`SPUStandardUpdaterController`) when packaged inside `Rota.app`.
pub struct SystemUpdater;

impl SystemUpdater {
    pub fn version() -> String {
        crate::desktop::bundle_short_version()
    }

    pub fn pending_version() -> Option<String> {
        state().pending_version.lock().unwrap().clone()
    }

    pub fn set_pending_version(version: Option<String>) {
        *state().pending_version.lock().unwrap() = version;
    }

    pub fn relaunching_for_update() -> bool {
        state().relaunching_for_update.load(Ordering::SeqCst)
    }

    pub fn start() {
        #[cfg(target_os = "macos")]
        {
            let mut guard = state().controller_ptr.lock().unwrap();
            if *guard != 0 {
                return;
            }
            let Some(app) = crate::desktop::enclosing_app_bundle() else {
                return;
            };
            let dylib = app.join("Contents/Frameworks/Sparkle.framework/Sparkle");
            let Ok(c_path) = std::ffi::CString::new(dylib.to_string_lossy().as_bytes()) else {
                return;
            };
            // SAFETY: Loads embedded Sparkle.framework from the signed app bundle when present.
            unsafe {
                let handle = libc::dlopen(c_path.as_ptr(), libc::RTLD_LAZY | libc::RTLD_GLOBAL);
                if handle.is_null() {
                    return;
                }
                let Some(cls) = objc2::runtime::AnyClass::get(c"SPUStandardUpdaterController") else {
                    return;
                };
                let alloc: *mut objc2::runtime::AnyObject = objc2::msg_send![cls, alloc];
                if alloc.is_null() {
                    return;
                }
                let null_obj: *mut objc2::runtime::AnyObject = std::ptr::null_mut();
                let controller: *mut objc2::runtime::AnyObject = objc2::msg_send![
                    alloc,
                    initWithStartingUpdater: true,
                    updaterDelegate: null_obj,
                    userDriverDelegate: null_obj
                ];
                if !controller.is_null() {
                    *guard = controller as usize;
                }
            }
        }
    }

    pub fn automatically_checks() -> bool {
        #[cfg(target_os = "macos")]
        {
            let ptr = *state().controller_ptr.lock().unwrap();
            if ptr != 0 {
                // SAFETY: `ptr` is a live `SPUStandardUpdaterController` allocated in `start()`.
                unsafe {
                    let ctrl = ptr as *mut objc2::runtime::AnyObject;
                    let updater: *mut objc2::runtime::AnyObject = objc2::msg_send![ctrl, updater];
                    if !updater.is_null() {
                        let checks: objc2::runtime::Bool =
                            objc2::msg_send![updater, automaticallyChecksForUpdates];
                        return checks.as_bool();
                    }
                }
            }
        }
        crate::desktop::app_bundle_identifier().is_some_and(|id| !id.ends_with(".dev"))
    }

    pub fn set_automatically_checks(enabled: bool) {
        #[cfg(target_os = "macos")]
        {
            let ptr = *state().controller_ptr.lock().unwrap();
            if ptr != 0 {
                // SAFETY: `ptr` is a live `SPUStandardUpdaterController`.
                unsafe {
                    let ctrl = ptr as *mut objc2::runtime::AnyObject;
                    let updater: *mut objc2::runtime::AnyObject = objc2::msg_send![ctrl, updater];
                    if !updater.is_null() {
                        let _: () = objc2::msg_send![updater, setAutomaticallyChecksForUpdates: enabled];
                    }
                }
            }
        }
    }

    pub fn check_for_updates() {
        #[cfg(target_os = "macos")]
        {
            let ptr = *state().controller_ptr.lock().unwrap();
            if ptr != 0 {
                // SAFETY: Activates app and triggers Sparkle's user-initiated update check.
                unsafe {
                    if let Some(mtm) = objc2::MainThreadMarker::new() {
                        objc2_app_kit::NSApplication::sharedApplication(mtm).activate();
                    }
                    let ctrl = ptr as *mut objc2::runtime::AnyObject;
                    let sender: *mut objc2::runtime::AnyObject = std::ptr::null_mut();
                    let _: () = objc2::msg_send![ctrl, checkForUpdates: sender];
                }
            }
        }
    }
}
