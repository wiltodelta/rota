use std::collections::{HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::process::{Command, Stdio};
use std::time::Duration;

use rota_platform::{bundled_helper_path, current_username, home_dir};
use serde_json::{Value, json};
use uuid::Uuid;

use crate::model::Harness;
use crate::model::serde_ext::to_sorted_pretty_vec;
use crate::runners::{ProcessLauncher, is_executable_file};
use crate::storage::{atomic_write_bytes, resolve_symlinks_best_effort};

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct InstalledExecutable {
    pub path: String,
    pub version: Option<String>,
}

pub struct ExecutableDiscovery;

impl ExecutableDiscovery {
    pub fn installed_agents() -> HashMap<Harness, Vec<InstalledExecutable>> {
        let home = home_dir();
        let mut dirs = Self::login_path(&home);
        dirs.extend(Self::known_directories(&home));
        Harness::AGENTS
            .into_iter()
            .map(|h| (h, Self::installed(h, &dirs)))
            .collect()
    }

    pub fn known_directories(home: &Path) -> Vec<String> {
        let mut out: Vec<String> = [
            ".local/bin",
            ".grok/bin",
            ".bun/bin",
            ".npm-global/bin",
            ".volta/bin",
        ]
        .into_iter()
        .map(|rel| home.join(rel).to_string_lossy().into_owned())
        .collect();
        out.push("/opt/homebrew/bin".into());
        out.push("/usr/local/bin".into());
        out
    }

    pub fn find(name: &str, directories: &[String]) -> Vec<String> {
        let mut seen = HashSet::new();
        let mut found = Vec::new();
        for dir in directories {
            if dir.is_empty() {
                continue;
            }
            let candidate = Path::new(dir).join(name);
            if !is_executable_file(&candidate) {
                continue;
            }
            let real = resolve_symlinks_best_effort(&candidate);
            if seen.insert(real) {
                found.push(candidate.to_string_lossy().into_owned());
            }
        }
        found
    }

    pub fn login_path(home: &Path) -> Vec<String> {
        let user = current_username();
        let Ok(output) = Command::new("/usr/bin/env")
            .args([
                "-i",
                &format!("HOME={}", home.display()),
                &format!("USER={user}"),
                &format!("LOGNAME={user}"),
                "SHELL=/bin/zsh",
                "/bin/zsh",
                "-lc",
                "printf %s \"$PATH\"",
            ])
            .current_dir(home)
            .stdin(Stdio::null())
            .stderr(Stdio::null())
            .output()
        else {
            return Vec::new();
        };
        if !output.status.success() {
            return Vec::new();
        }
        String::from_utf8_lossy(&output.stdout)
            .split(':')
            .filter(|s| !s.is_empty())
            .map(ToOwned::to_owned)
            .collect()
    }

    fn installed(harness: Harness, directories: &[String]) -> Vec<InstalledExecutable> {
        let paths = Self::find(harness.command_name(), directories);
        std::thread::scope(|scope| {
            let handles: Vec<_> = paths
                .into_iter()
                .map(|path| {
                    scope.spawn(move || {
                        let ver = Self::version(&path, Duration::from_secs(5));
                        InstalledExecutable { path, version: ver }
                    })
                })
                .collect();
            handles.into_iter().filter_map(|h| h.join().ok()).collect()
        })
    }

    pub fn version(path: &str, timeout: Duration) -> Option<String> {
        let (status, out) = ProcessLauncher::capture(
            path,
            &["--version".to_string()],
            &std::env::temp_dir(),
            Some(timeout),
            false,
            true,
            &HashMap::new(),
        );
        if status != 0 {
            return None;
        }
        let line = out.lines().next()?.trim();
        (!line.is_empty()).then(|| line.to_string())
    }
}

pub struct AgentAccess;

impl AgentAccess {
    pub const SERVER_NAME: &'static str = "rota";

    pub fn command_link() -> PathBuf {
        Self::command_link_in(&home_dir())
    }

    pub fn command_link_in(home: &Path) -> PathBuf {
        home.join(".local/bin/rota")
    }

    pub fn helper() -> Option<PathBuf> {
        bundled_helper_path()
    }

    pub fn command_installed(link: &Path, helper: &Path) -> bool {
        if !link.exists() {
            return false;
        }
        resolve_symlinks_best_effort(link) == resolve_symlinks_best_effort(helper)
    }

    pub fn install_command(link: &Path, helper: &Path) -> Result<(), String> {
        if let Some(parent) = link.parent() {
            std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
        }
        if let Ok(meta) = std::fs::symlink_metadata(link) {
            if meta.file_type().is_symlink() {
                std::fs::remove_file(link).map_err(|e| e.to_string())?;
            } else {
                return Err(format!(
                    "{} is a file, not Rota's link; move it away first.",
                    link.display()
                ));
            }
        }
        std::os::unix::fs::symlink(helper, link).map_err(|e| e.to_string())
    }

    pub fn add_arguments(harness: Harness, command: &str) -> Vec<String> {
        match harness {
            Harness::Claude => vec![
                "mcp".into(),
                "add".into(),
                "-s".into(),
                "user".into(),
                Self::SERVER_NAME.into(),
                "--".into(),
                command.into(),
                "mcp".into(),
            ],
            Harness::Codex => vec![
                "mcp".into(),
                "add".into(),
                Self::SERVER_NAME.into(),
                "--".into(),
                command.into(),
                "mcp".into(),
            ],
            Harness::Grok => vec![
                "mcp".into(),
                "add".into(),
                "-s".into(),
                "user".into(),
                Self::SERVER_NAME.into(),
                command.into(),
                "--".into(),
                "mcp".into(),
            ],
            Harness::Antigravity => vec![
                "mcp".into(),
                "add".into(),
                Self::SERVER_NAME.into(),
                command.into(),
                "mcp".into(),
            ],
            Harness::Shell => Vec::new(),
        }
    }

    pub fn remove_arguments(harness: Harness) -> Vec<String> {
        match harness {
            Harness::Claude | Harness::Grok => vec![
                "mcp".into(),
                "remove".into(),
                "-s".into(),
                "user".into(),
                Self::SERVER_NAME.into(),
            ],
            Harness::Codex | Harness::Antigravity => {
                vec!["mcp".into(), "remove".into(), Self::SERVER_NAME.into()]
            }
            Harness::Shell => Vec::new(),
        }
    }

    pub fn is_added(harness: Harness, executable: &str) -> bool {
        let tmp = std::env::temp_dir();
        let empty = HashMap::new();
        match harness {
            Harness::Claude | Harness::Codex => {
                let args = vec!["mcp".into(), "get".into(), Self::SERVER_NAME.into()];
                ProcessLauncher::capture(
                    executable,
                    &args,
                    &tmp,
                    Some(Duration::from_secs(20)),
                    true,
                    true,
                    &empty,
                )
                .0 == 0
            }
            Harness::Grok => {
                let args = vec!["mcp".into(), "list".into(), "--json".into()];
                let (st, out) = ProcessLauncher::capture(
                    executable,
                    &args,
                    &tmp,
                    Some(Duration::from_secs(20)),
                    false,
                    true,
                    &empty,
                );
                st == 0 && Self::lists(Self::SERVER_NAME, &out)
            }
            Harness::Antigravity => {
                let args = vec!["mcp".into(), "list".into()];
                let (st, out) = ProcessLauncher::capture(
                    executable,
                    &args,
                    &tmp,
                    Some(Duration::from_secs(20)),
                    false,
                    true,
                    &empty,
                );
                st == 0 && Self::antigravity_lists(Self::SERVER_NAME, &out)
            }
            Harness::Shell => false,
        }
    }

    pub fn antigravity_lists(name: &str, text: &str) -> bool {
        text.lines().any(|line| {
            let fields: Vec<&str> = line.split_whitespace().collect();
            fields.len() >= 3 && fields[0] == name && fields[2] == "enabled"
        })
    }

    pub fn lists(name: &str, json_text: &str) -> bool {
        let Ok(val) = serde_json::from_str::<Value>(json_text) else {
            return false;
        };
        fn search(v: &Value, target: &str) -> bool {
            match v {
                Value::Object(map) => {
                    map.contains_key(target)
                        || map.get("name").and_then(Value::as_str) == Some(target)
                        || map.values().any(|child| search(child, target))
                }
                Value::Array(arr) => arr.iter().any(|child| search(child, target)),
                _ => false,
            }
        }
        search(&val, name)
    }

    pub fn change(harness: Harness, add: bool, executable: &str, command: &str) -> Option<String> {
        let args = if add {
            Self::add_arguments(harness, command)
        } else {
            Self::remove_arguments(harness)
        };
        let (st, out) = ProcessLauncher::capture(
            executable,
            &args,
            &std::env::temp_dir(),
            Some(Duration::from_secs(30)),
            true,
            true,
            &HashMap::new(),
        );
        (st != 0).then(|| out.trim().to_string())
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct ClaudeUserSettings {
    pub chrome_by_default: bool,
    pub trusted_projects: HashSet<String>,
}

impl ClaudeUserSettings {
    pub fn standard_file() -> PathBuf {
        home_dir().join(".claude.json")
    }

    pub fn read() -> Self {
        Self::read_from(&Self::standard_file())
    }

    pub fn read_from(file: &Path) -> Self {
        let Ok(bytes) = std::fs::read(file) else {
            return Self::default();
        };
        let Ok(json) = serde_json::from_slice::<Value>(&bytes) else {
            return Self::default();
        };
        let chrome_by_default = json
            .get("claudeInChromeDefaultEnabled")
            .and_then(Value::as_bool)
            .unwrap_or(false);
        let mut trusted_projects = HashSet::new();
        if let Some(projects) = json.get("projects").and_then(Value::as_object) {
            for (k, v) in projects {
                if v.get("hasTrustDialogAccepted").and_then(Value::as_bool) == Some(true) {
                    trusted_projects.insert(k.clone());
                }
            }
        }
        Self {
            chrome_by_default,
            trusted_projects,
        }
    }

    pub fn trusts(&self, directory: &str) -> bool {
        let resolved = resolve_symlinks_best_effort(Path::new(directory));
        let resolved_str = resolved.to_string_lossy();
        if self.trusted_projects.contains(resolved_str.as_ref()) || self.trusted_projects.contains(directory)
        {
            return true;
        }
        let mut cursor = resolved.as_path();
        while let Some(parent) = cursor.parent() {
            if cursor.join(".git").exists() {
                return self.trusted_projects.contains(cursor.to_string_lossy().as_ref());
            }
            if parent == cursor {
                break;
            }
            cursor = parent;
        }
        false
    }
}

pub struct ClaudeRunSettings;

impl ClaudeRunSettings {
    pub const DIALOG_NOTIFICATIONS: &'static str =
        "permission_prompt|elicitation_dialog|elicitation_url_dialog|agent_needs_input";

    pub fn hooks(folder: &Path) -> Result<PathBuf, String> {
        let dialog_cmd =
            r#"if [ -n "$ROTA_SESSION_DIALOG" ]; then { cat; echo; } >> "$ROTA_SESSION_DIALOG"; fi"#;
        let effort_cmd = r#"if [ -n "$CLAUDE_EFFORT" ] && [ -n "$ROTA_SESSION_EFFORT" ]; then printf '%s' "$CLAUDE_EFFORT" > "$ROTA_SESSION_EFFORT"; fi"#;
        let effort_hook = json!({"hooks": [{"type": "command", "command": effort_cmd}]});
        let question_hook = json!([{
            "type": "command",
            "command": r#"[ -n "$ROTA_CLI" ] && "$ROTA_CLI" question-hook || exit 2"#,
            "timeout": 604800
        }]);
        let settings = json!({
            "hooks": {
                "Notification": [{
                    "matcher": Self::DIALOG_NOTIFICATIONS,
                    "hooks": [{"type": "command", "command": dialog_cmd}]
                }],
                "PreToolUse": [
                    effort_hook,
                    {"matcher": "AskUserQuestion|ExitPlanMode", "hooks": question_hook}
                ],
                "PermissionRequest": [{"hooks": question_hook}],
                "Elicitation": [{"hooks": question_hook}],
                "Stop": [effort_hook]
            }
        });
        let file = folder.join(format!("claude-settings-{}.json", Uuid::new_v4()));
        let bytes = to_sorted_pretty_vec(&settings).map_err(|e| e.to_string())?;
        atomic_write_bytes(&file, &bytes)?;
        Ok(file)
    }
}
