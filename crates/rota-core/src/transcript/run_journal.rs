use std::cell::RefCell;
use std::collections::{HashMap, HashSet};
use std::fs::File;
use std::sync::{Arc, Mutex};
use std::time::Instant;

use rota_platform::Logger;

use crate::model::SessionConfiguration;
use crate::runners::RunEvents;
use crate::storage::SessionImageStore;
use crate::transcript::{
    Transcript, TranscriptItem, TranscriptItemKind, TranscriptJournal, TranscriptRecord,
};

thread_local! {
    static SOURCE_STACK: RefCell<Vec<(String, usize)>> = const { RefCell::new(Vec::new()) };
}

pub(crate) struct JournalInner {
    pub(crate) output: File,
    pub(crate) closed: bool,
    pub(crate) finished: bool,
    pub(crate) pending_text: String,
    pub(crate) pending_id: Option<usize>,
    pub(crate) pending_kind: TranscriptItemKind,
    pub(crate) pending_native_id: Option<String>,
    pub(crate) native_items: HashMap<String, String>,
    pub(crate) transcript: Option<TranscriptJournal>,
    pub(crate) images: Option<SessionImageStore>,
    pub(crate) reported_configuration: SessionConfiguration,
    pub(crate) source_ids: HashSet<String>,
}

/// Thread-safe writer for one run's `.log` and `.chat.jsonl`, plus once-only finish & RunEvents dispatch.
pub struct RunJournal {
    pub(crate) inner: Mutex<JournalInner>,
    pub(crate) events: RunEvents,
    pub(crate) started_at: Instant,
}

impl RunJournal {
    pub(crate) const LOG: Logger = Logger::new("runner");

    pub fn new(
        output: File,
        events: RunEvents,
        transcript: Option<TranscriptJournal>,
        images: Option<SessionImageStore>,
    ) -> Arc<Self> {
        let source_ids = transcript
            .as_ref()
            .map(|t| t.source_ids.clone())
            .unwrap_or_default();
        let mut native_items = transcript
            .as_ref()
            .map(|t| t.native_items.clone())
            .unwrap_or_default();
        let run_start_id = transcript.as_ref().map(|t| t.next_id);
        let reported_configuration = SessionConfiguration {
            from_item: run_start_id,
            ..SessionConfiguration::default()
        };

        let mut pending_id = None;
        let mut pending_text = String::new();
        let mut pending_kind = TranscriptItemKind::Agent;
        let mut pending_native_id = None;

        if let Some(unfin) = transcript.as_ref().and_then(|t| t.unfinished.as_ref()) {
            pending_id = Some(unfin.id);
            pending_text = unfin.text.clone();
            pending_kind = unfin.kind;
            pending_native_id = unfin.native_id.clone();
            if let Some(nid) = &unfin.native_id {
                native_items.remove(nid);
            }
        }

        Arc::new(Self {
            inner: Mutex::new(JournalInner {
                output,
                closed: false,
                finished: false,
                pending_text,
                pending_id,
                pending_kind,
                pending_native_id,
                native_items,
                transcript,
                images,
                reported_configuration,
                source_ids,
            }),
            events,
            started_at: Instant::now(),
        })
    }

    pub fn with_source<F, R>(&self, source: &str, body: F) -> R
    where
        F: FnOnce() -> R,
    {
        SOURCE_STACK.with(|stack| stack.borrow_mut().push((source.to_string(), 0)));
        struct PopGuard;
        impl Drop for PopGuard {
            fn drop(&mut self) {
                SOURCE_STACK.with(|stack| {
                    stack.borrow_mut().pop();
                });
            }
        }
        let _guard = PopGuard;
        body()
    }

    fn next_source() -> Option<String> {
        SOURCE_STACK.with(|stack| {
            let mut s = stack.borrow_mut();
            let (id, idx) = s.last_mut()?;
            let out = format!("{id}/{idx}");
            *idx += 1;
            Some(out)
        })
    }

    pub fn is_finished(&self) -> bool {
        self.inner.lock().unwrap().finished
    }

    pub fn line(&self, text: &str) {
        let mut g = self.inner.lock().unwrap();
        if g.closed {
            return;
        }
        let source = Self::next_source();
        if let Some(src) = &source
            && !g.source_ids.insert(src.clone())
        {
            return;
        }
        Self::flush_text(&mut g);
        Self::write_raw(&mut g, text);
        let log_size = Self::file_offset(&mut g.output);
        if let Some((kind, body)) = Transcript::classify(text, false) {
            Self::append_item(&mut g, kind, &body, source, None, log_size);
        } else {
            Self::persist(
                &mut g,
                TranscriptRecord {
                    version: 1,
                    record_type: "checkpoint".into(),
                    required: Some(false),
                    id: None,
                    kind: None,
                    text: None,
                    complete: None,
                    log_size,
                    source_id: source,
                    native_id: None,
                },
            );
        }
    }

    pub fn record(&self, kind: TranscriptItemKind, text: &str) {
        self.record_with_native(kind, text, None);
    }

    pub fn record_with_native(&self, kind: TranscriptItemKind, text: &str, native_id: Option<&str>) {
        let mut g = self.inner.lock().unwrap();
        if g.closed {
            return;
        }
        if let Some(nid) = native_id
            && g.native_items.contains_key(nid)
        {
            return;
        }
        let source = Self::next_source();
        if let Some(src) = &source
            && !g.source_ids.insert(src.clone())
        {
            return;
        }
        Self::flush_text(&mut g);
        let next_item_id = g.transcript.as_ref().map(|t| t.next_id);
        let mut body = text.to_string();
        let mut image_warning: Option<String> = None;
        if kind == TranscriptItemKind::Output
            && let Some(images) = &g.images
        {
            match images.preserve_output(text, next_item_id) {
                Ok(preserved) => body = preserved,
                Err(err) => image_warning = Some(format!("Couldn't preserve a tool image: {err}")),
            }
        }
        let item = TranscriptItem::new(0, kind, body).presented();
        if item.kind == TranscriptItemKind::Agent {
            Self::capture_images_warning(&mut g, &item.text, next_item_id, &mut image_warning);
        }
        Self::write_raw(&mut g, &Self::readable(item.kind, &item.text));
        let log_size = Self::file_offset(&mut g.output);
        Self::append_item(
            &mut g,
            item.kind,
            &item.text,
            source,
            native_id.map(ToOwned::to_owned),
            log_size,
        );
        if let Some(nid) = native_id {
            g.native_items.insert(nid.to_string(), text.to_string());
        }
        if let Some(warning) = image_warning {
            Self::write_raw(&mut g, &Self::readable(TranscriptItemKind::Status, &warning));
            let sz = Self::file_offset(&mut g.output);
            Self::append_item(&mut g, TranscriptItemKind::Status, &warning, None, None, sz);
        }
    }

    pub fn text(&self, chunk: &str, kind: TranscriptItemKind, native_id: Option<&str>) {
        if chunk.is_empty() {
            return;
        }
        let mut g = self.inner.lock().unwrap();
        if g.closed {
            return;
        }
        let source = Self::next_source();
        if let Some(src) = &source
            && !g.source_ids.insert(src.clone())
        {
            return;
        }
        if g.pending_kind != kind || g.pending_native_id.as_deref() != native_id {
            Self::flush_text(&mut g);
        }
        g.pending_kind = kind;
        g.pending_native_id = native_id.map(ToOwned::to_owned);
        g.pending_text.push_str(chunk);
        let log_size = Self::file_offset(&mut g.output);
        if let Some(pid) = g.pending_id {
            Self::persist(
                &mut g,
                TranscriptRecord {
                    version: 1,
                    record_type: "append".into(),
                    required: None,
                    id: Some(pid as isize),
                    kind: None,
                    text: Some(chunk.to_string()),
                    complete: None,
                    log_size,
                    source_id: source,
                    native_id: None,
                },
            );
        } else if let Some(tj) = &mut g.transcript {
            let id = tj.allocate_id();
            g.pending_id = Some(id);
            Self::persist(
                &mut g,
                TranscriptRecord {
                    version: 1,
                    record_type: "item".into(),
                    required: None,
                    id: Some(id as isize),
                    kind: Some(kind.as_str().into()),
                    text: Some(chunk.to_string()),
                    complete: Some(false),
                    log_size,
                    source_id: source,
                    native_id: native_id.map(ToOwned::to_owned),
                },
            );
        }
    }

    pub fn end_text(&self) {
        let mut g = self.inner.lock().unwrap();
        Self::flush_text(&mut g);
    }

    pub fn reconcile_text(&self, text: &str, kind: TranscriptItemKind, native_id: &str) {
        let prior = {
            let g = self.inner.lock().unwrap();
            if g.pending_native_id.as_deref() == Some(native_id) {
                Some(g.pending_text.clone())
            } else {
                g.native_items.get(native_id).cloned()
            }
        };
        if let Some(prior) = prior {
            if text == prior {
                self.end_text();
                return;
            }
            if let Some(suffix) = text.strip_prefix(&prior) {
                self.text(suffix, kind, Some(native_id));
                self.end_text();
                return;
            }
            self.record(
                TranscriptItemKind::Status,
                "The provider revised a previously recorded message; see its native history.",
            );
            return;
        }
        self.record_with_native(kind, text, Some(native_id));
    }
}
