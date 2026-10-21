//! Lets files be dropped on the toast's drop zone (Windows -> iPhone).
//!
//! The toast is a WebView2 window, and the windows under the cursor belong to msedgewebview2.exe: Grasp can't
//! register a drop target on them, and WebView2's own refuses outside drops (the "not allowed" cursor, even
//! with a target on Grasp's in-process host window, because OLE doesn't walk up to it). So while the drop zone
//! is showing, Grasp puts a plain window of its own exactly over the toast: no WebView2 inside, almost fully
//! transparent (alpha 1/255, still hit-tested), with Grasp's IDropTarget. What you see is the toast's dashed
//! box underneath. The overlay exists only while the zone is up, so it never covers Accept / Reject.

use std::{
    cell::{Cell, RefCell},
    ffi::OsString,
    os::windows::ffi::OsStringExt,
    path::PathBuf,
    sync::atomic::{AtomicBool, Ordering},
};

use tauri::{AppHandle, Emitter, Manager};
use windows::{
    core::{implement, w, Ref},
    Win32::{
        Foundation::{COLORREF, HWND, LPARAM, LRESULT, POINTL, RECT, WPARAM},
        Graphics::Gdi::{GetStockObject, HBRUSH, BLACK_BRUSH},
        System::{
            Com::{IDataObject, DVASPECT_CONTENT, FORMATETC, TYMED_HGLOBAL},
            LibraryLoader::GetModuleHandleW,
            Ole::{
                IDropTarget, IDropTarget_Impl, RegisterDragDrop, ReleaseStgMedium, CF_HDROP, DROPEFFECT,
                DROPEFFECT_COPY, DROPEFFECT_NONE,
            },
            SystemServices::MODIFIERKEYS_FLAGS,
        },
        UI::{
            Shell::{DragQueryFileW, HDROP},
            WindowsAndMessaging::{
                CreateWindowExW, DefWindowProcW, GetWindowRect, RegisterClassW, SetLayeredWindowAttributes,
                SetWindowPos, ShowWindow, HWND_TOPMOST, LWA_ALPHA, SWP_NOACTIVATE, SWP_SHOWWINDOW, SW_HIDE,
                WNDCLASSW, WS_EX_LAYERED, WS_EX_NOACTIVATE, WS_EX_TOOLWINDOW, WS_EX_TOPMOST, WS_POPUP,
            },
        },
    },
};

/// The page wants the overlay (the drop zone is showing). Toast moves/resizes re-place it while set.
static WANTED: AtomicBool = AtomicBool::new(false);

thread_local! {
    // The overlay window and its drop target, created once on the main thread and kept for the app's life.
    static OVERLAY: Cell<Option<isize>> = const { Cell::new(None) };
    static TARGET: RefCell<Option<IDropTarget>> = const { RefCell::new(None) };
}

/// Shows (over the toast) or hides the overlay. Safe from any thread.
pub fn set(app: &AppHandle, on: bool) {
    WANTED.store(on, Ordering::Relaxed);
    sync(app);
}

/// Re-applies the wanted state, e.g. after the toast moved or resized.
pub fn sync(app: &AppHandle) {
    let a = app.clone();
    let _ = app.run_on_main_thread(move || apply(&a));
}

fn apply(app: &AppHandle) {
    let Some(overlay) = overlay(app) else { return };
    let toast = app.get_webview_window("toast").and_then(|w| w.hwnd().ok()).map(|h| HWND(h.0 as _));
    unsafe {
        let mut r = RECT::default();
        let placed = toast.is_some_and(|t| GetWindowRect(t, &mut r).is_ok());
        if WANTED.load(Ordering::Relaxed) && placed {
            let _ = SetWindowPos(
                overlay,
                Some(HWND_TOPMOST),
                r.left,
                r.top,
                r.right - r.left,
                r.bottom - r.top,
                SWP_NOACTIVATE | SWP_SHOWWINDOW,
            );
        } else {
            let _ = ShowWindow(overlay, SW_HIDE);
        }
    }
}

unsafe extern "system" fn wndproc(h: HWND, m: u32, w: WPARAM, l: LPARAM) -> LRESULT {
    DefWindowProcW(h, m, w, l)
}

/// Creates the overlay window and registers its drop target the first time. Main thread only.
fn overlay(app: &AppHandle) -> Option<HWND> {
    if let Some(h) = OVERLAY.get() {
        return Some(HWND(h as _));
    }
    unsafe {
        let instance = GetModuleHandleW(None).ok()?;
        let class = WNDCLASSW {
            lpfnWndProc: Some(wndproc),
            hInstance: instance.into(),
            lpszClassName: w!("GraspDropOverlay"),
            hbrBackground: HBRUSH(GetStockObject(BLACK_BRUSH).0),
            ..Default::default()
        };
        RegisterClassW(&class);
        let hwnd = CreateWindowExW(
            WS_EX_LAYERED | WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
            w!("GraspDropOverlay"),
            w!("Grasp drop zone"),
            WS_POPUP,
            0,
            0,
            1,
            1,
            None,
            None,
            Some(instance.into()),
            None,
        )
        .ok()?;
        // Alpha 1 of 255: invisible, but unlike 0 it is still hit-tested, so drags find it.
        let _ = SetLayeredWindowAttributes(hwnd, COLORREF(0), 1, LWA_ALPHA);
        let target: IDropTarget = Target { app: app.clone(), has_files: Cell::new(false) }.into();
        RegisterDragDrop(hwnd, &target).ok()?;
        TARGET.with(|t| *t.borrow_mut() = Some(target));
        OVERLAY.set(Some(hwnd.0 as isize));
        Some(hwnd)
    }
}

#[implement(IDropTarget)]
struct Target {
    app: AppHandle,
    /// The current drag carries files (CF_HDROP). Anything else is refused.
    has_files: Cell<bool>,
}

/// The dropped paths, from the shell's CF_HDROP list.
unsafe fn paths_of(data: Ref<'_, IDataObject>) -> Option<Vec<PathBuf>> {
    let format = FORMATETC {
        cfFormat: CF_HDROP.0,
        ptd: std::ptr::null_mut(),
        dwAspect: DVASPECT_CONTENT.0,
        lindex: -1,
        tymed: TYMED_HGLOBAL.0 as u32,
    };
    let mut medium = data.as_ref()?.GetData(&format).ok()?;
    let hdrop = HDROP(medium.u.hGlobal.0 as _);
    let count = DragQueryFileW(hdrop, u32::MAX, None);
    let mut paths = Vec::with_capacity(count as usize);
    for i in 0..count {
        let len = DragQueryFileW(hdrop, i, None) as usize;
        let mut buf = vec![0u16; len + 1];
        DragQueryFileW(hdrop, i, Some(&mut buf));
        paths.push(OsString::from_wide(&buf[..len]).into());
    }
    ReleaseStgMedium(&mut medium);
    Some(paths)
}

#[allow(non_snake_case)]
impl IDropTarget_Impl for Target_Impl {
    fn DragEnter(
        &self,
        data: Ref<'_, IDataObject>,
        _keys: MODIFIERKEYS_FLAGS,
        _pt: &POINTL,
        effect: *mut DROPEFFECT,
    ) -> windows::core::Result<()> {
        let files = unsafe { paths_of(data) }.is_some_and(|p| !p.is_empty());
        self.has_files.set(files);
        if files {
            let _ = self.app.emit_to("toast", "drop-hover", true);
        }
        unsafe { *effect = if files { DROPEFFECT_COPY } else { DROPEFFECT_NONE } };
        Ok(())
    }

    fn DragOver(&self, _keys: MODIFIERKEYS_FLAGS, _pt: &POINTL, effect: *mut DROPEFFECT) -> windows::core::Result<()> {
        unsafe { *effect = if self.has_files.get() { DROPEFFECT_COPY } else { DROPEFFECT_NONE } };
        Ok(())
    }

    fn DragLeave(&self) -> windows::core::Result<()> {
        if self.has_files.get() {
            let _ = self.app.emit_to("toast", "drop-hover", false);
        }
        Ok(())
    }

    fn Drop(
        &self,
        data: Ref<'_, IDataObject>,
        _keys: MODIFIERKEYS_FLAGS,
        _pt: &POINTL,
        effect: *mut DROPEFFECT,
    ) -> windows::core::Result<()> {
        // COPY tells Explorer we took a copy: the files stay where they are (the outbox reads them in place).
        let paths = unsafe { paths_of(data) }.unwrap_or_default();
        unsafe { *effect = if paths.is_empty() { DROPEFFECT_NONE } else { DROPEFFECT_COPY } };
        set(&self.app, false);
        if !paths.is_empty() {
            let _ = self.app.emit_to("toast", "dropped", ());
            crate::send::send_paths(&self.app, paths);
        }
        Ok(())
    }
}
