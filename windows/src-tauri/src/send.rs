//! Windows -> iPhone, the shell side. Everything here only queues things in the core's outbox; the phone
//! pulls them when Grasp is open on it (see grasp_core::outbox). Ways in:
//! - Explorer's Send to menu ("iPhone (Grasp)"), a shortcut that runs `grasp-desktop.exe --send <paths>`.
//!   A second launch hands its arguments to the running Grasp through the single-instance plugin.
//! - Tray menu: Send files... (picker) and Send clipboard (copied files, a screenshot, or text).
//! - Dropping files on the toast's drop zone (see dragwatch.rs and toast.rs).

use std::{path::PathBuf, sync::Arc};

use grasp_core::UiEvent;
use tauri::{AppHandle, Emitter, Manager, State};
use tauri_plugin_dialog::DialogExt;

use crate::{menu::Shell, toast::TauriUi};

pub const SEND_ARG: &str = "--send";
const SEND_TO_NAME: &str = "iPhone (Grasp).lnk";

/// Paths after `--send` in a command line (Explorer's Send to appends the selected items).
pub fn paths_from_args(argv: &[String]) -> Option<Vec<PathBuf>> {
    let at = argv.iter().position(|a| a == SEND_ARG)?;
    Some(argv[at + 1..].iter().map(PathBuf::from).collect())
}

/// One line for the toast when there is no phone to send to, or nothing to send.
fn fail(app: &AppHandle, reason: &str) {
    if let Some(ui) = app.try_state::<Arc<TauriUi>>() {
        use grasp_core::Ui;
        ui.event(UiEvent::Failed { id: format!("send-{}", now_ms()), reason: reason.into() });
    }
}

fn now_ms() -> u128 {
    std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_millis()).unwrap_or(0)
}

/// Only a phone paired by code can pull, so without one there is nowhere to send.
fn ready(app: &AppHandle, shell: &Shell) -> bool {
    match &shell.handle {
        Some(h) if !h.paired_devices().is_empty() => true,
        Some(_) => {
            fail(app, "Pair your iPhone first: choose Pair iPhone in Grasp's tray menu.");
            false
        }
        None => {
            fail(app, "Grasp isn't running its receiver, so the iPhone can't collect anything.");
            false
        }
    }
}

/// Queues files and folders. The core reports what was queued (`UiEvent::Queued`), which the toast shows.
pub fn send_paths(app: &AppHandle, paths: Vec<PathBuf>) {
    let Some(shell) = app.try_state::<Arc<Shell>>() else { return };
    if paths.is_empty() || !ready(app, &shell) {
        return;
    }
    let queued = shell.handle.as_ref().map(|h| h.send_paths(&paths)).unwrap_or(0);
    if queued == 0 {
        fail(app, "Nothing to send: those items are empty folders or no longer exist.");
    }
}

#[tauri::command]
pub async fn send_files(app: AppHandle) -> Result<(), String> {
    crate::menu::hide(&app);
    let picked = app.dialog().file().set_title("Send to iPhone").blocking_pick_files();
    let paths: Vec<PathBuf> = picked.unwrap_or_default().into_iter().filter_map(|p| p.into_path().ok()).collect();
    send_paths(&app, paths);
    Ok(())
}

/// Copied files win, then an image (a screenshot becomes a PNG), then text. The phone puts text on its
/// own clipboard.
#[tauri::command]
pub fn send_clipboard(app: AppHandle, shell: State<'_, Arc<Shell>>) {
    crate::menu::hide(&app);
    if !ready(&app, &shell) {
        return;
    }
    let Ok(mut clip) = arboard::Clipboard::new() else {
        return fail(&app, "Couldn't read the clipboard.");
    };
    if let Ok(files) = clip.get().file_list() {
        if !files.is_empty() {
            return send_paths(&app, files);
        }
    }
    if let Ok(image) = clip.get_image() {
        match save_png(&shell.clips_dir, &image) {
            Ok(path) => return send_paths(&app, vec![path]),
            Err(e) => return fail(&app, &format!("Couldn't save the copied image: {e}")),
        }
    }
    match clip.get_text() {
        Ok(text) if !text.trim().is_empty() => {
            if let Some(h) = &shell.handle {
                h.send_text(&text);
            }
        }
        _ => fail(&app, "The clipboard is empty."),
    }
}

/// "Screenshot 2026-10-20 21.04.11.png" in Grasp's own folder (the outbox sends files from where they are,
/// so a copied image needs to live somewhere until the phone collects it).
fn save_png(dir: &std::path::Path, image: &arboard::ImageData) -> anyhow::Result<PathBuf> {
    std::fs::create_dir_all(dir)?;
    let name = format!("Screenshot {}.png", stamp());
    let path = grasp_core::server::unique_path(dir, &name);
    let file = std::io::BufWriter::new(std::fs::File::create(&path)?);
    let mut enc = png::Encoder::new(file, image.width as u32, image.height as u32);
    enc.set_color(png::ColorType::Rgba);
    enc.set_depth(png::BitDepth::Eight);
    enc.write_header()?.write_image_data(&image.bytes)?;
    Ok(path)
}

/// Local time as "2026-10-20 21.04.11", without pulling in a date crate.
fn stamp() -> String {
    #[cfg(windows)]
    {
        use windows_sys::Win32::System::SystemInformation::GetLocalTime;
        let mut t = unsafe { std::mem::zeroed() };
        unsafe { GetLocalTime(&mut t) };
        format!("{:04}-{:02}-{:02} {:02}.{:02}.{:02}", t.wYear, t.wMonth, t.wDay, t.wHour, t.wMinute, t.wSecond)
    }
    #[cfg(not(windows))]
    {
        now_ms().to_string()
    }
}

#[tauri::command]
pub fn clear_outbox(app: AppHandle, shell: State<'_, Arc<Shell>>) {
    if let Some(h) = &shell.handle {
        h.clear_outbox();
    }
    // A "Waiting for iPhone" card still up has nothing to wait for now.
    let _ = app.emit_to("toast", "outbox-cleared", ());
}

/// Puts "iPhone (Grasp)" in Explorer's Send to menu, pointing at this exe. Rewritten on every start so it
/// follows the exe if Grasp moves (or a dev build runs). Failure only costs the menu entry.
pub fn install_send_to() {
    let (Ok(exe), Some(appdata)) = (std::env::current_exe(), std::env::var_os("APPDATA")) else { return };
    let dir = PathBuf::from(appdata).join(r"Microsoft\Windows\SendTo");
    if !dir.is_dir() {
        return;
    }
    let Ok(mut link) = mslnk::ShellLink::new(&exe) else { return };
    link.set_arguments(Some(SEND_ARG.into()));
    link.set_name(Some("Send to your iPhone with Grasp".into()));
    link.set_icon_location(Some(exe.display().to_string()));
    let _ = link.create_lnk(dir.join(SEND_TO_NAME));
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn send_to_arguments_become_paths() {
        let argv: Vec<String> = ["grasp.exe", "--send", r"C:\a b\photo.jpg", r"D:\Trip"].iter().map(|s| s.to_string()).collect();
        assert_eq!(paths_from_args(&argv), Some(vec![PathBuf::from(r"C:\a b\photo.jpg"), PathBuf::from(r"D:\Trip")]));
        assert_eq!(paths_from_args(&["grasp.exe".to_string()]), None);
    }
}
