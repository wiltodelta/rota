pub mod log;

use std::collections::HashMap;
use std::path::PathBuf;
use std::sync::{Arc, Mutex, OnceLock, mpsc};
use std::time::Duration;

use rota_platform::{Logger, ProcessResourceReading, system_uptime_seconds};

pub use log::{
    MainThreadProbe, PerformanceContext, PerformanceEvent, PerformanceEventKind, PerformanceLog,
    PerformanceProbeState, PerformanceSurface, TranscriptPerformance, format_local_iso,
};

pub type ContextProvider = Arc<dyn Fn() -> PerformanceContext + Send + Sync>;
pub type MainDispatcher = Arc<dyn Fn(Box<dyn FnOnce() + Send>) + Send + Sync>;

enum DiagCommand {
    Start {
        directory: PathBuf,
        metadata: HashMap<String, String>,
        context: ContextProvider,
        dispatcher: Option<MainDispatcher>,
    },
    SetSleeping(bool),
    RecordTranscript {
        seconds: f64,
        items: usize,
        earlier: bool,
        shell: bool,
    },
    ProbeReceived {
        probe: MainThreadProbe,
        received_at: f64,
        context: PerformanceContext,
    },
    Stop(mpsc::Sender<()>),
}

struct WorkerState {
    journal: Option<PerformanceLog>,
    probes: PerformanceProbeState,
    resources: Option<ProcessResourceReading>,
    last_sample: f64,
    context: PerformanceContext,
    transcript: TranscriptPerformance,
    context_provider: Option<ContextProvider>,
    dispatcher: Option<MainDispatcher>,
}

impl Default for WorkerState {
    fn default() -> Self {
        Self {
            journal: None,
            probes: PerformanceProbeState::new(),
            resources: None,
            last_sample: 0.0,
            context: PerformanceContext::default(),
            transcript: TranscriptPerformance::default(),
            context_provider: None,
            dispatcher: None,
        }
    }
}

/// Asynchronous performance journal and main-thread stall detector.
pub struct PerformanceDiagnostics {
    tx: Mutex<mpsc::Sender<DiagCommand>>,
}

impl Default for PerformanceDiagnostics {
    fn default() -> Self {
        Self::new()
    }
}

impl PerformanceDiagnostics {
    const LOG: Logger = Logger::new("performance");

    pub fn shared() -> &'static Self {
        static SHARED: OnceLock<PerformanceDiagnostics> = OnceLock::new();
        SHARED.get_or_init(Self::new)
    }

    pub fn new() -> Self {
        let (tx, rx) = mpsc::channel::<DiagCommand>();
        let tx_for_worker = tx.clone();
        std::thread::Builder::new()
            .name("rota-performance".to_string())
            .spawn(move || Self::worker_loop(rx, tx_for_worker))
            .expect("spawn performance diagnostics thread");
        Self { tx: Mutex::new(tx) }
    }

    pub fn start(&self, directory: PathBuf, metadata: HashMap<String, String>, context: ContextProvider) {
        self.send(DiagCommand::Start {
            directory,
            metadata,
            context,
            dispatcher: None,
        });
    }

    pub fn start_with_dispatcher(
        &self,
        directory: PathBuf,
        metadata: HashMap<String, String>,
        dispatcher: MainDispatcher,
        context: ContextProvider,
    ) {
        self.send(DiagCommand::Start {
            directory,
            metadata,
            context,
            dispatcher: Some(dispatcher),
        });
    }

    pub fn set_sleeping(&self, sleeping: bool) {
        self.send(DiagCommand::SetSleeping(sleeping));
    }

    pub fn record_transcript(&self, seconds: f64, items: usize, earlier: bool, shell: bool) {
        self.send(DiagCommand::RecordTranscript {
            seconds,
            items,
            earlier,
            shell,
        });
    }

    pub fn stop(&self) {
        let (ack_tx, ack_rx) = mpsc::channel();
        self.send(DiagCommand::Stop(ack_tx));
        let _ = ack_rx.recv_timeout(Duration::from_secs(2));
    }

    fn send(&self, cmd: DiagCommand) {
        if let Ok(tx) = self.tx.lock() {
            let _ = tx.send(cmd);
        }
    }

    fn worker_loop(rx: mpsc::Receiver<DiagCommand>, self_tx: mpsc::Sender<DiagCommand>) {
        let mut state = WorkerState::default();
        loop {
            let timeout = if state.journal.is_some() && !state.probes.sleeping {
                Duration::from_secs(1)
            } else {
                Duration::from_secs(3600)
            };
            match rx.recv_timeout(timeout) {
                Ok(cmd) => Self::handle_command(&mut state, cmd, &self_tx),
                Err(mpsc::RecvTimeoutError::Timeout) => Self::tick(&mut state, &self_tx),
                Err(mpsc::RecvTimeoutError::Disconnected) => break,
            }
        }
    }

    fn handle_command(state: &mut WorkerState, cmd: DiagCommand, self_tx: &mpsc::Sender<DiagCommand>) {
        match cmd {
            DiagCommand::Start {
                directory,
                metadata,
                context,
                dispatcher,
            } => {
                if state.journal.is_some() {
                    return;
                }
                match PerformanceLog::new(&directory, &metadata, PerformanceLog::BYTE_LIMIT) {
                    Ok(journal) => {
                        state.journal = Some(journal);
                        state.probes.set_sleeping(false);
                        state.resources = None;
                        state.last_sample = 0.0;
                        state.context = PerformanceContext::default();
                        state.transcript = TranscriptPerformance::default();
                        state.context_provider = Some(context);
                        state.dispatcher = dispatcher;
                        Self::tick(state, self_tx);
                    }
                    Err(err) => {
                        Self::LOG.error(&format!("Couldn't start local performance diagnostics: {err}"));
                    }
                }
            }
            DiagCommand::SetSleeping(sleeping) => {
                if state.journal.is_none() {
                    return;
                }
                state.probes.set_sleeping(sleeping);
                state.resources = None;
                state.last_sample = 0.0;
                let kind = if sleeping {
                    PerformanceEventKind::Sleep
                } else {
                    PerformanceEventKind::Wake
                };
                Self::write(state, PerformanceEvent::new(kind, system_uptime_seconds()));
            }
            DiagCommand::RecordTranscript {
                seconds,
                items,
                earlier,
                shell,
            } => {
                if state.journal.is_none() {
                    return;
                }
                state.transcript.add(seconds, items, earlier, shell);
                if seconds >= 0.1 {
                    let mut slow = TranscriptPerformance::default();
                    slow.add(seconds, items, earlier, shell);
                    let mut ev =
                        PerformanceEvent::new(PerformanceEventKind::SlowTranscript, system_uptime_seconds());
                    ev.duration_ms = Some(seconds * 1_000.0);
                    ev.context = Some(state.context.clone());
                    ev.transcript = Some(slow);
                    Self::write(state, ev);
                }
            }
            DiagCommand::ProbeReceived {
                probe,
                received_at,
                context,
            } => {
                if state.journal.is_none() {
                    return;
                }
                let Some(delay) = state.probes.finish(probe, received_at) else {
                    return;
                };
                state.context = context.clone();
                if delay >= 0.25 {
                    let mut ev =
                        PerformanceEvent::new(PerformanceEventKind::MainThreadDelay, system_uptime_seconds());
                    ev.duration_ms = Some(delay * 1_000.0);
                    ev.context = Some(context);
                    Self::write(state, ev);
                }
            }
            DiagCommand::Stop(ack) => {
                if state.journal.is_some() {
                    let mut ev =
                        PerformanceEvent::new(PerformanceEventKind::Shutdown, system_uptime_seconds());
                    ev.context = Some(state.context.clone());
                    ev.transcript = Some(std::mem::take(&mut state.transcript));
                    Self::write(state, ev);
                }
                state.journal = None;
                state.context_provider = None;
                state.dispatcher = None;
                state.probes.set_sleeping(true);
                let _ = ack.send(());
            }
        }
    }

    fn tick(state: &mut WorkerState, self_tx: &mpsc::Sender<DiagCommand>) {
        if state.journal.is_none() || state.probes.sleeping {
            return;
        }
        let now = system_uptime_seconds();
        if let Some(delay) = state.probes.stalled(now) {
            let mut ev = PerformanceEvent::new(PerformanceEventKind::MainThreadStall, now);
            ev.duration_ms = Some(delay * 1_000.0);
            ev.context = Some(state.context.clone());
            Self::write(state, ev);
        }
        if now - state.last_sample >= 10.0 {
            let next = ProcessResourceReading::current();
            let mut ev = PerformanceEvent::new(PerformanceEventKind::Resources, now);
            ev.cpu_percent = next.cpu_percent_since(state.resources);
            ev.resident_bytes = next.resident_bytes;
            ev.duration_ms = Some(state.probes.max_delay * 1_000.0);
            ev.context = Some(state.context.clone());
            ev.transcript = Some(std::mem::take(&mut state.transcript));
            Self::write(state, ev);
            state.resources = Some(next);
            state.last_sample = now;
            state.probes.max_delay = 0.0;
        }
        let Some(provider) = state.context_provider.clone() else {
            return;
        };
        if let Some(dispatcher) = state.dispatcher.clone() {
            let Some(probe) = state.probes.begin(now) else {
                return;
            };
            let tx = self_tx.clone();
            dispatcher(Box::new(move || {
                let received_at = system_uptime_seconds();
                let context = provider();
                let _ = tx.send(DiagCommand::ProbeReceived {
                    probe,
                    received_at,
                    context,
                });
            }));
        } else {
            state.context = provider();
        }
    }

    fn write(state: &mut WorkerState, event: PerformanceEvent) {
        if let Some(journal) = &mut state.journal
            && let Err(err) = journal.append(event)
        {
            Self::LOG.error(&format!(
                "Local performance diagnostics stopped after a write failure: {err}"
            ));
            state.journal = None;
        }
    }
}
