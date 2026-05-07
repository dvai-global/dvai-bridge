//! DVAI Hub — Tauri shell.
//!
//! Lifecycle:
//!   1. Single-instance lock: a second launch focuses the running window
//!      instead of spawning a parallel process.
//!   2. Spawn the Node sidecar that owns the peer-mode HTTP server +
//!      pairing/audit state. The sidecar speaks JSON-RPC over stdio.
//!   3. Build the system tray + main window. The window starts hidden;
//!      the user opens the dashboard via tray click.
//!   4. Tauri commands (in `ipc`) bridge frontend `invoke()` calls to
//!      sidecar JSON-RPC requests.
//!   5. Notifications fire when the sidecar emits a `pairing-request`
//!      event the frontend hasn't yet been opened to display.

mod ipc;
mod sidecar;
mod tray;

use std::sync::Arc;
use tauri::Manager;
use tokio::sync::Mutex;

use crate::sidecar::SidecarManager;

/// Shared application state available to every Tauri command.
pub struct AppState {
    pub sidecar: Arc<Mutex<SidecarManager>>,
}

/// Entry point — wired up by the binary `main.rs`.
pub fn run() {
    env_logger::Builder::from_env(env_logger::Env::default().default_filter_or("info")).init();
    log::info!("dvai-hub v{} starting up", env!("CARGO_PKG_VERSION"));

    let sidecar = Arc::new(Mutex::new(SidecarManager::new()));

    let builder = tauri::Builder::default()
        // Single-instance lock — second launch surfaces the existing window.
        .plugin(tauri_plugin_single_instance::init(|app, _argv, _cwd| {
            log::info!("second instance launched; bringing main window forward");
            if let Some(window) = app.get_webview_window("main") {
                let _ = window.show();
                let _ = window.set_focus();
                let _ = window.unminimize();
            }
        }))
        .plugin(tauri_plugin_notification::init())
        .plugin(tauri_plugin_autostart::init(
            tauri_plugin_autostart::MacosLauncher::LaunchAgent,
            None,
        ))
        .manage(AppState {
            sidecar: sidecar.clone(),
        })
        .setup(move |app| {
            // Build the tray icon + menu.
            tray::install_tray(app)?;

            // Spawn the Node sidecar in the background. The dashboard waits
            // on a `running` poll to know when peer-mode is ready.
            let sidecar_clone = sidecar.clone();
            let app_handle = app.handle().clone();
            tauri::async_runtime::spawn(async move {
                let mut mgr = sidecar_clone.lock().await;
                if let Err(e) = mgr.spawn(&app_handle).await {
                    log::error!("failed to spawn peer-mode sidecar: {e:?}");
                }
            });

            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            ipc::start_peer_mode,
            ipc::stop_peer_mode,
            ipc::get_status,
            ipc::get_pairings,
            ipc::revoke_pairing,
            ipc::get_engines,
            ipc::set_engine_enabled,
            ipc::respond_to_pairing,
            ipc::get_audit_log,
            ipc::invalidate_engine_cache,
        ])
        .build(tauri::generate_context!())
        .expect("error while building tauri application");

    builder.run(|_app_handle, event| {
        // Hold the app alive in the background when the window closes — the
        // tray icon stays visible and peer-mode keeps serving requests.
        //
        // Distinguish two ExitRequested sources:
        //   * code = None  → OS close signal (window X click, last-window
        //                    closed). Prevent exit so the Hub stays in tray.
        //   * code = Some  → explicit `app.exit(code)` call (tray Quit
        //                    menu, IPC shutdown). Honor the request — the
        //                    user genuinely wants the app down.
        if let tauri::RunEvent::ExitRequested { code, api, .. } = &event {
            if code.is_none() {
                api.prevent_exit();
            }
        }
    });
}
