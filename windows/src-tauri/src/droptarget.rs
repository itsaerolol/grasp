//! The toast's own OLE drop target, so files can be dropped on it (Windows -> iPhone).
//!
//! Why not Tauri's drag-drop events: wry swaps a file-accepting target onto the WebView2 host window
//! (`Chrome_WidgetWin_0`) when the webview is created. The toast is created hidden, and WebView2 puts its own
//! target back when the window is shown; with external drops disabled that one refuses everything, so the
//! cursor shows the "not allowed" sign. So every time the toast is shown we install ours on each of its child
//! windows that belong to this process. WebView2's render windows live in msedgewebview2.exe (we can't
//! register there, and they have no target), so OLE walks up from them to ours.

use std::{cell::Cell, cell::RefCell, ffi::OsString, os::windows::ffi::OsStringExt, path::PathBuf, rc::Rc, time::Duration};

use tauri::{AppHandle, Emitter, Manager};
use windows::{
    core::{implement, Ref, BOOL},
    Win32::{
        Foundation::{HWND, LPARAM, POINTL},
        System::{
            Com::{IDataObject, DVASPECT_CONTENT, FORMATETC, TYMED_HGLOBAL},
            Ole::{
                IDropTarget, IDropTarget_Impl, RegisterDragDrop, ReleaseStgMedium, RevokeDragDrop, CF_HDROP,
                DROPEFFECT, DROPEFFECT_COPY, DROPEFFECT_NONE,
            },
            SystemServices::MODIFIERKEYS_FLAGS,
        },
        UI::{
            Shell::{DragQueryFileW, HDROP},
            WindowsAndMessaging::{EnumChildWindows, GetWindowThreadProcessId},
        },
    },
};

enum Event {
    Hover(bool),
    Files(Vec<PathBuf>),
}

thread_local! {
    // Keeps our registered targets alive (OLE holds its own reference too). Main thread only.
    static TARGETS: RefCell<Vec<IDropTarget>> = const { RefCell::new(Vec::new()) };
}

/// Called whenever the toast is shown. WebView2 may restore its own target a moment after the window
/// appears, so ours goes on now and again shortly after.
pub fn arm(app: &AppHandle) {
    let app = app.clone();
    std::thread::spawn(move || {
        for delay in [0, 200, 800] {
            std::thread::sleep(Duration::from_millis(delay));
            let a = app.clone();
            let _ = app.run_on_main_thread(move || install(&a));
        }
    });
}

fn install(app: &AppHandle) {
    let Some(raw) = app.get_webview_window("toast").and_then(|w| w.hwnd().ok()).map(|h| h.0 as isize) else {
        return;
    };
    let mut children: Vec<HWND> = Vec::new();
    unsafe extern "system" fn collect(h: HWND, l: LPARAM) -> BOOL {
        (*(l.0 as *mut Vec<HWND>)).push(h);
        true.into()
    }
    let _ = unsafe {
        EnumChildWindows(Some(HWND(raw as _)), Some(collect), LPARAM(&mut children as *mut Vec<HWND> as isize))
    };

    let handler: Rc<dyn Fn(Event)> = {
        let app = app.clone();
        Rc::new(move |e| match e {
            Event::Hover(on) => {
                let _ = app.emit_to("toast", "drop-hover", on);
            }
            Event::Files(paths) => {
                let _ = app.emit_to("toast", "dropped", ());
                crate::send::send_paths(&app, paths);
            }
        })
    };
    let me = std::process::id();
    TARGETS.with(|t| {
        let mut t = t.borrow_mut();
        t.clear();
        for h in children {
            let mut pid = 0;
            unsafe { GetWindowThreadProcessId(h, Some(&mut pid)) };
            if pid != me {
                continue;
            }
            let target: IDropTarget = Target { on: handler.clone(), has_files: Cell::new(false) }.into();
            unsafe {
                let _ = RevokeDragDrop(h);
                if RegisterDragDrop(h, &target).is_ok() {
                    t.push(target);
                }
            }
        }
    });
}

#[implement(IDropTarget)]
struct Target {
    on: Rc<dyn Fn(Event)>,
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
            (self.on)(Event::Hover(true));
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
            (self.on)(Event::Hover(false));
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
        if !paths.is_empty() {
            (self.on)(Event::Files(paths));
        }
        Ok(())
    }
}
