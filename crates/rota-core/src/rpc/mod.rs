pub mod websocket;

use std::collections::HashMap;
use std::fmt;
use std::io::{Read, Write};
use std::os::fd::AsRawFd;
use std::process::{ChildStdin, ChildStdout};
use std::sync::{Arc, Mutex, mpsc};

use serde_json::{Value, json};
use uuid::Uuid;

pub use websocket::{WebSocketTransport, WsFrame};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct JsonRpcError {
    pub message: String,
    pub server_code: Option<String>,
}

impl JsonRpcError {
    pub fn new(message: impl Into<String>, server_code: Option<String>) -> Self {
        Self {
            message: message.into(),
            server_code,
        }
    }
}

impl fmt::Display for JsonRpcError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.message)
    }
}

impl std::error::Error for JsonRpcError {}

pub type JsonRpcReply = Box<dyn FnOnce(Result<Value, JsonRpcError>) + Send + 'static>;
pub type SyncRequestHandler = Arc<dyn Fn(&str, &Value) -> Option<Value> + Send + Sync + 'static>;
pub type AsyncRequestReply = Box<dyn FnOnce(Option<Value>) + Send + Sync + 'static>;
pub type AsyncRequestHandler = Arc<dyn Fn(String, String, Value, AsyncRequestReply) + Send + Sync + 'static>;
pub type NotificationHandler = Arc<dyn Fn(String, Value) + Send + Sync + 'static>;
pub type CloseHandler = Arc<dyn Fn() + Send + Sync + 'static>;

pub trait MessageTransport: Send + Sync {
    fn set_handlers(
        &self,
        on_message: Arc<dyn Fn(Vec<u8>) + Send + Sync>,
        on_close: Arc<dyn Fn() + Send + Sync>,
    );
    fn send(&self, message: &[u8]);
    fn close(&self);
}

struct PeerState {
    next_id: i64,
    pending: HashMap<i64, JsonRpcReply>,
    incoming: HashMap<String, Uuid>,
    on_notification: Option<NotificationHandler>,
    on_request: Option<SyncRequestHandler>,
    on_request_async: Option<AsyncRequestHandler>,
    on_close: Option<CloseHandler>,
    closed: bool,
}

/// Bidirectional JSON-RPC 2.0 peer supporting client requests, notifications, sync & async host requests.
pub struct JsonRpcPeer {
    transport: Arc<dyn MessageTransport>,
    state: Arc<Mutex<PeerState>>,
    dispatcher: Option<mpsc::Sender<Box<dyn FnOnce() + Send>>>,
}

impl JsonRpcPeer {
    pub fn new(transport: Arc<dyn MessageTransport>, serial_callbacks: bool) -> Arc<Self> {
        let dispatcher = if serial_callbacks {
            let (tx, rx) = mpsc::channel::<Box<dyn FnOnce() + Send>>();
            std::thread::spawn(move || {
                while let Ok(job) = rx.recv() {
                    job();
                }
            });
            Some(tx)
        } else {
            None
        };
        let peer = Arc::new(Self {
            transport: Arc::clone(&transport),
            state: Arc::new(Mutex::new(PeerState {
                next_id: 1,
                pending: HashMap::new(),
                incoming: HashMap::new(),
                on_notification: None,
                on_request: None,
                on_request_async: None,
                on_close: None,
                closed: false,
            })),
            dispatcher,
        });
        let weak_msg = Arc::downgrade(&peer);
        let weak_close = Arc::downgrade(&peer);
        transport.set_handlers(
            Arc::new(move |bytes| {
                if let Some(p) = weak_msg.upgrade() {
                    p.receive(&bytes);
                }
            }),
            Arc::new(move || {
                if let Some(p) = weak_close.upgrade() {
                    p.handle_closed();
                }
            }),
        );
        peer
    }

    pub fn set_on_notification(&self, handler: NotificationHandler) {
        self.state.lock().unwrap().on_notification = Some(handler);
    }

    pub fn set_on_request(&self, handler: SyncRequestHandler) {
        self.state.lock().unwrap().on_request = Some(handler);
    }

    pub fn set_on_request_async(&self, handler: AsyncRequestHandler) {
        self.state.lock().unwrap().on_request_async = Some(handler);
    }

    pub fn set_on_close(&self, handler: CloseHandler) {
        self.state.lock().unwrap().on_close = Some(handler);
    }

    pub fn request<F>(&self, method: &str, params: Value, reply: F)
    where
        F: FnOnce(Result<Value, JsonRpcError>) + Send + 'static,
    {
        let id = {
            let mut g = self.state.lock().unwrap();
            if g.closed {
                drop(g);
                reply(Err(JsonRpcError::new("connection closed", None)));
                return;
            }
            let id = g.next_id;
            g.next_id += 1;
            g.pending.insert(id, Box::new(reply));
            id
        };
        self.write_json(&json!({
            "jsonrpc": "2.0",
            "id": id,
            "method": method,
            "params": params,
        }));
    }

    pub fn notify(&self, method: &str, params: Value) {
        self.write_json(&json!({
            "jsonrpc": "2.0",
            "method": method,
            "params": params,
        }));
    }

    pub fn dismiss_request(&self, id: &str) {
        self.state.lock().unwrap().incoming.remove(id);
    }

    pub fn close(&self) {
        self.transport.close();
    }

    fn write_json(&self, val: &Value) {
        if let Ok(bytes) = serde_json::to_vec(val) {
            self.transport.send(&bytes);
        }
    }

    fn deliver<F: FnOnce() + Send + 'static>(&self, work: F) {
        if let Some(tx) = &self.dispatcher {
            let _ = tx.send(Box::new(work));
        } else {
            work();
        }
    }

    fn receive(self: &Arc<Self>, data: &[u8]) {
        let Ok(msg) = serde_json::from_slice::<Value>(data) else {
            return;
        };
        let method = msg.get("method").and_then(Value::as_str).map(ToOwned::to_owned);
        let params = msg.get("params").cloned().unwrap_or_else(|| json!({}));
        let raw_id = msg.get("id").cloned();

        match (method, raw_id) {
            (Some(method), Some(id_val)) => {
                let (async_h, sync_h) = {
                    let g = self.state.lock().unwrap();
                    (g.on_request_async.clone(), g.on_request.clone())
                };
                if let Some(handler) = async_h {
                    self.receive_async_request(id_val, method, params, handler);
                } else if let Some(handler) = sync_h
                    && let Some(result) = handler(&method, &params)
                {
                    self.write_json(&json!({
                        "jsonrpc": "2.0",
                        "id": id_val,
                        "result": result,
                    }));
                } else {
                    self.write_json(&json!({
                        "jsonrpc": "2.0",
                        "id": id_val,
                        "error": {"code": -32601, "message": format!("Rota does not handle {method}")},
                    }));
                }
            }
            (Some(method), None) => {
                let notif_h = self.state.lock().unwrap().on_notification.clone();
                if let Some(h) = notif_h {
                    self.deliver(move || h(method, params));
                }
            }
            (None, Some(id_val)) => {
                let Some(id_int) = id_val.as_i64() else {
                    return;
                };
                let reply = self.state.lock().unwrap().pending.remove(&id_int);
                let Some(reply) = reply else {
                    return;
                };
                let outcome = if let Some(err_obj) = msg.get("error").and_then(Value::as_object) {
                    let text = err_obj
                        .get("message")
                        .and_then(Value::as_str)
                        .unwrap_or("error")
                        .to_string();
                    let code = err_obj
                        .get("data")
                        .and_then(|d| d.get("code"))
                        .and_then(Value::as_str)
                        .map(ToOwned::to_owned);
                    Err(JsonRpcError::new(text, code))
                } else {
                    Ok(msg.get("result").cloned().unwrap_or(Value::Null))
                };
                self.deliver(move || reply(outcome));
            }
            (None, None) => {}
        }
    }

    fn receive_async_request(
        self: &Arc<Self>,
        id_val: Value,
        method: String,
        params: Value,
        handler: AsyncRequestHandler,
    ) {
        let key = id_key(&id_val);
        let token = Uuid::new_v4();
        self.state.lock().unwrap().incoming.insert(key.clone(), token);
        let peer = Arc::clone(self);
        self.deliver(move || {
            let key_for_cb = key.clone();
            let method_for_cb = method.clone();
            handler(
                key,
                method,
                params,
                Box::new(move |result| {
                    let current = {
                        let mut g = peer.state.lock().unwrap();
                        if g.incoming.get(&key_for_cb) == Some(&token) {
                            g.incoming.remove(&key_for_cb);
                            true
                        } else {
                            false
                        }
                    };
                    if !current {
                        return;
                    }
                    if let Some(res) = result {
                        peer.write_json(&json!({
                            "jsonrpc": "2.0",
                            "id": id_val,
                            "result": res,
                        }));
                    } else {
                        peer.write_json(&json!({
                            "jsonrpc": "2.0",
                            "id": id_val,
                            "error": {"code": -32601, "message": format!("Rota does not handle {method_for_cb}")},
                        }));
                    }
                }),
            );
        });
    }

    fn handle_closed(&self) {
        let (waiting, on_close) = {
            let mut g = self.state.lock().unwrap();
            if g.closed {
                return;
            }
            g.closed = true;
            g.incoming.clear();
            let waiting: Vec<JsonRpcReply> = g.pending.drain().map(|(_, r)| r).collect();
            (waiting, g.on_close.clone())
        };
        self.deliver(move || {
            for r in waiting {
                r(Err(JsonRpcError::new("connection closed", None)));
            }
            if let Some(cb) = on_close {
                cb();
            }
        });
    }
}

fn id_key(val: &Value) -> String {
    match val {
        Value::String(s) => s.clone(),
        Value::Number(n) => n.to_string(),
        other => other.to_string(),
    }
}

pub(crate) fn disable_sigpipe<F: AsRawFd>(fd: &F) {
    #[cfg(target_os = "macos")]
    unsafe {
        let _ = libc::fcntl(fd.as_raw_fd(), libc::F_SETNOSIGPIPE, 1);
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = fd;
    }
}

/// NDJSON stdio transport (one JSON message per line).
pub struct LineTransport {
    stdin: Mutex<Option<ChildStdin>>,
    handlers: Arc<Mutex<TransportCallbacks>>,
}

#[derive(Default)]
pub(crate) struct TransportCallbacks {
    pub on_message: Option<Arc<dyn Fn(Vec<u8>) + Send + Sync>>,
    pub on_close: Option<Arc<dyn Fn() + Send + Sync>>,
    pub pending_messages: Vec<Vec<u8>>,
    pub closed: bool,
}

impl LineTransport {
    pub fn spawn(stdin: ChildStdin, mut stdout: ChildStdout) -> Arc<Self> {
        disable_sigpipe(&stdin);
        let handlers = Arc::new(Mutex::new(TransportCallbacks::default()));
        let h_read = Arc::clone(&handlers);
        std::thread::spawn(move || {
            let mut buffer = Vec::new();
            let mut chunk = [0u8; 16_384];
            loop {
                match stdout.read(&mut chunk) {
                    Ok(0) | Err(_) => {
                        let cb = {
                            let mut g = h_read.lock().unwrap();
                            g.closed = true;
                            g.on_close.clone()
                        };
                        if let Some(cb) = cb {
                            cb();
                        }
                        break;
                    }
                    Ok(n) => {
                        buffer.extend_from_slice(&chunk[..n]);
                        while let Some(nl) = buffer.iter().position(|&b| b == b'\n') {
                            let mut line: Vec<u8> = buffer.drain(..=nl).take(nl).collect();
                            if line.last() == Some(&b'\r') {
                                line.pop();
                            }
                            if line.is_empty() {
                                continue;
                            }
                            let cb = {
                                let mut g = h_read.lock().unwrap();
                                if let Some(cb) = &g.on_message {
                                    Some(Arc::clone(cb))
                                } else {
                                    g.pending_messages.push(line.clone());
                                    None
                                }
                            };
                            if let Some(cb) = cb {
                                cb(line);
                            }
                        }
                    }
                }
            }
        });
        Arc::new(Self {
            stdin: Mutex::new(Some(stdin)),
            handlers,
        })
    }
}

impl MessageTransport for LineTransport {
    fn set_handlers(
        &self,
        on_message: Arc<dyn Fn(Vec<u8>) + Send + Sync>,
        on_close: Arc<dyn Fn() + Send + Sync>,
    ) {
        let (queued, already_closed) = {
            let mut g = self.handlers.lock().unwrap();
            let q = std::mem::take(&mut g.pending_messages);
            let c = g.closed;
            g.on_message = Some(Arc::clone(&on_message));
            g.on_close = Some(Arc::clone(&on_close));
            (q, c)
        };
        for m in queued {
            on_message(m);
        }
        if already_closed {
            on_close();
        }
    }

    fn send(&self, message: &[u8]) {
        if let Some(stdin) = self.stdin.lock().unwrap().as_mut() {
            let _ = stdin.write_all(message);
            let _ = stdin.write_all(b"\n");
            let _ = stdin.flush();
        }
    }

    fn close(&self) {
        let _ = self.stdin.lock().unwrap().take();
    }
}
