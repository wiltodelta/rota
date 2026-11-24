use std::collections::HashMap;
use std::fmt;
use std::path::{Path, PathBuf};

use base64::Engine;
use jiff::Timestamp;
use rota_platform::{OwnedProcess, inspect_image_bytes};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::model::ChatAttachment;
use crate::model::serde_ext::{opt_iso_timestamp, uppercase_uuid};
use crate::storage::{
    atomic_write_bytes, atomic_write_json, normalize_lexical_path, resolve_symlinks_best_effort,
};
use crate::transcript::{MarkdownImageReference, ToolOutput};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AttachmentError {
    NotAFile,
    UnsafeFolder,
    Io(String),
}

impl fmt::Display for AttachmentError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::NotAFile => f.write_str("Choose regular files, not folders or web links."),
            Self::UnsafeFolder => f.write_str("The attachment folder is not owned by this session."),
            Self::Io(msg) => f.write_str(msg),
        }
    }
}

impl std::error::Error for AttachmentError {}

#[derive(Debug, Clone)]
pub struct ChatAttachmentStore {
    pub folder: PathBuf,
}

impl ChatAttachmentStore {
    pub fn new(log: &Path) -> Self {
        Self {
            folder: Self::folder_for(log),
        }
    }

    pub fn folder_for(log: &Path) -> PathBuf {
        let mut s = log.as_os_str().to_os_string();
        s.push(".attachments");
        PathBuf::from(s)
    }

    fn validate_folder(&self) -> Result<(), AttachmentError> {
        if let Ok(meta) = std::fs::symlink_metadata(&self.folder)
            && meta.file_type().is_symlink()
        {
            return Err(AttachmentError::UnsafeFolder);
        }
        let resolved_folder_parent = resolve_symlinks_best_effort(&self.folder)
            .parent()
            .map(Path::to_path_buf);
        let parent_resolved = self.folder.parent().map(resolve_symlinks_best_effort);
        if resolved_folder_parent != parent_resolved {
            return Err(AttachmentError::UnsafeFolder);
        }
        Ok(())
    }

    pub fn stage(&self, paths: &[PathBuf]) -> Result<Vec<ChatAttachment>, AttachmentError> {
        self.validate_folder()?;
        let mut created_dirs = Vec::new();
        let mut out = Vec::with_capacity(paths.len());
        let res = (|| -> Result<(), AttachmentError> {
            for source in paths {
                let meta = std::fs::metadata(source).map_err(|_| AttachmentError::NotAFile)?;
                if !meta.is_file() {
                    return Err(AttachmentError::NotAFile);
                }
                let file_name = source
                    .file_name()
                    .and_then(|n| n.to_str())
                    .filter(|s| !s.is_empty())
                    .ok_or(AttachmentError::NotAFile)?;
                let dir = self.folder.join(uppercase_uuid(Uuid::new_v4()));
                std::fs::create_dir_all(&dir).map_err(|e| AttachmentError::Io(e.to_string()))?;
                created_dirs.push(dir.clone());
                let target = dir.join(file_name);
                std::fs::copy(source, &target).map_err(|e| AttachmentError::Io(e.to_string()))?;
                out.push(ChatAttachment::new(
                    file_name,
                    target.to_string_lossy().into_owned(),
                ));
            }
            Ok(())
        })();
        if let Err(err) = res {
            for dir in created_dirs {
                let _ = std::fs::remove_dir_all(dir);
            }
            return Err(err);
        }
        Ok(out)
    }

    pub fn stage_bytes(&self, bytes: &[u8], name: &str) -> Result<ChatAttachment, AttachmentError> {
        self.validate_folder()?;
        let dir = self.folder.join(uppercase_uuid(Uuid::new_v4()));
        std::fs::create_dir_all(&dir).map_err(|e| AttachmentError::Io(e.to_string()))?;
        let target = dir.join(name);
        if let Err(err) = atomic_write_bytes(&target, bytes) {
            let _ = std::fs::remove_dir_all(&dir);
            return Err(AttachmentError::Io(err));
        }
        Ok(ChatAttachment::new(name, target.to_string_lossy().into_owned()))
    }

    pub fn discard(&self, attachment: &ChatAttachment) -> Result<(), AttachmentError> {
        let file_path = Path::new(&attachment.path);
        let dir = file_path.parent().ok_or(AttachmentError::UnsafeFolder)?;
        let dir_name = dir
            .file_name()
            .and_then(|n| n.to_str())
            .ok_or(AttachmentError::UnsafeFolder)?;
        if Uuid::parse_str(dir_name).is_err() {
            return Err(AttachmentError::UnsafeFolder);
        }
        let dir_parent = dir.parent().ok_or(AttachmentError::UnsafeFolder)?;
        if normalize_lexical_path(dir_parent) != normalize_lexical_path(&self.folder) {
            return Err(AttachmentError::UnsafeFolder);
        }
        if resolve_symlinks_best_effort(dir).parent()
            != Some(resolve_symlinks_best_effort(&self.folder).as_path())
        {
            return Err(AttachmentError::UnsafeFolder);
        }
        std::fs::remove_dir_all(dir).map_err(|e| AttachmentError::Io(e.to_string()))
    }
}

#[derive(Debug, Clone)]
pub struct SessionImageStore {
    attachments: ChatAttachmentStore,
    working_directory: Option<PathBuf>,
}

impl SessionImageStore {
    pub fn new(log: &Path, working_directory: Option<PathBuf>) -> Self {
        Self {
            attachments: ChatAttachmentStore::new(log),
            working_directory,
        }
    }

    fn index_path(&self) -> PathBuf {
        self.attachments.folder.join("images.json")
    }

    fn index(&self) -> HashMap<String, ChatAttachment> {
        std::fs::read(self.index_path())
            .ok()
            .and_then(|b| serde_json::from_slice(&b).ok())
            .unwrap_or_default()
    }

    fn key(url: &str, item_id: Option<usize>) -> String {
        match item_id {
            Some(id) => format!("{id}|{url}"),
            None => url.to_string(),
        }
    }

    pub fn archived(&self, url: &str, item_id: Option<usize>) -> Option<PathBuf> {
        let saved = self.index();
        let file = saved.get(&Self::key(url, item_id))?;
        let resolved_file = resolve_symlinks_best_effort(Path::new(&file.path));
        let resolved_folder = resolve_symlinks_best_effort(&self.attachments.folder);
        if !resolved_file.starts_with(&resolved_folder) || !Path::new(&file.path).exists() {
            return None;
        }
        Some(PathBuf::from(&file.path))
    }

    fn resolve_local_source(&self, url: &str) -> Option<PathBuf> {
        if let Some(rest) = url.strip_prefix("file://") {
            let path = rest.strip_prefix("localhost").unwrap_or(rest);
            return Some(PathBuf::from(percent_decode(path)));
        }
        if url.contains("://") || url.starts_with("data:") {
            return None;
        }
        let decoded = percent_decode(url);
        if decoded.starts_with('/') {
            Some(PathBuf::from(decoded))
        } else {
            self.working_directory.as_ref().map(|wd| wd.join(decoded))
        }
    }

    pub fn preserve_output(&self, text: &str, item_id: Option<usize>) -> Result<String, AttachmentError> {
        let Some(mut output) = ToolOutput::decode(text) else {
            return Ok(text.to_string());
        };
        let mut refs = Vec::new();
        for part in &mut output.parts {
            if part.kind != crate::transcript::ToolOutputKind::Image {
                continue;
            }
            if part.text.starts_with("data:image/")
                && let Some((head, b64)) = part.text.split_once(',')
                && head.ends_with(";base64")
                && let Ok(bytes) = base64::engine::general_purpose::STANDARD.decode(b64)
            {
                let ext = inspect_image_bytes(&bytes).map(|i| i.extension);
                let name = match ext {
                    Some(e) => format!("tool-image.{e}"),
                    None => "tool-image".to_string(),
                };
                let staged = self.attachments.stage_bytes(&bytes, &name)?;
                part.text = format!("file://{}", staged.path);
            } else {
                refs.push(MarkdownImageReference {
                    url: part.text.clone(),
                    alt: part.path.clone().unwrap_or_else(|| "Tool image".to_string()),
                });
            }
        }
        self.capture(&refs, item_id)?;
        Ok(output.encoded())
    }

    pub fn capture(
        &self,
        references: &[MarkdownImageReference],
        item_id: Option<usize>,
    ) -> Result<(), AttachmentError> {
        if references.is_empty() {
            return Ok(());
        }
        let mut saved = self.index();
        let mut created = Vec::new();
        let res = (|| -> Result<(), AttachmentError> {
            for r in references {
                let id_key = Self::key(&r.url, item_id);
                if let Some(existing) = saved.get(&id_key)
                    && Path::new(&existing.path).exists()
                {
                    continue;
                }
                let Some(source) = self.resolve_local_source(&r.url) else {
                    continue;
                };
                if !source.is_file() {
                    continue;
                }
                if let Some(staged) = self.attachments.stage(&[source])?.into_iter().next() {
                    saved.insert(id_key, staged.clone());
                    created.push(staged);
                }
            }
            if !created.is_empty() {
                atomic_write_json(&self.index_path(), &saved).map_err(AttachmentError::Io)?;
            }
            Ok(())
        })();
        if let Err(err) = res {
            for f in created {
                let _ = self.attachments.discard(&f);
            }
            return Err(err);
        }
        Ok(())
    }
}

pub(crate) fn percent_decode(input: &str) -> String {
    let bytes = input.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%'
            && i + 2 < bytes.len()
            && let Ok(hex) = std::str::from_utf8(&bytes[i + 1..i + 3])
            && let Ok(val) = u8::from_str_radix(hex, 16)
        {
            out.push(val);
            i += 3;
            continue;
        }
        out.push(bytes[i]);
        i += 1;
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// Durable ownership of a local CLI (`<log>.runtime.json`).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RunLease {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub process: Option<OwnedProcess>,
    pub id: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub screen_name: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub native_offset: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none", with = "opt_iso_timestamp")]
    pub native_since: Option<Timestamp>,
}

impl RunLease {
    pub fn path(log: &Path) -> PathBuf {
        let mut s = log.as_os_str().to_os_string();
        s.push(".runtime.json");
        PathBuf::from(s)
    }

    pub fn read(log: &Path) -> Option<Self> {
        let bytes = std::fs::read(Self::path(log)).ok()?;
        serde_json::from_slice(&bytes).ok()
    }

    pub fn write(&self, log: &Path) -> Result<(), String> {
        atomic_write_json(&Self::path(log), self)
    }

    pub fn save_pid(pid: i32, log: &Path, id: impl Into<String>) -> Result<Self, String> {
        let lease = Self {
            process: OwnedProcess::capture(pid),
            id: id.into(),
            screen_name: None,
            native_offset: None,
            native_since: None,
        };
        lease.write(log)?;
        Ok(lease)
    }
}
