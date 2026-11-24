use std::collections::HashMap;
use std::fs::OpenOptions;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::sync::{Arc, Mutex, mpsc};
use std::time::Duration;

use rota_core::{
    JsonRpcPeer, MarkdownTable, MessageTransport, PerformanceEvent, PerformanceEventKind, PerformanceLog,
    RunEvents, RunJournal, Transcript, TranscriptItemKind, TranscriptJournal, TranscriptReader,
    TranscriptTurn, WebSocketTransport,
};
use serde_json::{Value, json};
use uuid::Uuid;

struct TempDir(PathBuf);

impl TempDir {
    fn new() -> Self {
        let dir = std::env::temp_dir().join(format!("rota-tx-test-{}", Uuid::new_v4()));
        std::fs::create_dir_all(&dir).unwrap();
        Self(dir)
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

#[test]
fn transcript_journal_supports_streaming_and_reverse_paging() {
    let tmp = TempDir::new();
    let log = tmp.0.join("session.log");
    let log_file = OpenOptions::new()
        .create(true)
        .write(true)
        .truncate(true)
        .open(&log)
        .unwrap();

    let tj = TranscriptJournal::open(&log, false, 0).unwrap();
    let run_journal = RunJournal::new(log_file, RunEvents::new(|_| {}, |_| {}), Some(tj), None);

    for idx in 0..12 {
        if idx % 2 == 0 {
            run_journal.record(TranscriptItemKind::User, &format!("Prompt {idx}"));
        } else {
            run_journal.text("Part 1", TranscriptItemKind::Agent, None);
            run_journal.text(&format!(" + Part 2 ({idx})"), TranscriptItemKind::Agent, None);
            run_journal.end_text();
        }
    }

    let mut paged = TranscriptReader::new(Some(4), false);
    let tail = paged.read(&log, false, true);
    assert!(tail.structured);
    assert!(tail.has_earlier);
    assert_eq!(tail.items.len(), 4);
    assert_eq!(tail.items[0].id, 8);
    assert_eq!(tail.items[3].text, "Part 1 + Part 2 (11)");

    let next_page = paged.read_earlier(&log, true);
    assert_eq!(next_page.items.len(), 8);
    assert_eq!(next_page.items[0].id, 4);
    assert!(next_page.has_earlier);

    let full = paged.read_earlier(&log, true);
    assert_eq!(full.items.len(), 12);
    assert_eq!(full.items[0].id, 0);
    assert!(!full.has_earlier);
}

#[test]
fn legacy_transcript_parsing_turns_and_markdown_tables() {
    let raw = "[you] Check status\n-> Bash\n[output] ok\nAll systems green.\n[rota: Succeeded after 125 s]";
    let items = Transcript::parse(raw, false);
    assert_eq!(items.len(), 5);
    assert_eq!(items[4].kind, TranscriptItemKind::Status);
    assert_eq!(items[4].text, "Completed after 2m 5s");

    let turns = TranscriptTurn::group(&items);
    assert_eq!(turns.len(), 1);
    assert_eq!(turns[0].tool_count(), 1);
    let msgs = turns[0].answer_messages();
    assert_eq!(msgs.len(), 2);
    assert_eq!(msgs[0].text, "ok");
    assert_eq!(msgs[1].text, "All systems green.");

    let md = "| Service | Status |\n| :--- | ---: |\n| API | 200 |\n";
    let lines: Vec<&str> = md.lines().collect();
    let mut index = 0usize;
    let table = MarkdownTable::parse(&lines, &mut index).unwrap();
    assert_eq!(index, 2);
    assert_eq!(table.headers, vec!["Service", "Status"]);
    assert_eq!(table.rows, vec![vec!["API", "200"]]);
}

#[test]
fn performance_log_rotates_bounded_files() {
    let tmp = TempDir::new();
    let diag_dir = tmp.0.join("Diagnostics");
    let mut meta = HashMap::new();
    meta.insert("version".into(), "test".into());
    let mut perf = PerformanceLog::new(&diag_dir, &meta, 512).unwrap();
    for i in 0..10 {
        let mut ev = PerformanceEvent::new(PerformanceEventKind::Resources, i as f64);
        ev.resident_bytes = Some(1_048_576);
        perf.append(ev).unwrap();
    }
    assert!(perf.current_path().exists());
    assert!(perf.previous_path().exists());
    assert!(std::fs::metadata(perf.current_path()).unwrap().len() <= 512);
}

struct ChannelTransport {
    tx: Mutex<Option<mpsc::Sender<Vec<u8>>>>,
    rx_slot: Mutex<Option<mpsc::Receiver<Vec<u8>>>>,
}

impl ChannelTransport {
    fn pair() -> (Arc<Self>, Arc<Self>) {
        let (tx_ab, rx_ab) = mpsc::channel();
        let (tx_ba, rx_ba) = mpsc::channel();
        (
            Arc::new(Self {
                tx: Mutex::new(Some(tx_ab)),
                rx_slot: Mutex::new(Some(rx_ba)),
            }),
            Arc::new(Self {
                tx: Mutex::new(Some(tx_ba)),
                rx_slot: Mutex::new(Some(rx_ab)),
            }),
        )
    }
}

impl MessageTransport for ChannelTransport {
    fn set_handlers(
        &self,
        on_message: Arc<dyn Fn(Vec<u8>) + Send + Sync>,
        on_close: Arc<dyn Fn() + Send + Sync>,
    ) {
        if let Some(rx) = self.rx_slot.lock().unwrap().take() {
            std::thread::spawn(move || {
                while let Ok(msg) = rx.recv() {
                    on_message(msg);
                }
                on_close();
            });
        }
    }

    fn send(&self, message: &[u8]) {
        if let Some(tx) = self.tx.lock().unwrap().as_ref() {
            let _ = tx.send(message.to_vec());
        }
    }

    fn close(&self) {
        let _ = self.tx.lock().unwrap().take();
    }
}

#[test]
fn jsonrpc_peer_handles_requests_notifications_async_host_calls_and_close() {
    let (t_client, t_server) = ChannelTransport::pair();
    let client = JsonRpcPeer::new(t_client, true);
    let server = JsonRpcPeer::new(t_server, true);

    let (notif_tx, notif_rx) = mpsc::channel();
    server.set_on_notification(Arc::new(move |method, params| {
        let _ = notif_tx.send((method, params));
    }));
    server.set_on_request_async(Arc::new(|_id, method, params, reply| {
        if method == "sum" {
            let a = params.get("a").and_then(Value::as_i64).unwrap_or(0);
            let b = params.get("b").and_then(Value::as_i64).unwrap_or(0);
            reply(Some(json!({"total": a + b})));
        } else {
            reply(None);
        }
    }));

    client.notify("hello", json!({"n": 1}));
    let (nm, np) = notif_rx.recv_timeout(Duration::from_secs(2)).unwrap();
    assert_eq!(nm, "hello");
    assert_eq!(np["n"], 1);

    let (res_tx, res_rx) = mpsc::channel();
    client.request("sum", json!({"a": 19, "b": 23}), move |res| {
        let _ = res_tx.send(res);
    });
    let sum_res = res_rx.recv_timeout(Duration::from_secs(2)).unwrap().unwrap();
    assert_eq!(sum_res["total"], 42);

    let (err_tx, err_rx) = mpsc::channel();
    client.request("unknown_op", json!({}), move |res| {
        let _ = err_tx.send(res);
    });
    assert!(err_rx.recv_timeout(Duration::from_secs(2)).unwrap().is_err());

    server.close();
}

#[test]
fn websocket_stdio_transport_upgrades_and_exchanges_frames() {
    let py = r#"
import json, sys
buf = b""
while b"\r\n\r\n" not in buf:
    ch = sys.stdin.buffer.read(1)
    if not ch: sys.exit(1)
    buf += ch
sys.stdout.buffer.write(b"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n")
sys.stdout.buffer.flush()
hdr = sys.stdin.buffer.read(2)
length = hdr[1] & 0x7f
mask = sys.stdin.buffer.read(4)
raw = bytearray(sys.stdin.buffer.read(length))
for i in range(len(raw)):
    raw[i] ^= mask[i % 4]
msg = json.loads(raw.decode())
reply = json.dumps({"jsonrpc": "2.0", "id": msg["id"], "result": {"echo": msg["params"]["ping"]}}).encode()
sys.stdout.buffer.write(bytes([0x81, len(reply)]) + reply)
sys.stdout.buffer.flush()
"#;
    let mut child = Command::new("/usr/bin/python3")
        .arg("-c")
        .arg(py)
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .spawn()
        .unwrap();
    let stdin = child.stdin.take().unwrap();
    let stdout = child.stdout.take().unwrap();

    let ws = WebSocketTransport::spawn(stdin, stdout);
    let peer = JsonRpcPeer::new(ws, false);
    let (tx, rx) = mpsc::channel();
    peer.request("ping_test", json!({"ping": "pong"}), move |res| {
        let _ = tx.send(res);
    });
    let reply = rx.recv_timeout(Duration::from_secs(5)).unwrap().unwrap();
    assert_eq!(reply["echo"], "pong");
    peer.close();
    let _ = child.wait();
}
