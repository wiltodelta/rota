use std::collections::HashSet;
use std::fs::File;
use std::io::{Read, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use rota_platform::Logger;
use serde_json::{Value, json};

use crate::control::{ControlClient, ControlServer};
use crate::model::{QuestionAnswer, QuestionRequest};
use crate::runners::claude_interactive::{ClaudeToolCall, ClaudeTranscript};
use crate::runners::{ClaudeDialog, ClaudeDialogEvent, ScreenRun};
use crate::transcript::{RunJournal, TranscriptItemKind};

struct ShownDialog {
    question_id: String,
    dialog: Option<ClaudeDialog>,
    title: String,
}

struct BridgeState {
    offset: u64,
    hook_questions: HashSet<i32>,
    notified_during_hook: bool,
    shown: Option<ShownDialog>,
    polls: usize,
    pending_tools: Vec<ClaudeToolCall>,
}

type ReadScreenFn = Arc<dyn Fn() -> Option<ClaudeDialog> + Send + Sync>;
type TypeKeyFn = Arc<dyn Fn(&str) + Send + Sync>;

pub struct ClaudeDialogBridge {
    pub file: PathBuf,
    screen_file: PathBuf,
    screen: String,
    session: String,
    journal: Arc<RunJournal>,
    read_screen: Option<ReadScreenFn>,
    type_key: Option<TypeKeyFn>,
    state: Mutex<BridgeState>,
}

impl ClaudeDialogBridge {
    const LOG: Logger = Logger::new("claude");

    pub fn new(screen: &str, session: &str, folder: &Path, journal: Arc<RunJournal>) -> Arc<Self> {
        Arc::new(Self {
            file: folder.join(format!("{screen}.dialog")),
            screen_file: folder.join(format!("{screen}.screen")),
            screen: screen.to_string(),
            session: session.to_string(),
            journal,
            read_screen: None,
            type_key: None,
            state: Mutex::new(BridgeState {
                offset: 0,
                hook_questions: HashSet::new(),
                notified_during_hook: false,
                shown: None,
                polls: 0,
                pending_tools: Vec::new(),
            }),
        })
    }

    pub fn clean_up(&self) {
        let _ = std::fs::remove_file(&self.file);
        let _ = std::fs::remove_file(&self.screen_file);
    }

    pub fn track(&self, entry: &Value, moves_on: bool) {
        let (started, ended) = ClaudeTranscript::tool_calls(entry);
        let close_qid = {
            let mut g = self.state.lock().unwrap();
            g.pending_tools.retain(|t| !ended.contains(&t.id));
            g.pending_tools.extend(started);
            if g.pending_tools.len() > 8 {
                let drop_n = g.pending_tools.len() - 8;
                g.pending_tools.drain(..drop_n);
            }
            if (moves_on || !ended.is_empty())
                && let Some(shown) = &g.shown
                && shown.dialog.is_none()
            {
                let id = shown.question_id.clone();
                g.shown = None;
                Some(id)
            } else {
                None
            }
        };
        if let Some(id) = close_qid {
            self.journal.resolve_question(&id);
        }
    }

    pub fn adopt(self: &Arc<Self>) {
        let _ = self.read_events();
        let empty_hooks = self.state.lock().unwrap().hook_questions.is_empty();
        if empty_hooks && let Some(open) = self.read_dialog() {
            self.show(Some(open), ClaudeDialog::DEFAULT_TITLE);
        }
    }

    pub fn poll(self: &Arc<Self>) {
        let notified = {
            let mut g = self.state.lock().unwrap();
            g.polls += 1;
            drop(g);
            self.read_events()
        };
        let check_post_hook = {
            let mut g = self.state.lock().unwrap();
            if g.notified_during_hook && g.hook_questions.is_empty() {
                g.notified_during_hook = false;
                notified.is_none() && g.shown.is_none()
            } else {
                false
            }
        };
        if check_post_hook && let Some(open) = self.read_dialog() {
            self.show(Some(open), ClaudeDialog::DEFAULT_TITLE);
            return;
        }
        let Some(notified_title) = notified else {
            self.watch();
            return;
        };
        {
            let mut g = self.state.lock().unwrap();
            if !g.hook_questions.is_empty() {
                g.notified_during_hook = true;
                Self::LOG.info(&format!(
                    "claude {} dialog belongs to a pending question",
                    self.session
                ));
                return;
            }
        }
        let open = self.read_dialog();
        let prev_close = {
            let mut g = self.state.lock().unwrap();
            if let Some(shown) = &g.shown {
                if open.as_ref().map(|d| &d.options) == shown.dialog.as_ref().map(|d| &d.options)
                    && open.is_some()
                {
                    return;
                }
                let old_id = shown.question_id.clone();
                g.shown = None;
                Some(old_id)
            } else {
                None
            }
        };
        if let Some(old_id) = prev_close {
            self.journal.resolve_question(&old_id);
        }
        self.show(open, &notified_title);
    }

    fn read_events(&self) -> Option<String> {
        let offset = self.state.lock().unwrap().offset;
        let mut file = File::open(&self.file).ok()?;
        file.seek(SeekFrom::Start(offset)).ok()?;
        let mut data = Vec::new();
        file.read_to_end(&mut data).ok()?;
        let end = data.iter().rposition(|&b| b == b'\n')?;
        let text = String::from_utf8_lossy(&data[..=end]).into_owned();
        let mut g = self.state.lock().unwrap();
        g.offset = offset + (end as u64) + 1;
        let mut notified = None;
        for line in text.lines() {
            match ClaudeDialog::parse_event(line) {
                Some(ClaudeDialogEvent::Question { pid, open: true }) => {
                    g.hook_questions.insert(pid);
                }
                Some(ClaudeDialogEvent::Question { pid, open: false }) => {
                    g.hook_questions.remove(&pid);
                }
                Some(ClaudeDialogEvent::Shown { message }) => {
                    notified = Some(message.unwrap_or_else(|| ClaudeDialog::DEFAULT_TITLE.to_string()));
                }
                None => {}
            }
        }
        g.hook_questions.retain(|&pid| unsafe { libc::kill(pid, 0) == 0 });
        notified
    }

    fn show(self: &Arc<Self>, open: Option<ClaudeDialog>, title: &str) {
        let tool = self
            .state
            .lock()
            .unwrap()
            .pending_tools
            .last()
            .map(|t| format!("{}\n{}", t.name, QuestionRequest::json(&t.input)));
        let question = ClaudeDialog::question(open.as_ref(), title, tool);
        let qid = question.id.clone();
        self.state.lock().unwrap().shown = Some(ShownDialog {
            question_id: qid.clone(),
            dialog: open,
            title: title.to_string(),
        });
        let me = Arc::clone(self);
        self.journal.ask(question, true, move |answer| {
            me.answer(&answer, &qid);
        });
    }

    fn watch(self: &Arc<Self>) {
        let (qid, prev_opts, prev_title) = {
            let g = self.state.lock().unwrap();
            if !g.polls.is_multiple_of(2) {
                return;
            }
            let Some(shown) = &g.shown else {
                return;
            };
            (
                shown.question_id.clone(),
                shown.dialog.as_ref().map(|d| d.options.clone()),
                shown.title.clone(),
            )
        };
        let open = self.read_dialog();
        if let Some(opts) = prev_opts {
            if open.as_ref().map(|d| &d.options) != Some(&opts) {
                self.close_question(&qid);
            }
        } else if let Some(d) = open {
            self.close_question(&qid);
            self.show(Some(d), &prev_title);
        }
    }

    fn close_question(&self, qid: &str) {
        let mut g = self.state.lock().unwrap();
        if g.shown.as_ref().is_some_and(|s| s.question_id == qid) {
            g.shown = None;
            drop(g);
            self.journal.resolve_question(qid);
        }
    }

    fn answer(self: &Arc<Self>, answer: &QuestionAnswer, qid: &str) {
        if self.journal.is_finished() {
            return;
        }
        let current = {
            let mut g = self.state.lock().unwrap();
            if g.shown.as_ref().is_some_and(|s| s.question_id == qid) {
                g.shown.take()
            } else {
                None
            }
        };
        let Some(current) = current else {
            return;
        };
        let Some(dialog) = current.dialog else {
            if ClaudeDialog::cancels(&answer.action) {
                self.send_keys(ClaudeDialog::ESCAPE);
            }
            return;
        };
        let Some(live) = self.read_dialog() else {
            self.journal.record(
                TranscriptItemKind::Status,
                "Claude's dialog had already closed; Rota typed nothing",
            );
            return;
        };
        if live.options != dialog.options {
            self.journal.record(
                TranscriptItemKind::Status,
                "Claude's dialog had already closed; Rota typed nothing",
            );
            return;
        }
        let Some(key) = live.key(&answer.action) else {
            return;
        };
        self.send_keys(&key);
        if !ClaudeDialog::cancels(&answer.action) {
            let me = Arc::clone(self);
            let opts = live.options;
            let numbered = live.numbered;
            std::thread::spawn(move || {
                std::thread::sleep(Duration::from_millis(700));
                if me.read_dialog().as_ref().map(|d| &d.options) == Some(&opts) {
                    if numbered {
                        me.send_keys("\r");
                        std::thread::sleep(Duration::from_millis(700));
                        if me.read_dialog().as_ref().map(|d| &d.options) == Some(&opts) {
                            me.journal.record(
                                TranscriptItemKind::Status,
                                "Claude did not take the answer; answer it in Terminal",
                            );
                        }
                    } else {
                        me.journal.record(
                            TranscriptItemKind::Status,
                            "Claude did not take the answer; answer it in Terminal",
                        );
                    }
                }
            });
        }
    }

    fn send_keys(&self, keys: &str) {
        if let Some(cb) = &self.type_key {
            cb(keys);
        } else {
            ScreenRun::type_keys(&self.screen, keys);
        }
    }

    fn read_dialog(&self) -> Option<ClaudeDialog> {
        if let Some(cb) = &self.read_screen {
            cb()
        } else {
            ScreenRun::hardcopy(&self.screen, &self.screen_file)
                .and_then(|bytes| ClaudeDialog::read_screen(&bytes))
        }
    }
}

pub struct QuestionHook;

impl QuestionHook {
    pub fn run() -> Result<(), String> {
        let mut input = Vec::new();
        std::io::stdin()
            .read_to_end(&mut input)
            .map_err(|e| e.to_string())?;
        let Ok(event) = serde_json::from_slice::<Value>(&input) else {
            return Ok(());
        };
        let Some(request) = QuestionRequest::claude(&event) else {
            return Ok(());
        };
        let session = std::env::var("ROTA_SESSION").map_err(|_| "Missing Rota session.".to_string())?;
        let dialog_file = std::env::var("ROTA_SESSION_DIALOG").ok();
        ClaudeDialog::append_question_marker(true, dialog_file.as_deref());

        let socket = ControlServer::standard_socket();
        let q_json = serde_json::to_value(&request.question).map_err(|e| e.to_string())?;
        let mut answer = QuestionAnswer::cancel();
        let collect = (|| -> Result<QuestionAnswer, String> {
            let _ = ControlClient::call(
                "questions.create",
                json!({"session": session, "question": q_json}),
                &socket,
                Duration::from_secs(30),
            )
            .map_err(|e| e.message)?;
            loop {
                let res = ControlClient::call(
                    "questions.poll",
                    json!({"session": session, "question": request.question.id}),
                    &socket,
                    Duration::from_secs(30),
                )
                .map_err(|e| e.message)?;
                if res.get("pending").and_then(Value::as_bool) == Some(true) {
                    std::thread::sleep(Duration::from_millis(250));
                    continue;
                }
                return serde_json::from_value::<QuestionAnswer>(res).map_err(|e| e.to_string());
            }
        })();
        ClaudeDialog::append_question_marker(false, dialog_file.as_deref());
        match collect {
            Ok(ans) => answer = ans,
            Err(_) => {
                let _ = std::io::stderr()
                    .write_all(b"Rota could not collect the answer. The request was canceled.\n");
            }
        }
        let mut out = serde_json::to_vec(&(request.response)(&answer)).map_err(|e| e.to_string())?;
        out.push(b'\n');
        std::io::stdout().write_all(&out).map_err(|e| e.to_string())
    }
}
