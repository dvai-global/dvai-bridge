//! Tauri commands — the bridge between the dashboard frontend and the
//! Node sidecar.
//!
//! Every command:
//!   1. Locks the sidecar manager.
//!   2. Sends the corresponding JSON-RPC request over stdio.
//!   3. Translates the response (or error) back to the frontend.

use serde_json::{json, Value};
use tauri::State;

use crate::sidecar::SidecarError;
use crate::AppState;

/// Helper — call into the sidecar with the given method + params and
/// surface a stringified error to the frontend on failure.
async fn call(
    state: &State<'_, AppState>,
    method: &str,
    params: Value,
) -> Result<Value, String> {
    let sidecar = state.sidecar.lock().await;
    sidecar.call(method, params).await.map_err(|e: SidecarError| e.to_string())
}

#[tauri::command]
pub async fn start_peer_mode(state: State<'_, AppState>) -> Result<Value, String> {
    call(&state, "start", json!({})).await
}

#[tauri::command]
pub async fn stop_peer_mode(state: State<'_, AppState>) -> Result<Value, String> {
    call(&state, "stop", json!({})).await
}

#[tauri::command]
pub async fn get_status(state: State<'_, AppState>) -> Result<Value, String> {
    call(&state, "get_status", json!({})).await
}

#[tauri::command]
pub async fn get_pairings(state: State<'_, AppState>) -> Result<Value, String> {
    call(&state, "get_pairings", json!({})).await
}

#[tauri::command]
pub async fn revoke_pairing(
    state: State<'_, AppState>,
    app_id: String,
    peer_device_id: String,
) -> Result<Value, String> {
    call(
        &state,
        "revoke_pairing",
        json!({ "appId": app_id, "peerDeviceId": peer_device_id }),
    )
    .await
}

#[tauri::command]
pub async fn get_engines(state: State<'_, AppState>) -> Result<Value, String> {
    call(&state, "get_engines", json!({})).await
}

#[tauri::command]
pub async fn set_engine_enabled(
    state: State<'_, AppState>,
    name: String,
    enabled: bool,
) -> Result<Value, String> {
    call(
        &state,
        "set_engine_enabled",
        json!({ "name": name, "enabled": enabled }),
    )
    .await
}

#[tauri::command]
pub async fn respond_to_pairing(
    state: State<'_, AppState>,
    request_id: String,
    approved: bool,
) -> Result<Value, String> {
    call(
        &state,
        "respond_to_pairing",
        json!({ "requestId": request_id, "approved": approved }),
    )
    .await
}

#[tauri::command]
pub async fn get_audit_log(
    state: State<'_, AppState>,
    app_id: String,
    limit: Option<u32>,
) -> Result<Value, String> {
    call(
        &state,
        "get_audit_log",
        json!({ "appId": app_id, "limit": limit }),
    )
    .await
}

#[tauri::command]
pub async fn invalidate_engine_cache(
    state: State<'_, AppState>,
    name: Option<String>,
) -> Result<Value, String> {
    call(
        &state,
        "invalidate_engine_cache",
        json!({ "name": name }),
    )
    .await
}
