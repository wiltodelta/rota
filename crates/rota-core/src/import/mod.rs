use std::path::{Path, PathBuf};
use std::time::SystemTime;

use jiff::Timestamp;
use jiff::tz::TimeZone;
use rota_platform::{ReadOnlySqlite, SqlValue, home_dir};
use serde::Deserialize;

use crate::model::{Harness, Routine};
use crate::schedule::ScheduleText;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ImportSource {
    ClaudeDesktop,
    Codex,
}

impl ImportSource {
    pub const ALL: [Self; 2] = [Self::ClaudeDesktop, Self::Codex];

    pub fn as_str(self) -> &'static str {
        match self {
            Self::ClaudeDesktop => "claudeDesktop",
            Self::Codex => "codex",
        }
    }

    pub fn title(self) -> &'static str {
        match self {
            Self::ClaudeDesktop => "Claude Desktop",
            Self::Codex => "Codex",
        }
    }

    pub fn harness(self) -> Harness {
        match self {
            Self::ClaudeDesktop => Harness::Claude,
            Self::Codex => Harness::Codex,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ImportCandidate {
    pub routine: Routine,
    pub source: ImportSource,
    pub on_in_source: bool,
    pub unsupported: Option<String>,
}

impl ImportCandidate {
    pub fn new(
        mut routine: Routine,
        source: ImportSource,
        on_in_source: bool,
        unsupported: Option<String>,
        source_id: Option<&str>,
    ) -> Self {
        if let Some(sid) = source_id {
            routine.import_identity = Some(format!("{}:{sid}", source.as_str()));
        }
        Self {
            routine,
            source,
            on_in_source,
            unsupported,
        }
    }

    pub fn id(&self) -> String {
        self.routine
            .import_identity
            .clone()
            .unwrap_or_else(|| format!("{}:{}", self.source.as_str(), self.routine.id))
    }
}

#[derive(Debug, Clone)]
pub struct ImportScan {
    pub source: ImportSource,
    pub candidates: Vec<ImportCandidate>,
    pub problem: Option<String>,
}

pub struct RoutineImport;

impl RoutineImport {
    pub fn scan_all() -> Vec<ImportScan> {
        Self::scan_all_in(&home_dir())
    }

    pub fn scan_all_in(home: &Path) -> Vec<ImportScan> {
        ImportSource::ALL
            .into_iter()
            .map(|source| match source {
                ImportSource::ClaudeDesktop => {
                    let Some(file) = ClaudeDesktopImport::locate(home) else {
                        return ImportScan {
                            source,
                            candidates: Vec::new(),
                            problem: Some("No scheduled tasks found.".to_string()),
                        };
                    };
                    match ClaudeDesktopImport::candidates(&file) {
                        Ok(candidates) => ImportScan {
                            source,
                            candidates,
                            problem: None,
                        },
                        Err(err) => ImportScan {
                            source,
                            candidates: Vec::new(),
                            problem: Some(err),
                        },
                    }
                }
                ImportSource::Codex => {
                    let dbs = CodexAutomationsImport::locate(home);
                    if dbs.is_empty() {
                        return ImportScan {
                            source,
                            candidates: Vec::new(),
                            problem: Some("No automations found.".to_string()),
                        };
                    }
                    let mut all = Vec::new();
                    for db in dbs {
                        match CodexAutomationsImport::candidates(&db) {
                            Ok(list) => all.extend(list),
                            Err(err) => {
                                return ImportScan {
                                    source,
                                    candidates: Vec::new(),
                                    problem: Some(err),
                                };
                            }
                        }
                    }
                    ImportScan {
                        source,
                        candidates: all,
                        problem: None,
                    }
                }
            })
            .collect()
    }

    pub fn is_imported(candidate: &ImportCandidate, routines: &[Routine]) -> bool {
        routines.iter().any(|r| {
            if let Some(identity) = &r.import_identity {
                Some(identity) == candidate.routine.import_identity.as_ref()
            } else {
                r.id == candidate.routine.id
                    && r.working_directory == candidate.routine.working_directory
                    && r.prompt == candidate.routine.prompt
            }
        })
    }

    pub fn routine_to_import(candidate: &ImportCandidate, existing: &[Routine]) -> Option<Routine> {
        if candidate.unsupported.is_some() || Self::is_imported(candidate, existing) {
            return None;
        }
        let mut routine = candidate.routine.clone();
        let base = routine.id.clone();
        let mut suffix = 2usize;
        while existing.iter().any(|r| r.id == routine.id) {
            routine.id = format!("{base}-{suffix}");
            suffix += 1;
        }
        routine.enabled = false;
        Some(routine)
    }

    pub fn identifier_from_name(name: &str) -> String {
        name.to_lowercase()
            .split(|c: char| !c.is_alphanumeric())
            .filter(|w| !w.is_empty())
            .collect::<Vec<_>>()
            .join("-")
    }
}

pub struct ClaudeDesktopImport;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ClaudeRegistration {
    id: String,
    display_name: Option<String>,
    cron_expression: Option<String>,
    enabled: Option<bool>,
    file_path: Option<String>,
    cwd: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ClaudeTasksFile {
    scheduled_tasks: Vec<ClaudeRegistration>,
}

impl ClaudeDesktopImport {
    pub fn locate(home: &Path) -> Option<PathBuf> {
        let root = home.join("Library/Application Support/Claude/claude-code-sessions");
        let mut newest: Option<(PathBuf, SystemTime)> = None;
        Self::walk_scheduled_tasks(&root, &mut newest);
        newest.map(|(p, _)| p)
    }

    fn walk_scheduled_tasks(dir: &Path, newest: &mut Option<(PathBuf, SystemTime)>) {
        let Ok(entries) = std::fs::read_dir(dir) else {
            return;
        };
        for entry in entries.flatten() {
            let path = entry.path();
            if path.is_dir() {
                Self::walk_scheduled_tasks(&path, newest);
            } else if path.file_name().and_then(|n| n.to_str()) == Some("scheduled-tasks.json") {
                let mtime = entry
                    .metadata()
                    .and_then(|m| m.modified())
                    .unwrap_or(SystemTime::UNIX_EPOCH);
                if newest.as_ref().is_none_or(|(_, best)| mtime > *best) {
                    *newest = Some((path, mtime));
                }
            }
        }
    }

    pub fn candidates(file: &Path) -> Result<Vec<ImportCandidate>, String> {
        let bytes = std::fs::read(file).map_err(|e| e.to_string())?;
        let parsed: ClaudeTasksFile = serde_json::from_slice(&bytes).map_err(|e| e.to_string())?;
        let mut out = Vec::new();
        for reg in parsed.scheduled_tasks {
            let (Some(cron), Some(cwd)) = (reg.cron_expression, reg.cwd) else {
                continue;
            };
            let prompt = reg
                .file_path
                .as_deref()
                .and_then(Self::stub_prompt)
                .unwrap_or_else(|| Routine::default_prompt(&reg.id, &cwd));
            let name = reg.display_name.unwrap_or_else(|| reg.id.clone());
            let routine = Routine::new(reg.id.clone(), name, cwd, cron, Harness::Claude, false, prompt);
            out.push(ImportCandidate::new(
                routine,
                ImportSource::ClaudeDesktop,
                reg.enabled.unwrap_or(false),
                None,
                Some(&reg.id),
            ));
        }
        Ok(out)
    }

    pub fn stub_prompt(path: &str) -> Option<String> {
        let text = std::fs::read_to_string(path).ok()?;
        Self::strip_frontmatter(&text)
    }

    pub fn strip_frontmatter(text: &str) -> Option<String> {
        let mut body = text;
        if let Some(after_open) = body.strip_prefix("---\n")
            && let Some(pos) = after_open.find("\n---")
        {
            body = &after_open[pos + 4..];
        }
        let trimmed = body.trim();
        (!trimmed.is_empty()).then(|| trimmed.to_string())
    }
}

pub struct CodexAutomationsImport;

impl CodexAutomationsImport {
    pub fn locate(home: &Path) -> Vec<PathBuf> {
        let folder = home.join(".codex/sqlite");
        let Ok(entries) = std::fs::read_dir(folder) else {
            return Vec::new();
        };
        let mut files: Vec<PathBuf> = entries
            .flatten()
            .map(|e| e.path())
            .filter(|p| p.extension().and_then(|e| e.to_str()) == Some("db"))
            .collect();
        files.sort();
        files
    }

    pub fn candidates(database: &Path) -> Result<Vec<ImportCandidate>, String> {
        Self::candidates_in_tz(database, &TimeZone::system())
    }

    pub fn candidates_in_tz(database: &Path, tz: &TimeZone) -> Result<Vec<ImportCandidate>, String> {
        let db = ReadOnlySqlite::open(database).map_err(|_| {
            format!(
                "Could not open {}.",
                database
                    .file_name()
                    .and_then(|n| n.to_str())
                    .unwrap_or("database")
            )
        })?;
        let query = "SELECT id, name, prompt, status, next_run_at, cwds, rrule, model, reasoning_effort, target_thread_id FROM automations ORDER BY name";
        let Ok(rows) = db.query(query) else {
            // A Codex SQLite store without an `automations` table simply has nothing to import.
            return Ok(Vec::new());
        };
        Ok(rows.into_iter().map(|r| Self::row_to_candidate(&r, tz)).collect())
    }

    fn row_to_candidate(row: &[SqlValue], tz: &TimeZone) -> ImportCandidate {
        let col_str = |i: usize| row.get(i).and_then(SqlValue::as_str).map(ToOwned::to_owned);
        let id = col_str(0).unwrap_or_default();
        let name = col_str(1).unwrap_or_default();
        let prompt = col_str(2).unwrap_or_default();
        let status = col_str(3).unwrap_or_default();
        let next_run = row.get(4).and_then(SqlValue::as_i64);
        let cwds_raw = col_str(5).unwrap_or_else(|| "[]".to_string());
        let rrule = col_str(6).unwrap_or_default();
        let model = col_str(7);
        let effort = col_str(8);
        let target_thread = col_str(9);

        let folders: Vec<String> = serde_json::from_str(&cwds_raw).unwrap_or_default();
        let anchor = next_run.and_then(|raw| {
            let secs = if raw > 1_000_000_000_000 { raw / 1000 } else { raw };
            Timestamp::from_second(secs).ok()
        });
        let cron = ScheduleText::cron_from_rrule(&rrule, anchor, tz);
        let local_id = RoutineImport::identifier_from_name(&name);
        let mut routine = Routine::new(
            if local_id.is_empty() { id.clone() } else { local_id },
            name,
            folders.first().cloned().unwrap_or_default(),
            cron.clone().unwrap_or_default(),
            Harness::Codex,
            false,
            prompt,
        );
        routine.model = model;
        routine.effort = effort;

        let unsupported = if target_thread.is_some() {
            Some("Continues a Codex thread, which a routine cannot.".to_string())
        } else if folders.is_empty() {
            Some("Has no project folder.".to_string())
        } else if folders.len() > 1 {
            Some("Uses multiple project folders. Create a separate Rota routine for each folder.".to_string())
        } else if cron.is_none() {
            Some(format!("Its schedule ({rrule}) has no cron equivalent."))
        } else {
            None
        };

        ImportCandidate::new(
            routine,
            ImportSource::Codex,
            status == "ACTIVE",
            unsupported,
            Some(&id),
        )
    }
}
