use std::sync::Arc;
use std::time::Duration;

use rota_platform::OwnedProcess;

use crate::model::{RunOutcome, TerminalState};
use crate::runners::{NativeTranscriptEvent, ScreenRun, TerminalRun};
use crate::transcript::TranscriptItemKind;

impl TerminalRun {
    pub(super) fn poll_loop(self: Arc<Self>) {
        loop {
            if self.journal.is_finished() {
                return;
            }
            self.capture_child();
            self.read_transcript();

            {
                let g = self.state.lock().unwrap();
                if g.stop_reason.is_some() && g.stopping.iter().any(OwnedProcess::exists) {
                    drop(g);
                    std::thread::sleep(Duration::from_millis(100));
                    continue;
                }
            }
            if let Some(status) = self.exit_status() {
                let reason = self
                    .state
                    .lock()
                    .unwrap()
                    .stop_reason
                    .clone()
                    .unwrap_or(if status == 0 {
                        RunOutcome::Succeeded
                    } else {
                        RunOutcome::Failed { exit_code: status }
                    });
                self.finish(reason);
                return;
            }
            let list = ScreenRun::list(&self.name);
            if ScreenRun::pid_in_list(&self.name, &list).is_none() {
                let child_alive = self
                    .state
                    .lock()
                    .unwrap()
                    .child
                    .as_ref()
                    .is_some_and(OwnedProcess::exists);
                if child_alive {
                    self.end(RunOutcome::Interrupted);
                    std::thread::sleep(Duration::from_secs(1));
                    continue;
                }
                let reason = self
                    .state
                    .lock()
                    .unwrap()
                    .stop_reason
                    .clone()
                    .or_else(|| {
                        self.exit_status().map(|c| {
                            if c == 0 {
                                RunOutcome::Succeeded
                            } else {
                                RunOutcome::Failed { exit_code: c }
                            }
                        })
                    })
                    .unwrap_or(RunOutcome::Interrupted);
                self.finish(reason);
                return;
            }
            let attached = ScreenRun::attached(&self.name, &list);
            let should_return = {
                let mut g = self.state.lock().unwrap();
                if attached {
                    g.was_attached = true;
                }
                let closed = g.was_attached && !attached && g.waiting && g.stop_reason.is_none();
                g.closed_polls = if closed { g.closed_polls + 1 } else { 0 };
                if g.closed_polls >= 2 {
                    g.stop_reason = Some(RunOutcome::Succeeded);
                    true
                } else {
                    false
                }
            };
            if should_return {
                self.journal
                    .record(TranscriptItemKind::Status, "Returned to Rota");
                self.quit_screen();
            }
            std::thread::sleep(Duration::from_secs(1));
        }
    }

    fn read_transcript(&self) {
        let mut batches = Vec::new();
        let mut lease_to_write = None;
        let mut failed = false;
        {
            let mut g = self.state.lock().unwrap();
            if !g.reading_transcript {
                return;
            }
            match g.transcript.read_with(|evs, src| batches.push((evs, src))) {
                Ok(()) => {
                    let cp = g.transcript.checkpoint();
                    if let Some(lease) = &mut g.lease
                        && lease.native_offset != Some(cp)
                    {
                        lease.native_offset = Some(cp);
                        lease_to_write = Some(lease.clone());
                    }
                }
                Err(_) => {
                    g.reading_transcript = false;
                    failed = true;
                }
            }
        }
        for (events, src) in batches {
            self.journal.with_source(&src, || {
                for ev in events {
                    self.handle_event(ev);
                }
            });
        }
        if let Some(l) = lease_to_write
            && l.write(&self.log).is_err()
        {
            self.state.lock().unwrap().reading_transcript = false;
            failed = true;
        }
        if failed {
            self.journal.record(
                TranscriptItemKind::Error,
                "Terminal history could not be read. Sync is paused; continue in Terminal.",
            );
        }
    }

    fn handle_event(&self, ev: NativeTranscriptEvent) {
        match ev {
            NativeTranscriptEvent::Item(kind, text) => {
                self.journal.record(kind, &text);
                if kind == TranscriptItemKind::User {
                    self.journal.terminal_input();
                }
            }
            NativeTranscriptEvent::Chunk {
                text,
                kind,
                native_id,
            } => {
                self.journal.text(&text, kind, native_id.as_deref());
            }
            NativeTranscriptEvent::Configuration(cfg) => self.journal.configure(cfg),
            NativeTranscriptEvent::State(state) => {
                let quit_now = {
                    let mut g = self.state.lock().unwrap();
                    g.waiting = state == TerminalState::Waiting;
                    g.waiting && g.stop_reason.is_some()
                };
                if state == TerminalState::Waiting {
                    self.journal.end_text();
                }
                self.journal.terminal_state(state);
                if quit_now {
                    self.quit_screen();
                }
            }
        }
    }

    fn exit_status(&self) -> Option<i32> {
        std::fs::read_to_string(&self.exit_file).ok()?.trim().parse().ok()
    }

    pub(super) fn capture_child(&self) {
        let mut g = self.state.lock().unwrap();
        if g.child.is_some() {
            return;
        }
        let Ok(text) = std::fs::read_to_string(&self.child_file) else {
            return;
        };
        let nums: Vec<i32> = text.split_whitespace().filter_map(|t| t.parse().ok()).collect();
        if nums.len() == 2
            && nums[0] > 1
            && let Some(proc_id) = OwnedProcess::capture(nums[0])
            && proc_id.parent == nums[1] as u32
        {
            g.child = Some(proc_id);
        }
    }

    fn end(self: &Arc<Self>, outcome: RunOutcome) {
        self.capture_child();
        {
            let mut g = self.state.lock().unwrap();
            if g.stop_reason.is_some() {
                return;
            }
            g.stop_reason = Some(outcome);
            if let Some(child) = g.child {
                let mut list = child.descendants();
                list.push(child);
                g.stopping = list;
            }
        }
        ScreenRun::command(&self.name, &["-X", "stuff", "\x03"]);
        let weak = Arc::downgrade(self);
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_secs(3));
            if let Some(me) = weak.upgrade() {
                me.quit_screen();
            }
        });
    }

    pub(super) fn quit_screen(&self) {
        if self.journal.is_finished() {
            return;
        }
        self.capture_child();
        let owned = {
            let mut g = self.state.lock().unwrap();
            if g.stopping.is_empty()
                && let Some(child) = g.child
            {
                let mut list = child.descendants();
                list.push(child);
                g.stopping = list;
            }
            g.stopping.clone()
        };
        for p in &owned {
            p.signal(libc::SIGTERM);
        }
        std::thread::spawn(move || {
            std::thread::sleep(Duration::from_secs(2));
            for p in owned {
                p.signal(libc::SIGKILL);
            }
        });
        ScreenRun::quit(&self.name);
    }

    fn finish(&self, outcome: RunOutcome) {
        self.read_transcript();
        self.journal.finish(outcome);
        let _ = std::fs::remove_file(&self.script);
        let _ = std::fs::remove_file(&self.exit_file);
        let _ = std::fs::remove_file(&self.child_file);
    }
}
