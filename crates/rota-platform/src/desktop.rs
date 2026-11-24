use std::path::{Path, PathBuf};

pub fn home_dir() -> PathBuf {
    std::env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/tmp"))
}

pub fn expand_tilde(path: &str) -> String {
    if path == "~" {
        return home_dir().to_string_lossy().into_owned();
    }
    if let Some(rest) = path.strip_prefix("~/") {
        return home_dir().join(rest).to_string_lossy().into_owned();
    }
    path.to_string()
}

pub fn abbreviate_tilde(path: &str) -> String {
    let home = home_dir().to_string_lossy().into_owned();
    if path == home {
        return "~".to_string();
    }
    if let Some(rest) = path.strip_prefix(&format!("{home}/")) {
        return format!("~/{rest}");
    }
    path.to_string()
}

pub fn current_username() -> String {
    std::env::var("USER")
        .or_else(|_| std::env::var("LOGNAME"))
        .unwrap_or_else(|_| "user".to_string())
}

/// Resolves the `.app` bundle directory containing this executable (including `Contents/Helpers/rota`).
pub fn enclosing_app_bundle() -> Option<PathBuf> {
    let exe = std::env::current_exe().ok()?;
    let canonical = std::fs::canonicalize(&exe).unwrap_or(exe);
    let mut cursor = canonical.as_path();
    while let Some(parent) = cursor.parent() {
        if parent.extension().and_then(|e| e.to_str()) == Some("app") {
            return Some(parent.to_path_buf());
        }
        cursor = parent;
    }
    None
}

/// Reads `CFBundleIdentifier` of the running bundle or enclosing `.app`.
pub fn app_bundle_identifier() -> Option<String> {
    #[cfg(target_os = "macos")]
    {
        use objc2_foundation::{NSBundle, NSString};
        if let Some(id) = NSBundle::mainBundle().bundleIdentifier() {
            let s = id.to_string();
            if !s.is_empty() {
                return Some(s);
            }
        }
        if let Some(app) = enclosing_app_bundle() {
            let ns_path = NSString::from_str(&app.to_string_lossy());
            if let Some(bundle) = NSBundle::bundleWithPath(&ns_path)
                && let Some(id) = bundle.bundleIdentifier()
            {
                let s = id.to_string();
                if !s.is_empty() {
                    return Some(s);
                }
            }
        }
    }
    None
}

pub fn bundle_short_version() -> String {
    #[cfg(target_os = "macos")]
    {
        use objc2::rc::Retained;
        use objc2_foundation::{NSBundle, NSString};
        let bundle = enclosing_app_bundle()
            .and_then(|app| NSBundle::bundleWithPath(&NSString::from_str(&app.to_string_lossy())))
            .unwrap_or_else(NSBundle::mainBundle);
        if let Some(info) = bundle.infoDictionary() {
            let key = NSString::from_str("CFBundleShortVersionString");
            if let Some(val) = info.objectForKey(&key)
                && let Ok(ver) = Retained::downcast::<NSString>(val)
            {
                let text = ver.to_string();
                if !text.is_empty() {
                    return text;
                }
            }
        }
    }
    "dev".to_string()
}

pub fn bundled_helper_path() -> Option<PathBuf> {
    if let Some(app) = enclosing_app_bundle() {
        let helper = app.join("Contents/Helpers/rota");
        if helper.exists() {
            return Some(helper);
        }
    }
    if let Ok(exe) = std::env::current_exe()
        && let Some(dir) = exe.parent()
    {
        let sibling = dir.join("rota");
        if sibling.exists() {
            return Some(sibling);
        }
    }
    None
}

pub fn bundled_fonts_directory() -> Option<PathBuf> {
    if let Some(app) = enclosing_app_bundle() {
        let direct = app.join("Contents/Resources/Fonts");
        if direct.is_dir() {
            return Some(direct);
        }
        let legacy = app.join("Contents/Resources/Rota_Rota.bundle/Fonts");
        if legacy.is_dir() {
            return Some(legacy);
        }
    }
    let repo_root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()?
        .parent()?
        .to_path_buf();
    let candidate = repo_root.join("Resources/Fonts");
    candidate.is_dir().then_some(candidate)
}

/// Registers bundled `.ttf` faces (`IBM Plex Sans`, `JetBrains Mono`) at process scope.
pub fn register_bundled_fonts() {
    static ONCE: std::sync::Once = std::sync::Once::new();
    ONCE.call_once(|| {
        let Some(folder) = bundled_fonts_directory() else {
            return;
        };
        let mut ttf_files = Vec::new();
        collect_ttfs(&folder, &mut ttf_files);
        #[cfg(target_os = "macos")]
        {
            use objc2_core_foundation::CFURL;
            use objc2_core_text::{CTFontManagerRegisterFontsForURL, CTFontManagerScope};
            for path in ttf_files {
                if let Some(cf_url) = CFURL::from_file_path(&path) {
                    // SAFETY: `cf_url` is a valid file CFURL; errors are ignored if already registered.
                    unsafe {
                        let _ = CTFontManagerRegisterFontsForURL(
                            &cf_url,
                            CTFontManagerScope::Process,
                            std::ptr::null_mut(),
                        );
                    }
                }
            }
        }
    });
}

fn collect_ttfs(dir: &Path, out: &mut Vec<PathBuf>) {
    let Ok(entries) = std::fs::read_dir(dir) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            collect_ttfs(&path, out);
        } else if path.extension().and_then(|e| e.to_str()) == Some("ttf") {
            out.push(path);
        }
    }
}

/// Launches `Rota.app` in the background without stealing focus, forwarding `ROTA_DATA_DIR`.
pub fn launch_rota_background(data_dir: Option<&str>) -> Result<(), String> {
    let app_path = enclosing_app_bundle()
        .or_else(find_installed_rota_app)
        .ok_or_else(|| "Rota is not running and its app was not found.".to_string())?;
    let mut cmd = std::process::Command::new("/usr/bin/open");
    cmd.arg("-g")
        .arg("-a")
        .arg(&app_path)
        .arg("--env")
        .arg("ROTA_BACKGROUND=1");
    if let Some(dir) = data_dir
        && !dir.is_empty()
    {
        cmd.arg("--env").arg(format!("ROTA_DATA_DIR={dir}"));
    }
    let status = cmd.status().map_err(|e| e.to_string())?;
    if status.success() {
        Ok(())
    } else {
        Err(format!("Could not start Rota ({status})."))
    }
}

fn find_installed_rota_app() -> Option<PathBuf> {
    #[cfg(target_os = "macos")]
    {
        use objc2_app_kit::NSWorkspace;
        use objc2_foundation::NSString;
        let ws = NSWorkspace::sharedWorkspace();
        for id in ["com.wiltodelta.rota", "com.wiltodelta.rota.dev"] {
            if let Some(url) = ws.URLForApplicationWithBundleIdentifier(&NSString::from_str(id))
                && let Some(path) = url.path()
            {
                return Some(PathBuf::from(path.to_string()));
            }
        }
    }
    let apps = PathBuf::from("/Applications/Rota.app");
    apps.exists().then_some(apps)
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum KnownTerminal {
    Terminal,
    ITerm,
    Ghostty,
}

impl KnownTerminal {
    pub const ALL: [Self; 3] = [Self::Terminal, Self::ITerm, Self::Ghostty];

    pub fn bundle_id(self) -> &'static str {
        match self {
            Self::Terminal => "com.apple.Terminal",
            Self::ITerm => "com.googlecode.iterm2",
            Self::Ghostty => "com.mitchellh.ghostty",
        }
    }

    pub fn title(self) -> &'static str {
        match self {
            Self::Terminal => "Terminal",
            Self::ITerm => "iTerm2",
            Self::Ghostty => "Ghostty",
        }
    }

    pub fn app_path(self) -> Option<PathBuf> {
        #[cfg(target_os = "macos")]
        {
            use objc2_app_kit::NSWorkspace;
            use objc2_foundation::NSString;
            let ws = NSWorkspace::sharedWorkspace();
            let url = ws.URLForApplicationWithBundleIdentifier(&NSString::from_str(self.bundle_id()))?;
            let path = url.path()?;
            Some(PathBuf::from(path.to_string()))
        }
        #[cfg(not(target_os = "macos"))]
        {
            None
        }
    }
}

pub fn installed_terminals() -> Vec<KnownTerminal> {
    KnownTerminal::ALL
        .into_iter()
        .filter(|t| t.app_path().is_some())
        .collect()
}

pub fn open_terminal_script(script: &Path, terminal_bundle_or_path: Option<&str>) -> Result<(), String> {
    #[cfg(target_os = "macos")]
    {
        let mut cmd = std::process::Command::new("/usr/bin/open");
        if let Some(choice) = terminal_bundle_or_path
            && !choice.is_empty()
        {
            if choice == KnownTerminal::Ghostty.bundle_id() || choice.ends_with("Ghostty.app") {
                if choice.ends_with(".app") {
                    cmd.arg("-n").arg("-a").arg(choice);
                } else {
                    cmd.arg("-n").arg("-b").arg(choice);
                }
                cmd.arg("--args").arg("-e").arg(script);
                let status = cmd.status().map_err(|e| e.to_string())?;
                return status
                    .success()
                    .then_some(())
                    .ok_or_else(|| format!("Terminal launch failed ({status})"));
            }
            if choice.ends_with(".app") || choice.starts_with('/') {
                cmd.arg("-a").arg(choice);
            } else {
                cmd.arg("-b").arg(choice);
            }
        }
        cmd.arg(script);
        let status = cmd.status().map_err(|e| e.to_string())?;
        status
            .success()
            .then_some(())
            .ok_or_else(|| format!("Terminal launch failed ({status})"))
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = (script, terminal_bundle_or_path);
        Err("Terminal launching is not configured on this platform.".to_string())
    }
}

pub fn open_url_or_path(target: &str) {
    #[cfg(target_os = "macos")]
    {
        let _ = std::process::Command::new("/usr/bin/open").arg(target).spawn();
    }
    #[cfg(target_os = "linux")]
    {
        let _ = std::process::Command::new("xdg-open").arg(target).spawn();
    }
}

pub fn clipboard_get() -> Option<String> {
    #[cfg(target_os = "macos")]
    {
        use objc2_app_kit::{NSPasteboard, NSPasteboardTypeString};
        let pb = NSPasteboard::generalPasteboard();
        // SAFETY: NSPasteboardTypeString is a valid system pasteboard type constant.
        let text = unsafe { pb.stringForType(NSPasteboardTypeString)? };
        Some(text.to_string())
    }
    #[cfg(not(target_os = "macos"))]
    {
        None
    }
}

pub fn clipboard_set(text: &str) {
    #[cfg(target_os = "macos")]
    {
        use objc2_app_kit::{NSPasteboard, NSPasteboardTypeString};
        use objc2_foundation::NSString;
        let pb = NSPasteboard::generalPasteboard();
        pb.clearContents();
        let ns = NSString::from_str(text);
        // SAFETY: NSPasteboardTypeString is a valid pasteboard type.
        unsafe {
            let _ = pb.setString_forType(&ns, NSPasteboardTypeString);
        }
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = text;
    }
}

pub fn pick_directory(initial: Option<&str>) -> Option<PathBuf> {
    #[cfg(target_os = "macos")]
    {
        use objc2::MainThreadMarker;
        use objc2_app_kit::{NSModalResponseOK, NSOpenPanel};
        use objc2_foundation::{NSString, NSURL};
        let mtm = MainThreadMarker::new()?;
        let panel = NSOpenPanel::openPanel(mtm);
        panel.setCanChooseDirectories(true);
        panel.setCanChooseFiles(false);
        panel.setAllowsMultipleSelection(false);
        if let Some(dir) = initial
            && !dir.is_empty()
        {
            let url = NSURL::fileURLWithPath(&NSString::from_str(dir));
            panel.setDirectoryURL(Some(&url));
        }
        if panel.runModal() == NSModalResponseOK
            && let Some(url) = panel.URL()
            && let Some(path) = url.path()
        {
            return Some(PathBuf::from(path.to_string()));
        }
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = initial;
    }
    None
}

pub fn pick_files(multiple: bool, initial_dir: Option<&str>) -> Vec<PathBuf> {
    #[cfg(target_os = "macos")]
    {
        use objc2::MainThreadMarker;
        use objc2_app_kit::{NSModalResponseOK, NSOpenPanel};
        use objc2_foundation::{NSString, NSURL};
        let Some(mtm) = MainThreadMarker::new() else {
            return Vec::new();
        };
        let panel = NSOpenPanel::openPanel(mtm);
        panel.setCanChooseDirectories(false);
        panel.setCanChooseFiles(true);
        panel.setAllowsMultipleSelection(multiple);
        if let Some(dir) = initial_dir
            && !dir.is_empty()
        {
            let url = NSURL::fileURLWithPath(&NSString::from_str(dir));
            panel.setDirectoryURL(Some(&url));
        }
        if panel.runModal() == NSModalResponseOK {
            let urls = panel.URLs();
            let mut out = Vec::with_capacity(urls.count());
            for idx in 0..urls.count() {
                if let Some(path) = urls.objectAtIndex(idx).path() {
                    out.push(PathBuf::from(path.to_string()));
                }
            }
            return out;
        }
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = (multiple, initial_dir);
    }
    Vec::new()
}
