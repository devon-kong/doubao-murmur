//! Help window. The toggle-key name is injected before the page loads so the
//! text always matches the current setting.

use tauri::{AppHandle, Manager, WebviewUrl, WebviewWindowBuilder};

use crate::settings::ToggleKey;

pub const WINDOW_LABEL: &str = "help";

/// Must run on the main thread.
pub fn show(app: &AppHandle, key: ToggleKey) -> Result<(), String> {
    if let Some(window) = app.get_webview_window(WINDOW_LABEL) {
        let _ = window.show();
        let _ = window.set_focus();
        return Ok(());
    }

    let key_json = serde_json::to_string(key.short_label())
        .unwrap_or_else(|_| "\"右 Alt\"".to_string());

    WebviewWindowBuilder::new(app, WINDOW_LABEL, WebviewUrl::App("help.html".into()))
        .title("Doubao Murmur - 使用帮助")
        .inner_size(700.0, 660.0)
        .center()
        .resizable(true)
        .initialization_script(&format!("window.__DM_KEY = {key_json};"))
        .build()
        .map(|_| ())
        .map_err(|e| e.to_string())
}
