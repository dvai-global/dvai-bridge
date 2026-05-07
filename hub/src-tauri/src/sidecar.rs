//! Node sidecar manager.
//!
//! The peer-mode runtime is a TypeScript module (`hub/peer-mode/`). Rather
//! than rewriting it in Rust, the Tauri shell spawns a Node child process
//! that loads the compiled JS, owns the HTTP server, and answers
//! JSON-RPC over stdio.
//!
//! Wire format — newline-delimited JSON, request/response/notification
//! shape borrowed from JSON-RPC 2.0 (without the strict `jsonrpc: "2.0"`
//! field, since it's a single-process bus):
//!
//!   request:      { "id": "uuid", "method": "get_status", "params": {} }
//!   response:     { "id": "uuid", "result": { ... } }    OR   { "id": "uuid", "error": { ... } }
//!   notification: { "method": "pairing-request", "params": { ... } }
//!
//! The frontend never speaks to the sidecar directly — Tauri commands
//! in `ipc.rs` translate frontend `invoke()` calls into stdio requests
//! and return the response.

use std::collections::HashMap;
use std::process::Stdio;
use std::sync::Arc;

use serde::{Deserialize, Serialize};
use serde_json::Value;
use tauri::{AppHandle, Emitter, Manager};
use tauri_plugin_notification::NotificationExt;
use thiserror::Error;
use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, ChildStdin, Command};
use tokio::sync::{oneshot, Mutex};

#[derive(Error, Debug)]
pub enum SidecarError {
    #[error("sidecar not running")]
    NotRunning,
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),
    #[error("json error: {0}")]
    Json(#[from] serde_json::Error),
    #[error("sidecar returned error: {0}")]
    Remote(String),
    #[error("sidecar response timeout")]
    Timeout,
}

#[derive(Debug, Serialize, Deserialize)]
struct JsonRpcRequest<'a> {
    id: String,
    method: &'a str,
    params: Value,
}

#[derive(Debug, Deserialize)]
struct JsonRpcEnvelope {
    id: Option<String>,
    method: Option<String>,
    params: Option<Value>,
    result: Option<Value>,
    error: Option<JsonRpcError>,
}

#[derive(Debug, Deserialize)]
struct JsonRpcError {
    code: i64,
    message: String,
}

type PendingMap = Arc<Mutex<HashMap<String, oneshot::Sender<Result<Value, SidecarError>>>>>;

pub struct SidecarManager {
    child: Option<Child>,
    stdin: Option<Arc<Mutex<ChildStdin>>>,
    pending: PendingMap,
}

impl SidecarManager {
    pub fn new() -> Self {
        Self {
            child: None,
            stdin: None,
            pending: Arc::new(Mutex::new(HashMap::new())),
        }
    }

    /// Spawn the bundled `dvai-hub-peer-mode` sidecar. On `tauri build`
    /// the binary lives next to the main exe; in dev we look for the
    /// compiled JS via `node hub/dist/peer-mode/server.js`.
    pub async fn spawn(&mut self, app: &AppHandle) -> Result<(), SidecarError> {
        if self.child.is_some() {
            return Ok(());
        }

        // Resolve sidecar path. In production, Tauri's `externalBin`
        // bundling places the binary at the resource path. In dev, we
        // run the JS directly via the `node` interpreter.
        let resource_path = app
            .path()
            .resource_dir()
            .map_err(|e| SidecarError::Io(std::io::Error::other(e.to_string())))?;

        // Production binary path
        let bundled = resource_path.join("binaries").join(if cfg!(target_os = "windows") {
            "dvai-hub-peer-mode.exe"
        } else {
            "dvai-hub-peer-mode"
        });

        let mut cmd = if bundled.exists() {
            let mut c = Command::new(&bundled);
            c.stdin(Stdio::piped()).stdout(Stdio::piped()).stderr(Stdio::piped());
            c
        } else {
            // Dev path — run the built sidecar JS via the system Node.
            //
            // CARGO_MANIFEST_DIR is the absolute path to `hub/src-tauri`
            // at compile time. From there, `../dist/peer-mode/server.js`
            // is the output of `pnpm build:peer-mode`. Override with
            // DVAI_HUB_SIDECAR_JS at runtime if needed (e.g. for
            // packaged installs that ship JS rather than a binary).
            let sidecar_js = std::env::var("DVAI_HUB_SIDECAR_JS").unwrap_or_else(|_| {
                let manifest_dir = env!("CARGO_MANIFEST_DIR");
                std::path::Path::new(manifest_dir)
                    .join("..")
                    .join("dist")
                    .join("peer-mode")
                    .join("server.js")
                    .to_string_lossy()
                    .into_owned()
            });
            let mut c = Command::new("node");
            c.arg(&sidecar_js)
                .stdin(Stdio::piped())
                .stdout(Stdio::piped())
                .stderr(Stdio::piped());
            c
        };

        log::info!("spawning peer-mode sidecar: {cmd:?}");
        let mut child = cmd.spawn()?;
        let stdout = child.stdout.take().ok_or_else(|| {
            SidecarError::Io(std::io::Error::other("no stdout on sidecar child"))
        })?;
        let stderr = child.stderr.take().ok_or_else(|| {
            SidecarError::Io(std::io::Error::other("no stderr on sidecar child"))
        })?;
        let stdin = child.stdin.take().ok_or_else(|| {
            SidecarError::Io(std::io::Error::other("no stdin on sidecar child"))
        })?;

        self.stdin = Some(Arc::new(Mutex::new(stdin)));
        self.child = Some(child);

        // Spawn a stdout reader that demuxes responses + emits notifications.
        let pending = self.pending.clone();
        let app_handle = app.clone();
        tokio::spawn(async move {
            let mut reader = BufReader::new(stdout).lines();
            while let Ok(Some(line)) = reader.next_line().await {
                if line.trim().is_empty() {
                    continue;
                }
                let env: JsonRpcEnvelope = match serde_json::from_str(&line) {
                    Ok(v) => v,
                    Err(e) => {
                        log::warn!("sidecar emitted non-JSON line: {line:?} ({e})");
                        continue;
                    }
                };
                match (env.id, env.method) {
                    // Response to a pending request.
                    (Some(id), None) => {
                        let mut guard = pending.lock().await;
                        if let Some(tx) = guard.remove(&id) {
                            let result = if let Some(err) = env.error {
                                Err(SidecarError::Remote(format!(
                                    "({}) {}",
                                    err.code, err.message
                                )))
                            } else {
                                Ok(env.result.unwrap_or(Value::Null))
                            };
                            let _ = tx.send(result);
                        }
                    }
                    // Notification — forward to the frontend over Tauri events.
                    (None, Some(method)) => {
                        let payload = env.params.unwrap_or(Value::Null);
                        if let Err(e) = app_handle.emit(&method, payload.clone()) {
                            log::warn!("failed to emit notification {method}: {e}");
                        }
                        // Also fire a system notification on pairing-request
                        // so the user sees it when the dashboard window is hidden.
                        if method == "pairing-request" {
                            let device_name = payload
                                .get("request")
                                .and_then(|r| r.get("peerDeviceName"))
                                .and_then(|v| v.as_str())
                                .unwrap_or("a device")
                                .to_string();
                            let app_name = payload
                                .get("request")
                                .and_then(|r| r.get("appName"))
                                .and_then(|v| v.as_str())
                                .map(|s| s.to_string())
                                .or_else(|| {
                                    payload
                                        .get("request")
                                        .and_then(|r| r.get("appId"))
                                        .and_then(|v| v.as_str())
                                        .map(|s| s.to_string())
                                })
                                .unwrap_or_else(|| "an app".to_string());
                            let body =
                                format!("{device_name} wants to pair on behalf of {app_name}.");
                            if let Err(e) = app_handle
                                .notification()
                                .builder()
                                .title("DVAI Hub — pairing request")
                                .body(body)
                                .show()
                            {
                                log::warn!("system notification failed: {e}");
                            }
                        }
                    }
                    _ => {
                        log::warn!("unexpected sidecar message: {line}");
                    }
                }
            }
            log::info!("sidecar stdout closed");
        });

        // Spawn a stderr drainer so the child can't block on a full pipe.
        tokio::spawn(async move {
            let mut reader = BufReader::new(stderr).lines();
            while let Ok(Some(line)) = reader.next_line().await {
                log::warn!("[sidecar:stderr] {line}");
            }
        });

        Ok(())
    }

    pub async fn shutdown(&mut self) -> Result<(), SidecarError> {
        if let Some(mut child) = self.child.take() {
            let _ = child.start_kill();
            let _ = child.wait().await;
        }
        self.stdin = None;
        self.pending.lock().await.clear();
        Ok(())
    }

    /// Send a JSON-RPC request and await the response.
    pub async fn call(&self, method: &str, params: Value) -> Result<Value, SidecarError> {
        let stdin = self.stdin.as_ref().ok_or(SidecarError::NotRunning)?.clone();
        let id = uuid_v4_simple();
        let (tx, rx) = oneshot::channel();
        {
            let mut pending = self.pending.lock().await;
            pending.insert(id.clone(), tx);
        }
        let req = JsonRpcRequest {
            id: id.clone(),
            method,
            params,
        };
        let line = serde_json::to_string(&req)? + "\n";
        {
            let mut guard = stdin.lock().await;
            guard.write_all(line.as_bytes()).await?;
            guard.flush().await?;
        }
        // 30-second timeout — peer-mode operations are local + cheap.
        match tokio::time::timeout(std::time::Duration::from_secs(30), rx).await {
            Ok(Ok(result)) => result,
            Ok(Err(_)) => Err(SidecarError::Remote("response channel dropped".into())),
            Err(_) => {
                // Time out: drop the pending entry to free memory.
                self.pending.lock().await.remove(&id);
                Err(SidecarError::Timeout)
            }
        }
    }
}

/// Tiny RFC4122-v4-shaped string generator (lower-case hex with dashes).
/// We don't need cryptographic uniqueness — JSON-RPC ids only need to be
/// unique for the in-flight set, which is bounded by request concurrency.
fn uuid_v4_simple() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    static COUNTER: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    let n = COUNTER.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
    format!("{:016x}-{:08x}-{:08x}", now as u64, (now >> 64) as u64, n)
}
