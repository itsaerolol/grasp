// Release builds are tray-only: no console window.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod chime;
mod menu;
mod toast;

use std::sync::{Arc, Mutex};

use grasp_core::{cert, Config, Ui, UiEvent};
use tauri::{
    tray::{MouseButtonState, TrayIconBuilder, TrayIconEvent},
    Manager, WindowEvent,
};
use tauri_plugin_autostart::MacosLauncher;

use crate::menu::{Settings, Shell};

const DEFAULT_PORT: u16 = 53317;

fn main() {
    tauri::Builder::default()
        // A second launch would fight over the port; just do nothing.
        .plugin(tauri_plugin_single_instance::init(|_app, _argv, _cwd| {}))
        .plugin(tauri_plugin_autostart::init(MacosLauncher::LaunchAgent, None))
        .plugin(tauri_plugin_dialog::init())
        .invoke_handler(tauri::generate_handler![
            toast::respond,
            toast::toast_show,
            toast::toast_hidden,
            toast::toast_resize,
            toast::reveal,
            menu::menu_state,
            menu::set_auto_accept,
            menu::choose_save_dir,
            menu::open_save_dir,
            menu::set_launch_at_login,
            menu::start_pairing,
            menu::cancel_pairing,
            menu::unpair,
            menu::quit,
            menu::menu_resize,
            menu::menu_hide,
        ])
        .setup(|app| {
            let ui = toast::TauriUi::new(app.handle().clone());
            app.manage(ui.clone());

            let data = app.path().app_data_dir()?;
            let downloads = app.path().download_dir()?;
            let settings_path = data.join("settings.json");
            let settings = Settings::load(&settings_path);
            let port = std::env::var("GRASP_PORT").ok().and_then(|p| p.parse().ok()).unwrap_or(DEFAULT_PORT);
            let alias = std::env::var("COMPUTERNAME").unwrap_or_else(|_| "Grasp PC".into());
            let inbox = settings.save_dir.clone().unwrap_or_else(|| downloads.clone());

            // The receiver. Built here so the menu gets a handle; it runs on the async runtime.
            let identity = cert::load_or_create(&data.join("identity"))?;
            let fingerprint = identity.fingerprint.clone();
            let cfg = Config {
                port,
                inbox,
                alias: alias.clone(),
                state: data.join("pairing"),
                auto_accept_paired: settings.auto_accept_paired,
            };
            let (handle, server) = match grasp_core::build(cfg, identity, ui.clone()) {
                Ok((h, s)) => (Some(h), Some(s)),
                Err(e) => {
                    ui.event(UiEvent::Failed { id: "server".into(), reason: friendly(&e, port) });
                    (None, None)
                }
            };
            let shell = Arc::new(Shell {
                handle,
                settings: Mutex::new(settings),
                settings_path,
                downloads,
                alias: alias.clone(),
                port,
                fingerprint,
                server_error: Mutex::new(None),
            });
            app.manage(shell.clone());
            if let Some(server) = server {
                let ui = ui.clone();
                tauri::async_runtime::spawn(async move {
                    if let Err(e) = server.await {
                        let reason = friendly(&e, port);
                        *shell.server_error.lock().unwrap() = Some(reason.clone());
                        ui.event(UiEvent::Failed { id: "server".into(), reason });
                    }
                });
            }

            // Tray: left or right click opens the menu window (no native menu).
            let mut tray = TrayIconBuilder::with_id("grasp")
                .tooltip(format!("Grasp: receiving as {alias}"))
                .show_menu_on_left_click(false)
                .on_tray_icon_event(|tray, event| {
                    if let TrayIconEvent::Click { rect, button_state: MouseButtonState::Up, .. } = event {
                        menu::toggle(tray.app_handle(), &rect);
                    }
                });
            if let Some(icon) = app.default_window_icon() {
                tray = tray.icon(icon.clone());
            }
            tray.build(app)?;

            // The menu behaves like a popup: it goes away when you click elsewhere.
            if let Some(w) = app.get_webview_window("menu") {
                let w2 = w.clone();
                w.on_window_event(move |e| {
                    if let WindowEvent::Focused(false) = e {
                        let _ = w2.hide();
                    }
                });
            }
            Ok(())
        })
        .run(tauri::generate_context!())
        .expect("Grasp failed to start");
}

/// One short, actionable line for the toast.
fn friendly(e: &anyhow::Error, port: u16) -> String {
    let msg = format!("{e:#}");
    if msg.contains("10048") || msg.to_lowercase().contains("address already in use") {
        format!("Port {port} is busy. Quit LocalSend (or another Grasp) and relaunch.")
    } else {
        format!("Grasp can't receive: {msg}")
    }
}
