use std::fs;
use std::path::{Path, PathBuf};

use rota_core::model::Harness;
use rota_core::runners::ExecutableDiscovery;
use serde_json::Value;
use uuid::Uuid;

pub struct TempDir(PathBuf);

impl TempDir {
    pub fn new(prefix: &str) -> Self {
        let dir = std::env::temp_dir().join(format!("{prefix}-{}", Uuid::new_v4()));
        fs::create_dir_all(&dir).expect("create temp dir");
        Self(dir)
    }

    pub fn path(&self) -> &Path {
        &self.0
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

pub fn is_executable(path: &str) -> bool {
    use std::os::unix::fs::PermissionsExt;
    fs::metadata(path)
        .map(|m| m.is_file() && (m.permissions().mode() & 0o111 != 0))
        .unwrap_or(false)
}

fn suite_executable(domain: &str, key: &str) -> Option<String> {
    let xml = std::process::Command::new("/usr/bin/defaults")
        .args(["export", domain, "-"])
        .stderr(std::process::Stdio::null())
        .output()
        .ok()
        .filter(|o| o.status.success())?;
    let mut plutil = std::process::Command::new("/usr/bin/plutil")
        .args(["-extract", "executables", "json", "-o", "-", "-"])
        .stdin(std::process::Stdio::piped())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .spawn()
        .ok()?;
    if let Some(mut stdin) = plutil.stdin.take() {
        use std::io::Write;
        let _ = stdin.write_all(&xml.stdout);
    }
    let out = plutil.wait_with_output().ok().filter(|o| o.status.success())?;
    let root: Value = serde_json::from_slice(&out.stdout).ok()?;
    root.get(key)?
        .as_str()
        .map(ToOwned::to_owned)
        .filter(|s| !s.is_empty())
}

pub fn configured_or_installed_executable(harness: Harness) -> Option<String> {
    if harness == Harness::Shell {
        let sh = harness.default_executable();
        return is_executable(&sh).then_some(sh);
    }
    let domain = std::env::var("ROTA_BUNDLE_ID").unwrap_or_else(|_| "com.wiltodelta.rota".into());
    let chosen = suite_executable(&domain, harness.as_str());
    let path = chosen
        .or_else(|| {
            ExecutableDiscovery::installed_agents()
                .remove(&harness)
                .and_then(|mut list| {
                    if list.is_empty() {
                        None
                    } else {
                        Some(list.swap_remove(0).path)
                    }
                })
        })
        .unwrap_or_else(|| harness.default_executable());
    if is_executable(&path) {
        Some(path)
    } else {
        eprintln!("Skipping {}: executable not installed at {path}", harness.title());
        None
    }
}
