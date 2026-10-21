//! The toast: one frameless, non-focusable, always-on-top window pinned to the top right of the
//! primary monitor's work area. The page (ui/index.html) draws and animates everything; this module
//! only places the window, plays the chime, and carries the Accept / Reject decision back to the core.

use std::{
    collections::HashMap,
    path::PathBuf,
    sync::{Arc, Mutex},
};

use async_trait::async_trait;
use grasp_core::{IncomingRequest, Ui, UiEvent};
use tauri::{AppHandle, Emitter, LogicalSize, Manager, PhysicalPosition, State, WebviewWindow};
use tokio::sync::oneshot;

use crate::chime;

/// Card (360) plus the transparent shadow margin on each side (22) = 404. Keep in sync with `.stage`.
const WIDTH: f64 = 404.0;
/// The window overhangs the work area by this much so the visible card sits ~16px from the edge
/// even though the window carries 22px of shadow margin.
const BLEED_X: f64 = 6.0;
const NUDGE_Y: f64 = 2.0;

pub struct TauriUi {
    app: AppHandle,
    pending: Mutex<HashMap<String, oneshot::Sender<bool>>>,
}

impl TauriUi {
    pub fn new(app: AppHandle) -> Arc<Self> {
        Arc::new(Self { app, pending: Mutex::new(HashMap::new()) })
    }
}

#[async_trait]
impl Ui for TauriUi {
    async fn decide(&self, req: &IncomingRequest) -> bool {
        let (tx, rx) = oneshot::channel();
        self.pending.lock().unwrap().insert(req.id.clone(), tx);

        // The core drops this future if the sender disconnects; don't leak the entry then.
        struct Cleanup<'a>(&'a TauriUi, String);
        impl Drop for Cleanup<'_> {
            fn drop(&mut self) {
                self.0.pending.lock().unwrap().remove(&self.1);
            }
        }
        let _cleanup = Cleanup(self, req.id.clone());

        chime::play();
        let _ = self.app.emit("incoming", req);
        rx.await.unwrap_or(false)
    }

    fn event(&self, ev: UiEvent) {
        // A message only reaches here after the user tapped Accept. Only now may it touch the
        // clipboard or the browser. (The chime already played when the prompt appeared.)
        if let UiEvent::Message { id, text, .. } = &ev {
            let copied = arboard::Clipboard::new().and_then(|mut c| c.set_text(text.clone())).is_ok();
            let opened = match as_openable_url(text) {
                Some(url) => open_url(&url),
                None => false,
            };
            let _ = self.app.emit("accepted-message", serde_json::json!({ "id": id, "copied": copied, "opened": opened }));
            return;
        }
        match &ev {
            // Show what arrived: Explorer opens on the folder with the (first) file selected. The file
            // itself is never opened, so a received document or program can't run on its own.
            UiEvent::Done { dir, first_file, .. } => {
                open_in_explorer(PathBuf::from(first_file.clone().unwrap_or_else(|| dir.clone())));
            }
            UiEvent::Paired { .. } | UiEvent::Queued { .. } | UiEvent::OutboxDelivered { .. } => {
                let _ = self.app.emit_to("menu", "menu-refresh", ());
            }
            _ => {}
        }
        let _ = self.app.emit("ui", &ev);
    }
}

/// The text, if and only if it is exactly one `http` or `https` link. Anything else (other
/// schemes such as file: or ms-msdt:, extra words, control characters) is never opened.
pub fn as_openable_url(text: &str) -> Option<String> {
    let t = text.trim();
    let lower = t.to_ascii_lowercase();
    let rest = lower.strip_prefix("https://").or_else(|| lower.strip_prefix("http://"))?;
    let ok = t.len() <= 2048
        && !rest.is_empty()
        && !rest.starts_with('/')
        && !t.chars().any(|c| c.is_whitespace() || c.is_control());
    ok.then(|| t.to_string())
}

fn open_url(url: &str) -> bool {
    // No shell involved: the URL is a single argv entry, so it can't smuggle commands.
    std::process::Command::new("rundll32").args(["url.dll,FileProtocolHandler", url]).spawn().is_ok()
}

fn window(app: &AppHandle) -> Option<WebviewWindow> {
    app.get_webview_window("toast")
}

/// Pin to the top-right corner of the work area (so it clears the taskbar wherever that lives).
fn place(w: &WebviewWindow) {
    let (Ok(Some(monitor)), Ok(size)) = (w.primary_monitor(), w.outer_size()) else { return };
    let work = monitor.work_area();
    let scale = monitor.scale_factor();
    let x = work.position.x + work.size.width as i32 - size.width as i32 + (BLEED_X * scale) as i32;
    let y = work.position.y + (NUDGE_Y * scale) as i32;
    let _ = w.set_position(PhysicalPosition::new(x, y));
}

#[tauri::command]
pub fn respond(ui: State<'_, Arc<TauriUi>>, id: String, accept: bool) {
    if let Some(tx) = ui.pending.lock().unwrap().remove(&id) {
        let _ = tx.send(accept);
    }
}

#[tauri::command]
pub fn toast_show(app: AppHandle) {
    if let Some(w) = window(&app) {
        place(&w);
        let _ = w.show();
        let _ = w.set_always_on_top(true);
        #[cfg(windows)]
        crate::droptarget::sync(&app);
    }
}

#[tauri::command]
pub fn toast_hidden(app: AppHandle) {
    if let Some(w) = window(&app) {
        let _ = w.hide();
    }
    #[cfg(windows)]
    crate::droptarget::set(&app, false);
}

/// The page shows (true) or leaves (false) the drop zone: the invisible drop overlay follows it.
#[tauri::command]
pub fn drop_overlay(app: AppHandle, on: bool) {
    #[cfg(windows)]
    crate::droptarget::set(&app, on);
    #[cfg(not(windows))]
    let _ = (app, on);
}

/// The page reports its card height so the transparent window never covers more than the toast.
#[tauri::command]
pub fn toast_resize(app: AppHandle, height: f64) {
    if let Some(w) = window(&app) {
        let _ = w.set_size(LogicalSize::new(WIDTH, height.clamp(60.0, 600.0)));
        place(&w);
        #[cfg(windows)]
        crate::droptarget::sync(&app);
    }
}

#[cfg(test)]
mod tests {
    use super::as_openable_url;

    #[test]
    fn only_a_single_web_link_is_openable() {
        assert_eq!(as_openable_url("https://whiteframe.cc"), Some("https://whiteframe.cc".into()));
        assert_eq!(as_openable_url("  HTTP://Example.com/a?b=c  "), Some("HTTP://Example.com/a?b=c".into()));
        // Not links, or not safe to open:
        assert_eq!(as_openable_url("https://whiteframe.cc and some words"), None);
        assert_eq!(as_openable_url("file:///C:/Windows/System32/cmd.exe"), None);
        assert_eq!(as_openable_url("javascript:alert(1)"), None);
        assert_eq!(as_openable_url("ms-msdt:/id PCWDiagnostic"), None);
        assert_eq!(as_openable_url("\\\\evil\\share\\x.exe"), None);
        assert_eq!(as_openable_url("https://"), None);
        assert_eq!(as_openable_url("https:///nohost"), None);
        assert_eq!(as_openable_url("https://a.com\nhttps://b.com"), None);
        assert_eq!(as_openable_url("just a note"), None);
    }
}

/// Opens Explorer on a folder, or on a folder with a file selected.
#[tauri::command]
pub fn reveal(path: String) {
    open_in_explorer(PathBuf::from(path));
}

pub fn open_in_explorer(path: PathBuf) {
    let mut cmd = std::process::Command::new("explorer");
    if path.is_dir() {
        cmd.arg(path);
    } else {
        // Explorer wants `/select,"C:\path with spaces\file"` as one raw argument; the default argv
        // quoting would wrap the whole thing and Explorer would open Documents instead. Names are
        // ours (safe_file_name strips `"`), so building the string is safe.
        #[cfg(windows)]
        {
            use std::os::windows::process::CommandExt;
            cmd.raw_arg(format!("/select,\"{}\"", path.display()));
        }
        #[cfg(not(windows))]
        cmd.arg(format!("/select,{}", path.display()));
    }
    let _ = cmd.spawn();
}
