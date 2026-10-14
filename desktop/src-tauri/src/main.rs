// Release builds are tray-only: no console window.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod chime;
mod toast;

use grasp_core::{cert, Config, Ui, UiEvent};
use tauri::{
    menu::{CheckMenuItem, Menu, MenuItem, PredefinedMenuItem},
    tray::TrayIconBuilder,
    Manager,
};
use tauri_plugin_autostart::{MacosLauncher, ManagerExt};

const DEFAULT_PORT: u16 = 53317;

fn main() {
    tauri::Builder::default()
        // A second launch would fight over the port; just do nothing.
        .plugin(tauri_plugin_single_instance::init(|_app, _argv, _cwd| {}))
        .plugin(tauri_plugin_autostart::init(MacosLauncher::LaunchAgent, None))
        .invoke_handler(tauri::generate_handler![
            toast::respond,
            toast::toast_show,
            toast::toast_hidden,
            toast::toast_resize,
            toast::reveal,
        ])
        .setup(|app| {
            let handle = app.handle().clone();
            let ui = toast::TauriUi::new(handle.clone());
            app.manage(ui.clone());

            let downloads = app.path().download_dir()?;
            let port = std::env::var("GRASP_PORT").ok().and_then(|p| p.parse().ok()).unwrap_or(DEFAULT_PORT);
            let alias = std::env::var("COMPUTERNAME").unwrap_or_else(|_| "Grasp PC".into());

            // Tray: the only chrome Grasp has.
            let open = MenuItem::with_id(app, "open", "Open Downloads", true, None::<&str>)?;
            let login = CheckMenuItem::with_id(
                app,
                "login",
                "Launch at login",
                true,
                app.autolaunch().is_enabled().unwrap_or(false),
                None::<&str>,
            )?;
            let quit = MenuItem::with_id(app, "quit", "Quit Grasp", true, None::<&str>)?;
            let menu = Menu::with_items(app, &[&open, &login, &PredefinedMenuItem::separator(app)?, &quit])?;

            let tray_dir = downloads.clone();
            let mut tray = TrayIconBuilder::with_id("grasp")
                .tooltip(format!("Grasp: receiving as {alias}"))
                .menu(&menu)
                .on_menu_event(move |app, event| match event.id().as_ref() {
                    "open" => toast::open_in_explorer(tray_dir.clone()),
                    "login" => {
                        let launch = app.autolaunch();
                        let _ = if launch.is_enabled().unwrap_or(false) { launch.disable() } else { launch.enable() };
                    }
                    "quit" => app.exit(0),
                    _ => {}
                });
            if let Some(icon) = app.default_window_icon() {
                tray = tray.icon(icon.clone());
            }
            tray.build(app)?;

            // The receiver.
            let identity_dir = app.path().app_data_dir()?.join("identity");
            tauri::async_runtime::spawn(async move {
                let result = async {
                    let identity = cert::load_or_create(&identity_dir)?;
                    grasp_core::serve(Config { port, inbox: downloads, alias }, identity, ui.clone()).await
                }
                .await;
                if let Err(e) = result {
                    ui.event(UiEvent::Failed { id: "server".into(), reason: friendly(&e, port) });
                }
            });
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
