//! System-tray icon + menu.
//!
//! The Hub lives in the tray as long as the user is signed in. Clicking
//! the icon (or the "Open Dashboard" menu item) shows the main window.
//! "Pause" / "Resume" stops the peer-mode HTTP server without quitting
//! the app — pairings stay; LAN advertising goes silent.

use tauri::{
    menu::{Menu, MenuItem, PredefinedMenuItem},
    tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent},
    AppHandle, Manager,
};

pub fn install_tray(app: &mut tauri::App) -> tauri::Result<()> {
    let handle = app.handle();

    let open_item = MenuItem::with_id(handle, "open", "Open Dashboard", true, None::<&str>)?;
    let pause_item = MenuItem::with_id(handle, "pause", "Pause peer-mode", true, None::<&str>)?;
    let resume_item =
        MenuItem::with_id(handle, "resume", "Resume peer-mode", true, None::<&str>)?;
    let separator = PredefinedMenuItem::separator(handle)?;
    let quit_item = MenuItem::with_id(handle, "quit", "Quit DVAI Hub", true, None::<&str>)?;

    let menu = Menu::with_items(
        handle,
        &[&open_item, &pause_item, &resume_item, &separator, &quit_item],
    )?;

    // Use the app's bundled icon (icon.ico on Windows, icon.icns on macOS,
    // icon.png on Linux). Without this Tauri 2 doesn't auto-attach an icon
    // to the tray — the slot renders blank.
    let icon = handle
        .default_window_icon()
        .cloned()
        .ok_or_else(|| tauri::Error::AssetNotFound("default window icon".into()))?;

    let tray = TrayIconBuilder::with_id("dvai-hub-tray")
        .icon(icon)
        .menu(&menu)
        .show_menu_on_left_click(false)
        .tooltip("DVAI Hub")
        .on_menu_event(move |app, event| {
            handle_menu_event(app, event.id().as_ref());
        })
        .on_tray_icon_event(|tray, event| {
            // Single left-click → toggle main window.
            if let TrayIconEvent::Click {
                button: MouseButton::Left,
                button_state: MouseButtonState::Up,
                ..
            } = event
            {
                let app = tray.app_handle();
                if let Some(window) = app.get_webview_window("main") {
                    let visible = window.is_visible().unwrap_or(false);
                    if visible {
                        let _ = window.hide();
                    } else {
                        let _ = window.show();
                        let _ = window.set_focus();
                    }
                }
            }
        })
        .build(handle)?;

    // Tray instance held by Tauri — drop is fine.
    let _ = tray;
    Ok(())
}

fn handle_menu_event(app: &AppHandle, id: &str) {
    match id {
        "open" => {
            if let Some(window) = app.get_webview_window("main") {
                let _ = window.show();
                let _ = window.set_focus();
                let _ = window.unminimize();
            }
        }
        "pause" => {
            // Forward to the sidecar — non-blocking emit; the dashboard reflects it.
            tauri::async_runtime::spawn(forward_command(app.clone(), "stop", serde_json::json!({})));
        }
        "resume" => {
            tauri::async_runtime::spawn(forward_command(app.clone(), "start", serde_json::json!({})));
        }
        "quit" => {
            // Hard exit — the lifecycle hook in lib.rs normally prevents exit;
            // explicit user request from the tray bypasses it.
            app.exit(0);
        }
        _ => {}
    }
}

async fn forward_command(app: AppHandle, method: &str, params: serde_json::Value) {
    use crate::AppState;
    let state = app.state::<AppState>();
    let sidecar = state.sidecar.lock().await;
    if let Err(e) = sidecar.call(method, params).await {
        log::warn!("tray forward {method} failed: {e}");
    }
}
