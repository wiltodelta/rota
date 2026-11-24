pub mod attachments;
pub mod history;

use std::fmt;
use std::io::Write;
use std::path::{Component, Path, PathBuf};

use rota_platform::{app_bundle_identifier, expand_tilde, home_dir};
use serde::Serialize;
use serde::de::DeserializeOwned;
use uuid::Uuid;

use crate::model::Routine;
use crate::model::serde_ext::to_sorted_pretty_vec;

pub use attachments::{AttachmentError, ChatAttachmentStore, RunLease, SessionImageStore};
pub use history::RunHistory;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StorageLocation {
    pub root: PathBuf,
    pub logs: PathBuf,
}

impl StorageLocation {
    pub fn new(root: impl Into<PathBuf>, logs: impl Into<PathBuf>) -> Self {
        Self {
            root: root.into(),
            logs: logs.into(),
        }
    }

    pub fn standard() -> Self {
        if let Ok(dir) = std::env::var("ROTA_DATA_DIR")
            && !dir.is_empty()
        {
            let root = PathBuf::from(expand_tilde(&dir));
            let logs = root.join("Logs");
            return Self { root, logs };
        }
        let home = home_dir();
        let is_dev = app_bundle_identifier().is_some_and(|id| id.ends_with(".dev"));
        let name = if is_dev { "Rota Dev" } else { "Rota" };
        Self {
            root: home.join("Library/Application Support").join(name),
            logs: home.join("Library/Logs").join(name),
        }
    }

    pub fn routines_file(&self) -> PathBuf {
        self.root.join("routines.json")
    }

    pub fn history_directory(&self) -> PathBuf {
        self.root.join("runs")
    }

    pub fn socket_path(&self) -> PathBuf {
        self.root.join("rota.sock")
    }
}

#[derive(Debug, Clone)]
pub struct RoutineStore {
    location: StorageLocation,
}

impl RoutineStore {
    pub fn new(location: StorageLocation) -> Self {
        Self { location }
    }

    pub fn location(&self) -> &StorageLocation {
        &self.location
    }

    pub fn load(&self) -> Result<Vec<Routine>, String> {
        read_json_file::<Vec<Routine>>(&self.location.routines_file()).map(Option::unwrap_or_default)
    }

    pub fn save(&self, routines: &[Routine]) -> Result<(), String> {
        atomic_write_json(&self.location.routines_file(), &routines)
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum HistoryDeletionError {
    Running,
    ForeignLog,
    Io(String),
}

impl fmt::Display for HistoryDeletionError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::Running => f.write_str("Stop the session before deleting it."),
            Self::ForeignLog => f.write_str("The session log is outside Rota's log folder."),
            Self::Io(msg) => f.write_str(msg),
        }
    }
}

impl std::error::Error for HistoryDeletionError {}

pub fn read_json_file<T: DeserializeOwned>(path: &Path) -> Result<Option<T>, String> {
    if !path.exists() {
        return Ok(None);
    }
    let bytes = std::fs::read(path).map_err(|e| e.to_string())?;
    let parsed = serde_json::from_slice::<T>(&bytes).map_err(|e| e.to_string())?;
    Ok(Some(parsed))
}

pub fn atomic_write_json<T: Serialize>(path: &Path, value: &T) -> Result<(), String> {
    let bytes = to_sorted_pretty_vec(value).map_err(|e| e.to_string())?;
    atomic_write_bytes(path, &bytes)
}

pub fn atomic_write_bytes(path: &Path, bytes: &[u8]) -> Result<(), String> {
    let parent = path
        .parent()
        .ok_or_else(|| "Missing parent directory".to_string())?;
    std::fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    if path.is_dir() {
        return Err(format!("{} is a directory", path.display()));
    }
    let tmp = parent.join(format!(
        ".{}.tmp-{}",
        path.file_name().and_then(|n| n.to_str()).unwrap_or("rota"),
        Uuid::new_v4()
    ));
    let res = (|| -> std::io::Result<()> {
        let mut file = std::fs::File::create(&tmp)?;
        file.write_all(bytes)?;
        file.sync_all()?;
        drop(file);
        std::fs::rename(&tmp, path)?;
        Ok(())
    })();
    if let Err(err) = res {
        let _ = std::fs::remove_file(&tmp);
        return Err(err.to_string());
    }
    Ok(())
}

/// Resolves `.` and `..` lexically without touching the filesystem.
pub(crate) fn normalize_lexical_path(path: &Path) -> PathBuf {
    let mut out = PathBuf::new();
    for comp in path.components() {
        match comp {
            Component::CurDir => {}
            Component::ParentDir => {
                out.pop();
            }
            other => out.push(other.as_os_str()),
        }
    }
    out
}

/// Resolves symlinks on existing prefixes while keeping missing trailing components intact.
pub(crate) fn resolve_symlinks_best_effort(path: &Path) -> PathBuf {
    let normalized = normalize_lexical_path(path);
    if let Ok(canon) = std::fs::canonicalize(&normalized) {
        return canon;
    }
    let mut tail = Vec::new();
    let mut cursor = normalized.as_path();
    while let Some(name) = cursor.file_name() {
        tail.push(name.to_os_string());
        let Some(parent) = cursor.parent() else {
            break;
        };
        if let Ok(canon_parent) = std::fs::canonicalize(parent) {
            let mut rebuilt = canon_parent;
            for part in tail.into_iter().rev() {
                rebuilt.push(part);
            }
            return rebuilt;
        }
        cursor = parent;
    }
    normalized
}
