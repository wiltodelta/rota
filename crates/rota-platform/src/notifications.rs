use std::sync::mpsc::Sender;
use std::time::Duration;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum NotificationUserEvent {
    OpenSession(String),
    OpenRoutine(String),
    ReplyToSession { session_id: String, text: String },
}

#[derive(Debug, Clone)]
pub struct NotificationPayload {
    pub id: String,
    pub title: String,
    pub subtitle: Option<String>,
    pub body: String,
    pub sound: bool,
    pub session_id: Option<String>,
    pub routine_id: Option<String>,
    pub allow_inline_reply: bool,
    pub temporary: bool,
}

/// Posts macOS UserNotifications when running inside a signed bundle, and withdraws
/// informational notifications after 8 seconds.
pub struct SystemNotifier {
    events: Option<Sender<NotificationUserEvent>>,
}

impl SystemNotifier {
    pub fn new(events: Option<Sender<NotificationUserEvent>>) -> Self {
        let notifier = Self { events };
        notifier.configure();
        notifier
    }

    #[cfg(target_os = "macos")]
    fn main_app_bundle_ready() -> bool {
        use objc2_foundation::NSBundle;
        let main = NSBundle::mainBundle();
        let Some(id) = main.bundleIdentifier() else {
            return false;
        };
        if id.is_empty() {
            return false;
        }
        let path = main.bundlePath().to_string();
        if !path.ends_with(".app") {
            return false;
        }
        unsafe extern "C" {
            fn LSRegisterURL(in_url: *const std::ffi::c_void, in_update: u8) -> i32;
        }
        let url = main.bundleURL();
        // SAFETY: Ensures LaunchServices knows this `.app` bundle before `UNUserNotificationCenter` queries `bundleProxyForCurrentProcess`.
        unsafe {
            let ptr = objc2::rc::Retained::as_ptr(&url).cast::<std::ffi::c_void>();
            let _ = LSRegisterURL(ptr, 1);
        }
        true
    }

    fn configure(&self) {
        #[cfg(target_os = "macos")]
        {
            if !Self::main_app_bundle_ready() {
                return;
            }
            let _ = &self.events;
            use block2::RcBlock;
            use objc2_foundation::{NSError, NSSet, NSString};
            use objc2_user_notifications::{
                UNAuthorizationOptions, UNNotificationActionOptions, UNNotificationCategory,
                UNNotificationCategoryOptions, UNTextInputNotificationAction, UNUserNotificationCenter,
            };
            let center = UNUserNotificationCenter::currentNotificationCenter();
            let reply = UNTextInputNotificationAction::actionWithIdentifier_title_options_textInputButtonTitle_textInputPlaceholder(
                &NSString::from_str("reply"),
                &NSString::from_str("Reply"),
                UNNotificationActionOptions::empty(),
                &NSString::from_str("Send"),
                &NSString::from_str("Reply"),
            );
            let actions = objc2_foundation::NSArray::from_slice(&[reply.as_ref()]);
            let empty_intents = objc2_foundation::NSArray::<NSString>::new();
            let category = UNNotificationCategory::categoryWithIdentifier_actions_intentIdentifiers_options(
                &NSString::from_str("rota.reply"),
                &actions,
                &empty_intents,
                UNNotificationCategoryOptions::empty(),
            );
            let categories = NSSet::from_slice(&[category.as_ref()]);
            center.setNotificationCategories(&categories);

            let log = crate::log::Logger::new("notifications");
            let block = RcBlock::new(move |granted: objc2::runtime::Bool, err: *mut NSError| {
                if !err.is_null() {
                    log.error("Notification authorization failed");
                } else {
                    log.info(if granted.as_bool() {
                        "Notifications allowed"
                    } else {
                        "Notifications denied"
                    });
                }
            });
            center.requestAuthorizationWithOptions_completionHandler(
                UNAuthorizationOptions::Alert | UNAuthorizationOptions::Badge | UNAuthorizationOptions::Sound,
                &block,
            );
        }
    }

    pub fn post(&self, payload: NotificationPayload) {
        #[cfg(target_os = "macos")]
        {
            if !Self::main_app_bundle_ready() {
                return;
            }
            use block2::RcBlock;
            use objc2::runtime::AnyObject;
            use objc2_foundation::{NSDictionary, NSError, NSString};
            use objc2_user_notifications::{
                UNMutableNotificationContent, UNNotificationRequest, UNNotificationSound,
                UNUserNotificationCenter,
            };
            unsafe {
                let center = UNUserNotificationCenter::currentNotificationCenter();
                let content = UNMutableNotificationContent::new();
                content.setTitle(&NSString::from_str(&payload.title));
                if let Some(sub) = &payload.subtitle {
                    content.setSubtitle(&NSString::from_str(sub));
                }
                content.setBody(&NSString::from_str(&payload.body));
                if payload.sound {
                    content.setSound(Some(&UNNotificationSound::defaultSound()));
                }
                if payload.allow_inline_reply {
                    content.setCategoryIdentifier(&NSString::from_str("rota.reply"));
                }
                if let Some(session) = &payload.session_id {
                    let k = NSString::from_str("session");
                    let v = NSString::from_str(session);
                    let keys: [&NSString; 1] = [&k];
                    let vals: [&AnyObject; 1] = [v.as_ref()];
                    let dict: objc2::rc::Retained<NSDictionary<NSString, AnyObject>> =
                        NSDictionary::from_slices(&keys, &vals);
                    let raw = objc2::rc::Retained::as_ptr(&dict).cast::<NSDictionary>();
                    content.setUserInfo(&*raw);
                } else if let Some(routine) = &payload.routine_id {
                    let k = NSString::from_str("routine");
                    let v = NSString::from_str(routine);
                    let keys: [&NSString; 1] = [&k];
                    let vals: [&AnyObject; 1] = [v.as_ref()];
                    let dict: objc2::rc::Retained<NSDictionary<NSString, AnyObject>> =
                        NSDictionary::from_slices(&keys, &vals);
                    let raw = objc2::rc::Retained::as_ptr(&dict).cast::<NSDictionary>();
                    content.setUserInfo(&*raw);
                }

                let req_id = payload.id.clone();
                let temporary = payload.temporary;
                let request = UNNotificationRequest::requestWithIdentifier_content_trigger(
                    &NSString::from_str(&req_id),
                    &content,
                    None,
                );
                let block = RcBlock::new(move |err: *mut NSError| {
                    if !err.is_null() || !temporary {
                        return;
                    }
                    let remove_id = req_id.clone();
                    std::thread::spawn(move || {
                        std::thread::sleep(Duration::from_secs(8));
                        if Self::main_app_bundle_ready() {
                            let ns_id = NSString::from_str(&remove_id);
                            let arr = objc2_foundation::NSArray::from_slice(&[ns_id.as_ref()]);
                            UNUserNotificationCenter::currentNotificationCenter()
                                .removeDeliveredNotificationsWithIdentifiers(&arr);
                        }
                    });
                });
                center.addNotificationRequest_withCompletionHandler(&request, Some(&block));
            }
        }
        #[cfg(not(target_os = "macos"))]
        {
            let _ = payload;
        }
    }
}
