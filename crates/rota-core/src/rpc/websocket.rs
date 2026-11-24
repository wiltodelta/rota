use std::io::{Read, Write};
use std::process::{ChildStdin, ChildStdout};
use std::sync::{Arc, Mutex};

use base64::Engine;
use uuid::Uuid;

use crate::rpc::{MessageTransport, TransportCallbacks, disable_sigpipe};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WsFrame {
    pub opcode: u8,
    pub is_final: bool,
    pub payload: Vec<u8>,
    pub length: usize,
}

struct WsWriterState {
    stdin: Option<ChildStdin>,
    upgraded: bool,
    queued: Vec<Vec<u8>>,
}

/// RFC 6455 WebSocket client over a child process's stdin/stdout (`codex app-server proxy`).
pub struct WebSocketTransport {
    writer: Arc<Mutex<WsWriterState>>,
    handlers: Arc<Mutex<TransportCallbacks>>,
}

impl WebSocketTransport {
    pub fn spawn(mut stdin: ChildStdin, mut stdout: ChildStdout) -> Arc<Self> {
        disable_sigpipe(&stdin);
        let key_bytes = Uuid::new_v4();
        let key = base64::engine::general_purpose::STANDARD.encode(key_bytes.as_bytes());
        let handshake = format!(
            "GET / HTTP/1.1\r\nHost: localhost\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\
Sec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n"
        );
        let _ = stdin.write_all(handshake.as_bytes());
        let _ = stdin.flush();

        let writer = Arc::new(Mutex::new(WsWriterState {
            stdin: Some(stdin),
            upgraded: false,
            queued: Vec::new(),
        }));
        let handlers = Arc::new(Mutex::new(TransportCallbacks::default()));

        let w_read = Arc::clone(&writer);
        let h_read = Arc::clone(&handlers);
        std::thread::spawn(move || {
            let mut buffer: Vec<u8> = Vec::new();
            let mut fragments: Vec<u8> = Vec::new();
            let mut upgraded = false;
            let mut chunk = [0u8; 16_384];
            loop {
                match stdout.read(&mut chunk) {
                    Ok(0) | Err(_) => {
                        Self::notify_closed(&h_read);
                        break;
                    }
                    Ok(n) => {
                        buffer.extend_from_slice(&chunk[..n]);
                        if !upgraded {
                            let Some(end) = find_subslice(&buffer, b"\r\n\r\n") else {
                                continue;
                            };
                            let head = String::from_utf8_lossy(&buffer[..end]).into_owned();
                            buffer.drain(..end + 4);
                            if !head.starts_with("HTTP/1.1 101") {
                                Self::notify_closed(&h_read);
                                break;
                            }
                            upgraded = true;
                            let mut wg = w_read.lock().unwrap();
                            wg.upgraded = true;
                            let pending = std::mem::take(&mut wg.queued);
                            if let Some(s) = wg.stdin.as_mut() {
                                for msg in pending {
                                    let _ = s.write_all(&Self::frame(&msg, 0x1));
                                }
                                let _ = s.flush();
                            }
                        }
                        while let Some(parsed) = Self::parse(&buffer) {
                            buffer.drain(..parsed.length);
                            match parsed.opcode {
                                0x0 | 0x1 => {
                                    fragments.extend_from_slice(&parsed.payload);
                                    if parsed.is_final {
                                        let complete = std::mem::take(&mut fragments);
                                        Self::deliver_msg(&h_read, complete);
                                    }
                                }
                                0x9 => {
                                    let mut wg = w_read.lock().unwrap();
                                    if let Some(s) = wg.stdin.as_mut() {
                                        let _ = s.write_all(&Self::frame(&parsed.payload, 0xA));
                                        let _ = s.flush();
                                    }
                                }
                                0x8 => {
                                    Self::notify_closed(&h_read);
                                    return;
                                }
                                _ => {}
                            }
                        }
                    }
                }
            }
        });

        Arc::new(Self { writer, handlers })
    }

    fn deliver_msg(handlers: &Mutex<TransportCallbacks>, msg: Vec<u8>) {
        let cb = {
            let mut g = handlers.lock().unwrap();
            if let Some(cb) = &g.on_message {
                Some(Arc::clone(cb))
            } else {
                g.pending_messages.push(msg.clone());
                None
            }
        };
        if let Some(cb) = cb {
            cb(msg);
        }
    }

    fn notify_closed(handlers: &Mutex<TransportCallbacks>) {
        let cb = {
            let mut g = handlers.lock().unwrap();
            if g.closed {
                return;
            }
            g.closed = true;
            g.on_close.clone()
        };
        if let Some(cb) = cb {
            cb();
        }
    }

    /// Encodes a final, masked client frame using the smallest RFC 6455 length encoding.
    pub fn frame(payload: &[u8], opcode: u8) -> Vec<u8> {
        let count = payload.len();
        let mut out = Vec::with_capacity(count + 14);
        out.push(0x80 | (opcode & 0x0F));
        if count < 126 {
            out.push(0x80 | (count as u8));
        } else if count <= u16::MAX as usize {
            out.push(0x80 | 126);
            out.extend_from_slice(&(count as u16).to_be_bytes());
        } else {
            out.push(0x80 | 127);
            out.extend_from_slice(&(count as u64).to_be_bytes());
        }
        let rand_bytes = Uuid::new_v4();
        let mask = &rand_bytes.as_bytes()[..4];
        out.extend_from_slice(mask);
        for (idx, &b) in payload.iter().enumerate() {
            out.push(b ^ mask[idx % 4]);
        }
        out
    }

    /// Parses one complete WebSocket frame at the start of `data`, or `None` if incomplete.
    pub fn parse(data: &[u8]) -> Option<WsFrame> {
        if data.len() < 2 {
            return None;
        }
        let is_final = (data[0] & 0x80) != 0;
        let opcode = data[0] & 0x0F;
        let masked = (data[1] & 0x80) != 0;
        let mut length = (data[1] & 0x7F) as usize;
        let mut offset = 2usize;
        if length == 126 {
            if data.len() < 4 {
                return None;
            }
            length = u16::from_be_bytes([data[2], data[3]]) as usize;
            offset = 4;
        } else if length == 127 {
            if data.len() < 10 {
                return None;
            }
            let mut arr = [0u8; 8];
            arr.copy_from_slice(&data[2..10]);
            length = u64::from_be_bytes(arr) as usize;
            offset = 10;
        }
        let mask_offset = offset;
        if masked {
            offset += 4;
        }
        let total = offset.checked_add(length)?;
        if data.len() < total {
            return None;
        }
        let mut payload = data[offset..total].to_vec();
        if masked {
            let mask = &data[mask_offset..mask_offset + 4];
            for (idx, b) in payload.iter_mut().enumerate() {
                *b ^= mask[idx % 4];
            }
        }
        Some(WsFrame {
            opcode,
            is_final,
            payload,
            length: total,
        })
    }
}

impl MessageTransport for WebSocketTransport {
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
        let mut wg = self.writer.lock().unwrap();
        if !wg.upgraded {
            wg.queued.push(message.to_vec());
            return;
        }
        if let Some(stdin) = wg.stdin.as_mut() {
            let _ = stdin.write_all(&Self::frame(message, 0x1));
            let _ = stdin.flush();
        }
    }

    fn close(&self) {
        let mut wg = self.writer.lock().unwrap();
        if let Some(mut stdin) = wg.stdin.take() {
            let _ = stdin.write_all(&Self::frame(&[], 0x8));
            let _ = stdin.flush();
        }
    }
}

fn find_subslice(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    haystack.windows(needle.len()).position(|window| window == needle)
}
