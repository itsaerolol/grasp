//! The Grasp window: a normal window (dark title bar, taskbar button) in the same always-dark style as the
//! toast, opened from the tray icon. Closing it hides it back to the tray; Grasp keeps receiving until Quit.
//! It holds the few settings Grasp has (save folder, auto-accept for paired iPhones, launch at login), the
//! pairing code, the paired-device list, and sending to the iPhone (send files, send clipboard, what's waiting
//! for the phone).

use std::{
    net::UdpSocket,
    path::PathBuf,
    sync::{Arc, Mutex},
};

use grasp_core::{Handle, PairedDevice, PairingWindow};
use serde::{Deserialize, Serialize};
use tauri::{AppHandle, Emitter, LogicalSize, Manager, State, WebviewWindow};
use tauri_plugin_autostart::ManagerExt;
use tauri_plugin_dialog::DialogExt;

use crate::toast::open_in_explorer;

/// Content width; the height follows the content (`menu_resize`).
const WIDTH: f64 = 380.0;

#[derive(Serialize, Deserialize, Default, Clone)]
#[serde(rename_all = "camelCase")]
pub struct Settings {
    pub save_dir: Option<PathBuf>,
    pub auto_accept_paired: bool,
}

impl Settings {
    pub fn load(path: &PathBuf) -> Self {
        std::fs::read(path).ok().and_then(|b| serde_json::from_slice(&b).ok()).unwrap_or_default()
    }
    fn save(&self, path: &PathBuf) {
        if let Some(dir) = path.parent() {
            let _ = std::fs::create_dir_all(dir);
        }
        if let Ok(json) = serde_json::to_vec_pretty(self) {
            let _ = std::fs::write(path, json);
        }
    }
}

/// Everything the menu needs, owned by the Tauri app.
pub struct Shell {
    pub handle: Option<Handle>,
    pub settings: Mutex<Settings>,
    pub settings_path: PathBuf,
    pub downloads: PathBuf,
    pub alias: String,
    pub port: u16,
    pub fingerprint: String,
    pub server_error: Mutex<Option<String>>,
    /// Where copied images are saved as PNGs until the phone collects them.
    pub clips_dir: PathBuf,
}

impl Shell {
    pub fn save_dir(&self) -> PathBuf {
        self.settings.lock().unwrap().save_dir.clone().unwrap_or_else(|| self.downloads.clone())
    }
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct MenuState {
    alias: String,
    address: Option<String>,
    port: u16,
    fingerprint: String,
    receiving: bool,
    server_error: Option<String>,
    paired: Vec<PairedDevice>,
    pairing: Option<PairingWindow>,
    auto_accept: bool,
    save_dir: String,
    save_dir_name: String,
    launch_at_login: bool,
    /// Items queued for the iPhone that it hasn't collected yet.
    waiting: usize,
}

/// The LAN address other devices reach us on. Connecting a UDP socket sends nothing; it just asks
/// the OS which interface it would route through.
fn local_address() -> Option<String> {
    let s = UdpSocket::bind("0.0.0.0:0").ok()?;
    s.connect("8.8.8.8:80").ok()?;
    Some(s.local_addr().ok()?.ip().to_string())
}

#[tauri::command]
pub fn menu_state(app: AppHandle, shell: State<'_, Arc<Shell>>) -> MenuState {
    let dir = shell.save_dir();
    let handle = shell.handle.as_ref();
    MenuState {
        alias: shell.alias.clone(),
        address: local_address(),
        port: shell.port,
        fingerprint: shell.fingerprint.clone(),
        receiving: handle.is_some() && shell.server_error.lock().unwrap().is_none(),
        server_error: shell.server_error.lock().unwrap().clone(),
        paired: handle.map(|h| h.paired_devices()).unwrap_or_default(),
        pairing: handle.and_then(|h| h.pairing()),
        auto_accept: shell.settings.lock().unwrap().auto_accept_paired,
        save_dir_name: dir.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_else(|| dir.display().to_string()),
        save_dir: dir.display().to_string(),
        launch_at_login: app.autolaunch().is_enabled().unwrap_or(false),
        waiting: handle.map(|h| h.outbox_len()).unwrap_or(0),
    }
}

#[tauri::command]
pub fn set_auto_accept(shell: State<'_, Arc<Shell>>, on: bool) {
    let mut s = shell.settings.lock().unwrap();
    s.auto_accept_paired = on;
    s.save(&shell.settings_path);
    if let Some(h) = &shell.handle {
        h.set_auto_accept_paired(on);
    }
}

/// Folder picker. Runs on a worker thread (async command), so the blocking dialog is fine.
#[tauri::command]
pub async fn choose_save_dir(app: AppHandle, shell: State<'_, Arc<Shell>>) -> Result<(), String> {
    let current = shell.save_dir();
    let picked = app.dialog().file().set_directory(&current).set_title("Save received files to").blocking_pick_folder();
    let Some(dir) = picked.and_then(|p| p.into_path().ok()) else { return Ok(()) };
    let mut s = shell.settings.lock().unwrap();
    s.save_dir = Some(dir.clone());
    s.save(&shell.settings_path);
    if let Some(h) = &shell.handle {
        h.set_inbox(dir);
    }
    Ok(())
}

#[tauri::command]
pub fn open_save_dir(shell: State<'_, Arc<Shell>>) {
    open_in_explorer(shell.save_dir());
}

#[tauri::command]
pub fn set_launch_at_login(app: AppHandle, on: bool) {
    let launch = app.autolaunch();
    let _ = if on { launch.enable() } else { launch.disable() };
}

#[tauri::command]
pub fn start_pairing(shell: State<'_, Arc<Shell>>) -> Option<PairingWindow> {
    shell.handle.as_ref().map(|h| h.start_pairing())
}

#[tauri::command]
pub fn cancel_pairing(shell: State<'_, Arc<Shell>>) {
    if let Some(h) = &shell.handle {
        h.cancel_pairing();
    }
}

#[tauri::command]
pub fn unpair(shell: State<'_, Arc<Shell>>, fingerprint: String) {
    if let Some(h) = &shell.handle {
        h.unpair(&fingerprint);
    }
}

#[tauri::command]
pub fn quit(app: AppHandle) {
    app.exit(0);
}

#[tauri::command]
pub fn menu_resize(app: AppHandle, height: f64) {
    if let Some(w) = window(&app) {
        let _ = w.set_size(LogicalSize::new(WIDTH, height.clamp(200.0, 900.0)));
    }
}

#[tauri::command]
pub fn menu_hide(app: AppHandle) {
    hide(&app);
}

fn window(app: &AppHandle) -> Option<WebviewWindow> {
    app.get_webview_window("menu")
}

pub fn hide(app: &AppHandle) {
    if let Some(w) = window(app) {
        let _ = w.hide();
    }
}

/// The tray icon brings the window up (restored and in front). The window's own X only hides it again.
pub fn open(app: &AppHandle) {
    let Some(w) = window(app) else { return };
    let _ = app.emit_to("menu", "menu-open", ());
    let _ = w.unminimize();
    let _ = w.show();
    let _ = w.set_focus();
}
