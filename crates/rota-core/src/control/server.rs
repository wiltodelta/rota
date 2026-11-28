use std::io::{Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::PermissionsExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use rota_platform::Logger;
use serde_json::{Value, json};
use uuid::Uuid;

use crate::control::ControlError;
use crate::model::serde_ext::to_sorted_compact_string;
use crate::rpc::disable_sigpipe;
use crate::scheduler::Scheduler;
use crate::storage::StorageLocation;

pub type ControlHandler = Arc<dyn Fn(&str, Value) -> Result<Value, ControlError> + Send + Sync + 'static>;

const MAX_LINE_BYTES: usize = 32 * 1024 * 1024;

/// Unix domain socket server (`0600`, `SO_NOSIGPIPE`, 32 MiB message cap) for `rota` and MCP.
pub struct ControlServer;

impl ControlServer {
    const LOG: Logger = Logger::new("control");

    pub fn standard_socket() -> PathBuf {
        StorageLocation::standard().socket_path()
    }

    pub fn for_scheduler(
        socket: PathBuf,
        scheduler: Arc<Scheduler>,
    ) -> Result<ControlServerHandle, ControlError> {
        Self::start(
            socket,
            Arc::new(move |method, params| scheduler.control_request(method, params)),
        )
    }

    pub fn start(socket: PathBuf, handler: ControlHandler) -> Result<ControlServerHandle, ControlError> {
        validate_socket_path(&socket)?;
        if let Some(parent) = socket.parent() {
            std::fs::create_dir_all(parent)
                .map_err(|e| ControlError::new(format!("Could not create socket folder: {e}")))?;
        }
        let _ = std::fs::remove_file(&socket);
        let listener = UnixListener::bind(&socket)
            .map_err(|e| ControlError::new(format!("Could not listen on {}: {e}.", socket.display())))?;
        std::fs::set_permissions(&socket, std::fs::Permissions::from_mode(0o600)).map_err(|e| {
            let _ = std::fs::remove_file(&socket);
            ControlError::new(format!("Could not secure {}: {e}.", socket.display()))
        })?;
        Self::LOG.info(&format!("Listening on {}", socket.display()));

        let stopped = Arc::new(AtomicBool::new(false));
        let active_streams: Arc<Mutex<Vec<UnixStream>>> = Arc::new(Mutex::new(Vec::new()));
        let stopped_flag = Arc::clone(&stopped);
        let streams_ref = Arc::clone(&active_streams);
        let listener_for_accept = listener
            .try_clone()
            .map_err(|e| ControlError::new(format!("Could not clone listener: {e}")))?;

        std::thread::Builder::new()
            .name("rota-control-accept".to_string())
            .spawn(move || {
                for incoming in listener_for_accept.incoming() {
                    if stopped_flag.load(Ordering::Acquire) {
                        break;
                    }
                    let Ok(stream) = incoming else {
                        if stopped_flag.load(Ordering::Acquire) {
                            break;
                        }
                        continue;
                    };
                    disable_sigpipe(&stream);
                    if let Ok(cloned) = stream.try_clone() {
                        streams_ref.lock().unwrap().push(cloned);
                    }
                    let h = Arc::clone(&handler);
                    let s_flag = Arc::clone(&stopped_flag);
                    std::thread::spawn(move || Self::serve_connection(stream, h, s_flag));
                }
            })
            .map_err(|e| ControlError::new(format!("Could not spawn control server: {e}")))?;

        Ok(ControlServerHandle {
            inner: Arc::new(HandleInner {
                socket,
                listener,
                stopped,
                active_streams,
            }),
        })
    }

    fn serve_connection(mut stream: UnixStream, handler: ControlHandler, stopped: Arc<AtomicBool>) {
        let mut buffer = Vec::new();
        let mut chunk = [0u8; 65_536];
        loop {
            if stopped.load(Ordering::Acquire) {
                break;
            }
            let count = match stream.read(&mut chunk) {
                Ok(0) => break,
                Ok(n) => n,
                Err(err) if err.kind() == std::io::ErrorKind::Interrupted => continue,
                Err(_) => break,
            };
            buffer.extend_from_slice(&chunk[..count]);
            if buffer.len() > MAX_LINE_BYTES {
                break;
            }
            while let Some(nl) = buffer.iter().position(|&b| b == b'\n') {
                let mut line: Vec<u8> = buffer.drain(..=nl).take(nl).collect();
                if line.last() == Some(&b'\r') {
                    line.pop();
                }
                if !Self::handle_line(&line, &mut stream, &handler) {
                    return;
                }
            }
        }
    }

    fn handle_line(line: &[u8], stream: &mut UnixStream, handler: &ControlHandler) -> bool {
        let Ok(req) = serde_json::from_slice::<Value>(line) else {
            return write_reply(
                stream,
                &json!({"error": {"message": "Not a JSON request with a method."}}),
            );
        };
        let Some(obj) = req.as_object() else {
            return write_reply(
                stream,
                &json!({"error": {"message": "Not a JSON request with a method."}}),
            );
        };
        let Some(method) = obj.get("method").and_then(Value::as_str) else {
            return write_reply(
                stream,
                &json!({"error": {"message": "Not a JSON request with a method."}}),
            );
        };
        let id = obj.get("id").cloned().unwrap_or(Value::Null);
        let params = obj
            .get("params")
            .filter(|v| v.is_object())
            .cloned()
            .unwrap_or_else(|| json!({}));

        let result = handler(method, params);
        let status_note = match &result {
            Ok(_) => "ok",
            Err(err) => err.message.as_str(),
        };
        Self::LOG.info(&format!("{method}: {status_note}"));

        let response = match result {
            Ok(val) => json!({"id": id, "result": val}),
            Err(err) => json!({"id": id, "error": {"message": err.message}}),
        };
        write_reply(stream, &response)
    }
}

fn write_reply(stream: &mut UnixStream, response: &Value) -> bool {
    let Ok(mut payload) = to_sorted_compact_string(response).map(String::into_bytes) else {
        return false;
    };
    payload.push(b'\n');
    stream.write_all(&payload).is_ok() && stream.flush().is_ok()
}

fn validate_socket_path(socket: &Path) -> Result<(), ControlError> {
    let raw = socket.to_string_lossy();
    let max_len = std::mem::size_of::<libc::sockaddr_un>() - 2;
    if raw.len() >= max_len {
        return Err(ControlError::new(format!("The socket path is too long: {raw}")));
    }
    Ok(())
}

struct HandleInner {
    socket: PathBuf,
    listener: UnixListener,
    stopped: Arc<AtomicBool>,
    active_streams: Arc<Mutex<Vec<UnixStream>>>,
}

#[derive(Clone)]
pub struct ControlServerHandle {
    inner: Arc<HandleInner>,
}

impl ControlServerHandle {
    pub fn socket_path(&self) -> &Path {
        &self.inner.socket
    }

    pub fn stop(&self) {
        if self.inner.stopped.swap(true, Ordering::AcqRel) {
            return;
        }
        unsafe {
            let _ = libc::shutdown(self.inner.listener.as_raw_fd(), libc::SHUT_RDWR);
        }
        // Wake the blocking accept() call if macOS ignores shutdown on an unconnected Unix listener.
        let _ = UnixStream::connect(&self.inner.socket);
        for stream in self.inner.active_streams.lock().unwrap().drain(..) {
            let _ = stream.shutdown(std::net::Shutdown::Both);
        }
        let _ = std::fs::remove_file(&self.inner.socket);
    }
}

impl Drop for HandleInner {
    fn drop(&mut self) {
        if !self.stopped.swap(true, Ordering::AcqRel) {
            unsafe {
                let _ = libc::shutdown(self.listener.as_raw_fd(), libc::SHUT_RDWR);
            }
            let _ = UnixStream::connect(&self.socket);
            for stream in self.active_streams.lock().unwrap().drain(..) {
                let _ = stream.shutdown(std::net::Shutdown::Both);
            }
            let _ = std::fs::remove_file(&self.socket);
        }
    }
}

/// Client side of Rota's control socket: one JSON line out, one JSON line back.
pub struct ControlClient;

impl ControlClient {
    pub fn call(
        method: &str,
        params: Value,
        socket: &Path,
        timeout: Duration,
    ) -> Result<Value, ControlError> {
        validate_socket_path(socket)?;
        let mut stream = UnixStream::connect(socket).map_err(|_| ControlError::not_running())?;
        disable_sigpipe(&stream);
        let _ = stream.set_read_timeout(Some(timeout));
        let _ = stream.set_write_timeout(Some(timeout));

        let request_id = crate::model::serde_ext::uppercase_uuid(Uuid::new_v4());
        let mut payload = serde_json::to_vec(&json!({
            "id": request_id,
            "method": method,
            "params": params,
        }))
        .map_err(|e| ControlError::new(e.to_string()))?;
        payload.push(b'\n');

        stream
            .write_all(&payload)
            .map_err(|_| ControlError::new("Could not send the request to Rota."))?;
        let _ = stream.flush();

        let mut buffer = Vec::new();
        let mut chunk = [0u8; 65_536];
        while !buffer.contains(&b'\n') {
            match stream.read(&mut chunk) {
                Ok(0) => {
                    return Err(ControlError::new(format!(
                        "Rota did not answer within {} s.",
                        timeout.as_secs()
                    )));
                }
                Ok(n) => {
                    buffer.extend_from_slice(&chunk[..n]);
                    if buffer.len() > MAX_LINE_BYTES {
                        return Err(ControlError::new("Rota's answer exceeded 32 MiB."));
                    }
                }
                Err(err) if err.kind() == std::io::ErrorKind::Interrupted => continue,
                Err(_) => {
                    return Err(ControlError::new(format!(
                        "Rota did not answer within {} s.",
                        timeout.as_secs()
                    )));
                }
            }
        }
        let nl = buffer.iter().position(|&b| b == b'\n').unwrap_or(buffer.len());
        let response: Value = serde_json::from_slice(&buffer[..nl])
            .map_err(|_| ControlError::new("Rota's answer was not JSON."))?;
        if response.get("id").and_then(Value::as_str) != Some(request_id.as_str()) {
            return Err(ControlError::new(
                "Rota returned an answer for a different request.",
            ));
        }
        if let Some(err_obj) = response.get("error").and_then(Value::as_object) {
            let msg = err_obj
                .get("message")
                .and_then(Value::as_str)
                .unwrap_or("Rota refused the request.");
            return Err(ControlError::new(msg));
        }
        Ok(response.get("result").cloned().unwrap_or(Value::Null))
    }
}
