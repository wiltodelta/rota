use crate::desktop::open_url_or_path;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub struct ComputerUseAccess {
    pub accessibility: bool,
    pub screen_recording: bool,
}

#[cfg(target_os = "macos")]
unsafe extern "C" {
    fn AXIsProcessTrusted() -> bool;
    fn AXIsProcessTrustedWithOptions(options: *const std::ffi::c_void) -> bool;
    fn CGPreflightScreenCaptureAccess() -> bool;
    fn CGRequestScreenCaptureAccess() -> bool;
}

impl ComputerUseAccess {
    pub fn current() -> Self {
        #[cfg(target_os = "macos")]
        {
            // SAFETY: Read-only TCC preflight queries that never prompt.
            unsafe {
                Self {
                    accessibility: AXIsProcessTrusted(),
                    screen_recording: CGPreflightScreenCaptureAccess(),
                }
            }
        }
        #[cfg(not(target_os = "macos"))]
        {
            Self {
                accessibility: true,
                screen_recording: true,
            }
        }
    }

    pub fn request_accessibility() {
        #[cfg(target_os = "macos")]
        {
            use objc2::runtime::AnyObject;
            use objc2_foundation::{NSDictionary, NSNumber, NSString};
            let key = NSString::from_str("AXTrustedCheckOptionPrompt");
            let val = NSNumber::new_bool(true);
            let k_refs: [&NSString; 1] = [&key];
            let v_refs: [&AnyObject; 1] = [val.as_ref()];
            let dict = NSDictionary::from_slices(&k_refs, &v_refs);
            // SAFETY: NSDictionary is toll-free bridged to CFDictionaryRef.
            unsafe {
                let ptr = objc2::rc::Retained::as_ptr(&dict).cast::<std::ffi::c_void>();
                let _ = AXIsProcessTrustedWithOptions(ptr);
            }
        }
    }

    pub fn request_screen_recording() {
        #[cfg(target_os = "macos")]
        {
            // SAFETY: Requests screen capture access or opens System Settings pane if already denied.
            let ok = unsafe { CGRequestScreenCaptureAccess() };
            if !ok {
                open_url_or_path(
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
                );
            }
        }
    }
}

pub fn launch_at_login_enabled() -> bool {
    #[cfg(target_os = "macos")]
    {
        use objc2_service_management::{SMAppService, SMAppServiceStatus};
        // SAFETY: Reads main app login-item registration status.
        unsafe { SMAppService::mainAppService().status() == SMAppServiceStatus::Enabled }
    }
    #[cfg(not(target_os = "macos"))]
    {
        false
    }
}

pub fn set_launch_at_login(enabled: bool) -> Result<(), String> {
    #[cfg(target_os = "macos")]
    {
        use objc2_service_management::SMAppService;
        // SAFETY: Registers or unregisters main app service when inside a signed bundle.
        unsafe {
            let service = SMAppService::mainAppService();
            let res = if enabled {
                service.registerAndReturnError()
            } else {
                service.unregisterAndReturnError()
            };
            res.map_err(|err| err.localizedDescription().to_string())
        }
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = enabled;
        Err("Launch at login is only supported in packaged builds.".to_string())
    }
}

/// Inspects image format and frame count from bytes (PNG, JPEG, GIF, WebP) without external C codecs.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ImageInspection {
    pub mime: &'static str,
    pub extension: &'static str,
    pub animated: bool,
}

pub fn inspect_image_bytes(bytes: &[u8]) -> Option<ImageInspection> {
    if bytes.len() >= 8 && &bytes[..8] == b"\x89PNG\r\n\x1a\n" {
        return Some(ImageInspection {
            mime: "image/png",
            extension: "png",
            animated: false,
        });
    }
    if bytes.len() >= 3 && bytes[0] == 0xFF && bytes[1] == 0xD8 && bytes[2] == 0xFF {
        return Some(ImageInspection {
            mime: "image/jpeg",
            extension: "jpg",
            animated: false,
        });
    }
    if bytes.len() >= 6 && (&bytes[..6] == b"GIF87a" || &bytes[..6] == b"GIF89a") {
        let descriptors = bytes.iter().filter(|&&b| b == 0x2C).count();
        return Some(ImageInspection {
            mime: "image/gif",
            extension: "gif",
            animated: descriptors > 1,
        });
    }
    if bytes.len() >= 12 && &bytes[..4] == b"RIFF" && &bytes[8..12] == b"WEBP" {
        return Some(ImageInspection {
            mime: "image/webp",
            extension: "webp",
            animated: false,
        });
    }
    None
}

/// Checks whether `url` answers any HTTP status within `timeout_secs` using `curl`.
pub fn probe_http_reachable(url: &str, timeout_secs: u64) -> bool {
    let Ok(status) = std::process::Command::new("/usr/bin/curl")
        .args([
            "-sS",
            "-I",
            "-o",
            "/dev/null",
            "--max-time",
            &timeout_secs.to_string(),
            url,
        ])
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .status()
    else {
        return false;
    };
    status.success()
}

/// Process CPU time and resident memory for `PerformanceDiagnostics`.
#[derive(Debug, Clone, Copy, Default)]
pub struct ProcessResourceReading {
    pub uptime: f64,
    pub cpu_seconds: Option<f64>,
    pub resident_bytes: Option<u64>,
}

impl ProcessResourceReading {
    pub fn current() -> Self {
        let uptime = crate::power::system_uptime_seconds();
        // SAFETY: Standard `getrusage(RUSAGE_SELF)`.
        let cpu_seconds = unsafe {
            let mut usage: libc::rusage = std::mem::zeroed();
            if libc::getrusage(libc::RUSAGE_SELF, &raw mut usage) == 0 {
                let sec = (usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) as f64;
                let usec = (usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) as f64 / 1_000_000.0;
                Some(sec + usec)
            } else {
                None
            }
        };
        #[cfg(target_os = "macos")]
        let resident_bytes = {
            #[repr(C)]
            struct MachTaskBasicInfo {
                virtual_size: u64,
                resident_size: u64,
                resident_size_max: u64,
                user_time: [u32; 2],
                system_time: [u32; 2],
                policy: i32,
                suspend_count: i32,
            }
            unsafe extern "C" {
                static mut mach_task_self_: u32;
                fn task_info(
                    target_task: u32,
                    flavor: u32,
                    task_info_out: *mut i32,
                    task_info_out_cnt: *mut u32,
                ) -> i32;
            }
            const MACH_TASK_BASIC_INFO: u32 = 20;
            // SAFETY: Queries current Mach task resident bytes.
            unsafe {
                let mut info: MachTaskBasicInfo = std::mem::zeroed();
                let mut count =
                    (std::mem::size_of::<MachTaskBasicInfo>() / std::mem::size_of::<i32>()) as u32;
                let kr = task_info(
                    mach_task_self_,
                    MACH_TASK_BASIC_INFO,
                    (&raw mut info).cast::<i32>(),
                    &raw mut count,
                );
                if kr == 0 { Some(info.resident_size) } else { None }
            }
        };
        #[cfg(not(target_os = "macos"))]
        let resident_bytes = None;

        Self {
            uptime,
            cpu_seconds,
            resident_bytes,
        }
    }

    pub fn cpu_percent_since(self, previous: Option<Self>) -> Option<f64> {
        let prev = previous?;
        let now_cpu = self.cpu_seconds?;
        let old_cpu = prev.cpu_seconds?;
        if self.uptime > prev.uptime && now_cpu >= old_cpu {
            Some((now_cpu - old_cpu) / (self.uptime - prev.uptime) * 100.0)
        } else {
            None
        }
    }
}
