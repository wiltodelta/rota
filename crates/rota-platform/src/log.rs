use std::ffi::CString;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum LogLevel {
    Info = 0,
    Notice = 1,
    Error = 2,
}

#[cfg(target_os = "macos")]
unsafe extern "C" {
    fn rota_os_log_emit(
        subsystem: *const std::os::raw::c_char,
        category: *const std::os::raw::c_char,
        kind: u8,
        message: *const std::os::raw::c_char,
    );
}

#[derive(Debug, Clone, Copy)]
pub struct Logger {
    category: &'static str,
}

impl Logger {
    pub const fn new(category: &'static str) -> Self {
        Self { category }
    }

    pub fn info(&self, message: &str) {
        self.emit(LogLevel::Info, message);
    }

    pub fn notice(&self, message: &str) {
        self.emit(LogLevel::Notice, message);
    }

    pub fn warning(&self, message: &str) {
        self.emit(LogLevel::Notice, message);
    }

    pub fn error(&self, message: &str) {
        self.emit(LogLevel::Error, message);
    }

    fn emit(&self, level: LogLevel, message: &str) {
        #[cfg(target_os = "macos")]
        {
            let subsystem =
                crate::desktop::app_bundle_identifier().unwrap_or_else(|| "com.wiltodelta.rota".to_string());
            let Ok(c_sub) = CString::new(subsystem) else {
                return;
            };
            let Ok(c_cat) = CString::new(self.category) else {
                return;
            };
            let sanitized = message.replace('\0', " ");
            let Ok(c_msg) = CString::new(sanitized) else {
                return;
            };
            // SAFETY: All pointers are NUL-terminated CStrings alive for the call duration.
            unsafe {
                rota_os_log_emit(c_sub.as_ptr(), c_cat.as_ptr(), level as u8, c_msg.as_ptr());
            }
        }
        #[cfg(not(target_os = "macos"))]
        {
            let tag = match level {
                LogLevel::Info => "INFO",
                LogLevel::Notice => "NOTICE",
                LogLevel::Error => "ERROR",
            };
            eprintln!("[rota:{}:{tag}] {message}", self.category);
        }
    }
}
