//! Borderless status overlay pinned above every other window.
//! Mirrors OverlayPanel.swift + OverlayView.swift.

use std::sync::atomic::{AtomicBool, Ordering};

use serde::{Deserialize, Serialize};
use tauri::{AppHandle, Emitter, Manager, PhysicalPosition, WebviewUrl, WebviewWindow,
            WebviewWindowBuilder};

use crate::config;
use crate::win32;
use crate::{log_warn};

pub const WINDOW_LABEL: &str = "overlay";
pub const STATE_EVENT: &str = "overlay-state";

/// Set while the app moves the window itself, so the resulting Moved event is not
/// mistaken for the user dragging it.
static PROGRAMMATIC_MOVE: AtomicBool = AtomicBool::new(false);

#[derive(Clone, Serialize)]
pub struct OverlayState {
    pub text: String,
    pub recording: bool,
    pub error: bool,
}

#[derive(Serialize, Deserialize)]
struct Geometry {
    x: i32,
    y: i32,
}

/// Must run on the main thread.
pub fn build(app: &AppHandle) -> Result<WebviewWindow, String> {
    let window = WebviewWindowBuilder::new(
        app,
        WINDOW_LABEL,
        WebviewUrl::App("overlay.html".into()),
    )
    .title("Doubao Murmur")
    .inner_size(config::OVERLAY_WIDTH, config::OVERLAY_HEIGHT)
    .decorations(false)
    .always_on_top(true)
    .skip_taskbar(true)
    .resizable(false)
    .transparent(true)
    .shadow(false)
    .focused(false)
    .visible(false)
    .build()
    .map_err(|e| e.to_string())?;

    // Applied before the window is ever shown: if the overlay took focus, the
    // transcription would be pasted into the overlay instead of the app the user
    // was typing in.
    if let Ok(handle) = window.hwnd() {
        win32::make_non_activating(win32::hwnd_from_isize(handle.0 as isize));
    } else {
        log_warn!("Could not read the overlay window handle; it may steal focus");
    }

    Ok(window)
}

pub fn show(app: &AppHandle) {
    let Some(window) = app.get_webview_window(WINDOW_LABEL) else {
        return;
    };
    reposition(app, &window);
    let _ = window.show();
}

pub fn hide(app: &AppHandle) {
    if let Some(window) = app.get_webview_window(WINDOW_LABEL) {
        let _ = window.hide();
    }
}

pub fn update(app: &AppHandle, state: OverlayState) {
    if let Some(window) = app.get_webview_window(WINDOW_LABEL) {
        let _ = window.emit(STATE_EVENT, state);
    }
}

fn reposition(app: &AppHandle, window: &WebviewWindow) {
    let Some(position) = target_position(app, window) else {
        return;
    };

    PROGRAMMATIC_MOVE.store(true, Ordering::SeqCst);
    let _ = window.set_position(position);
    PROGRAMMATIC_MOVE.store(false, Ordering::SeqCst);
}

fn target_position(app: &AppHandle, window: &WebviewWindow) -> Option<PhysicalPosition<i32>> {
    if let Some(saved) = load_geometry() {
        if is_on_a_monitor(app, saved.x, saved.y) {
            return Some(PhysicalPosition::new(saved.x, saved.y));
        }
    }

    // Top-centre of whichever monitor the pointer is on.
    let monitor = app
        .cursor_position()
        .ok()
        .and_then(|point| app.monitor_from_point(point.x, point.y).ok().flatten())
        .or_else(|| window.current_monitor().ok().flatten())
        .or_else(|| app.primary_monitor().ok().flatten())?;

    let scale = monitor.scale_factor();
    let area = monitor.size();
    let origin = monitor.position();

    let width = (config::OVERLAY_WIDTH * scale) as i32;
    let x = origin.x + (area.width as i32 - width) / 2;
    let y = origin.y + (config::OVERLAY_TOP_MARGIN * scale) as i32;

    Some(PhysicalPosition::new(x, y))
}

fn is_on_a_monitor(app: &AppHandle, x: i32, y: i32) -> bool {
    let Ok(monitors) = app.available_monitors() else {
        return false;
    };

    monitors.iter().any(|monitor| {
        let origin = monitor.position();
        let size = monitor.size();
        // Only the top-left corner has to land on a monitor; that is enough to
        // guarantee the window is reachable after a display layout change.
        x >= origin.x - 40
            && y >= origin.y - 10
            && x < origin.x + size.width as i32 - 80
            && y < origin.y + size.height as i32 - 20
    })
}

/// Called from the window's Moved handler.
pub fn remember_position(x: i32, y: i32) {
    if PROGRAMMATIC_MOVE.load(Ordering::SeqCst) {
        return;
    }

    if let Ok(text) = serde_json::to_string(&Geometry { x, y }) {
        let _ = std::fs::write(config::overlay_path(), text);
    }
}

fn load_geometry() -> Option<Geometry> {
    let text = std::fs::read_to_string(config::overlay_path()).ok()?;
    serde_json::from_str(&text).ok()
}
