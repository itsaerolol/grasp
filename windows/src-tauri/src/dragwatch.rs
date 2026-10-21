//! Opens the toast's drop zone whenever files are being dragged anywhere (Explorer, the desktop), and closes
//! it when they're let go elsewhere. Windows has no "a drag started" event, so a thread polls ~12 times a
//! second: the left button is held and the shell's drag-image window (class "SysDragImage") is visible.
//! That window only exists while something is dragged with the shell's drag image, so selecting files with a
//! rubber band or moving a window never triggers it.

use std::{sync::Arc, time::Duration};

use tauri::{AppHandle, Emitter, Manager};

use crate::menu::Shell;

const POLL: Duration = Duration::from_millis(80);

pub fn start(app: AppHandle) {
    std::thread::spawn(move || {
        let mut dragging = false;
        loop {
            std::thread::sleep(POLL);
            let held = left_button_down();
            if !dragging && held && drag_image_visible() {
                dragging = true;
                // Nowhere to send without a phone paired by code; don't pop a zone that can't work.
                let paired = app
                    .try_state::<Arc<Shell>>()
                    .and_then(|s| s.handle.as_ref().map(|h| !h.paired_devices().is_empty()))
                    .unwrap_or(false);
                if paired {
                    let _ = app.emit_to("toast", "drag-start", ());
                }
            } else if dragging && !held {
                dragging = false;
                // The page hides the zone unless the drop landed on it (that arrives as a window event).
                let _ = app.emit_to("toast", "drag-end", ());
            }
        }
    });
}

#[cfg(windows)]
fn left_button_down() -> bool {
    use windows_sys::Win32::UI::Input::KeyboardAndMouse::{GetAsyncKeyState, VK_LBUTTON};
    // GetAsyncKeyState reports the physical button; with swapped buttons the primary is VK_RBUTTON.
    let primary = if swapped() { windows_sys::Win32::UI::Input::KeyboardAndMouse::VK_RBUTTON } else { VK_LBUTTON };
    (unsafe { GetAsyncKeyState(primary as i32) } as u16 & 0x8000) != 0
}

#[cfg(windows)]
fn swapped() -> bool {
    use windows_sys::Win32::UI::WindowsAndMessaging::{GetSystemMetrics, SM_SWAPBUTTON};
    unsafe { GetSystemMetrics(SM_SWAPBUTTON) != 0 }
}

#[cfg(windows)]
fn drag_image_visible() -> bool {
    use windows_sys::Win32::UI::WindowsAndMessaging::{FindWindowW, IsWindowVisible};
    let class: Vec<u16> = "SysDragImage\0".encode_utf16().collect();
    let hwnd = unsafe { FindWindowW(class.as_ptr(), std::ptr::null()) };
    !hwnd.is_null() && unsafe { IsWindowVisible(hwnd) } != 0
}

#[cfg(not(windows))]
fn left_button_down() -> bool {
    false
}

#[cfg(not(windows))]
fn drag_image_visible() -> bool {
    false
}
