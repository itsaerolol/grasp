//! The tray menu: a small frameless window in the same always-dark style as the toast, opened from the
//! tray icon and closed when it loses focus. It holds the few settings Grasp has (save folder,
//! auto-accept for paired iPhones, launch at login), the pairing code, the paired-device list, and
//! sending to the iPhone (send files, send clipboard, what's waiting for the phone).

use std::{
    net::UdpSocket,
    path::PathBuf,
    sync::{Arc, Mutex},
};

use grasp_core::{Handle, PairedDevice, PairingWindow};
use serde::{Deserialize, Serialize};
use tauri::{
    AppHandle, Emitter, LogicalSize, Manager, PhysicalPosition, PhysicalRect, Position, Size, State, WebviewWindow,
};
use tauri_plugin_autostart::ManagerExt;
use tauri_plugin_dialog::DialogExt;

use crate::toast::open_in_explorer;

const WIDTH: f64 = 340.0;

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
pub fn open_save_dir(app: AppHandle, shell: State<'_, Arc<Shell>>) {
    open_in_explorer(shell.save_dir());
    hide(&app);
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
        let _ = w.set_size(LogicalSize::new(WIDTH, height.clamp(120.0, 900.0)));
        if let Some(anchor) = *ANCHOR.lock().unwrap() {
            place(&w, anchor);
        }
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

/// Where the tray icon was clicked, so a resize can re-place the window against the same icon.
static ANCHOR: Mutex<Option<PhysicalRect<i32, u32>>> = Mutex::new(None);

fn to_physical(rect: &tauri::Rect, scale: f64) -> PhysicalRect<i32, u32> {
    let position = match rect.position {
        Position::Physical(p) => p,
        Position::Logical(l) => l.to_physical(scale),
    };
    let size = match rect.size {
        Size::Physical(s) => s,
        Size::Logical(l) => l.to_physical(scale),
    };
    PhysicalRect { position, size }
}

/// Opens the menu next to the tray icon, or closes it if it is already showing.
pub fn toggle(app: &AppHandle, tray_rect: &tauri::Rect) {
    let Some(w) = window(app) else { return };
    if w.is_visible().unwrap_or(false) {
        let _ = w.hide();
        return;
    }
    let scale = w.scale_factor().unwrap_or(1.0);
    let anchor = to_physical(tray_rect, scale);
    *ANCHOR.lock().unwrap() = Some(anchor);
    place(&w, anchor);
    let _ = app.emit_to("menu", "menu-open", ());
    let _ = w.show();
    let _ = w.set_focus();
}

/// Sits against the taskbar edge the tray lives on, horizontally centred on the icon, kept on screen.
fn place(w: &WebviewWindow, anchor: PhysicalRect<i32, u32>) {
    let monitor = w
        .monitor_from_point(anchor.position.x as f64, anchor.position.y as f64)
        .ok()
        .flatten()
        .or_else(|| w.primary_monitor().ok().flatten());
    let (Some(monitor), Ok(size)) = (monitor, w.outer_size()) else { return };
    let work = monitor.work_area();
    let gap = (8.0 * monitor.scale_factor()) as i32;
    let (wx, wy) = (work.position.x, work.position.y);
    let (ww, wh) = (work.size.width as i32, work.size.height as i32);
    let (w_w, w_h) = (size.width as i32, size.height as i32);

    let icon_cx = anchor.position.x + anchor.size.width as i32 / 2;
    let x = (icon_cx - w_w / 2).clamp(wx + gap, wx + ww - w_w - gap);
    // Taskbar at the top: the icon sits above the work area, so open downward. Otherwise open upward.
    let y = if anchor.position.y < wy { wy + gap } else { wy + wh - w_h - gap };
    let _ = w.set_position(PhysicalPosition::new(x, y));
}
