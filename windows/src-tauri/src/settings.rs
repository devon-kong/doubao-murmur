//! User-tunable behaviour, persisted to %APPDATA%\doubao-murmur\settings.json.

use serde::{Deserialize, Serialize};

use crate::config;
use crate::{log_error, log_warn};

/// The key that toggles dictation. Right Alt matches macOS and Linux, but it is
/// configurable because a bare Alt tap opens the menu bar in some Win32 apps and
/// because AltGr layouts put a third meaning on that same physical key.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ToggleKey {
    RightAlt,
    RightControl,
    RightShift,
    ScrollLock,
    Pause,
}

impl ToggleKey {
    pub const ALL: [ToggleKey; 5] = [
        ToggleKey::RightAlt,
        ToggleKey::RightControl,
        ToggleKey::RightShift,
        ToggleKey::ScrollLock,
        ToggleKey::Pause,
    ];

    pub fn label(self) -> &'static str {
        match self {
            ToggleKey::RightAlt => "右 Alt（默认）",
            ToggleKey::RightControl => "右 Ctrl",
            ToggleKey::RightShift => "右 Shift",
            ToggleKey::ScrollLock => "Scroll Lock",
            ToggleKey::Pause => "Pause",
        }
    }

    pub fn short_label(self) -> &'static str {
        match self {
            ToggleKey::RightAlt => "右 Alt",
            ToggleKey::RightControl => "右 Ctrl",
            ToggleKey::RightShift => "右 Shift",
            ToggleKey::ScrollLock => "Scroll Lock",
            ToggleKey::Pause => "Pause",
        }
    }

    pub fn id(self) -> &'static str {
        match self {
            ToggleKey::RightAlt => "key_right_alt",
            ToggleKey::RightControl => "key_right_ctrl",
            ToggleKey::RightShift => "key_right_shift",
            ToggleKey::ScrollLock => "key_scroll_lock",
            ToggleKey::Pause => "key_pause",
        }
    }

    pub fn from_id(id: &str) -> Option<ToggleKey> {
        ToggleKey::ALL.into_iter().find(|key| key.id() == id)
    }
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum PasteMode {
    /// Copy to the clipboard, then send Ctrl+V.
    Clipboard,
    /// Type the text directly with synthesised Unicode keystrokes.
    Typing,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Settings {
    #[serde(default = "default_toggle_key")]
    pub toggle_key: ToggleKey,
    /// Swallow the toggle key so the focused app never sees it. Stops a bare Alt
    /// tap from opening menu bars, but also disables AltGr, so it is off by default.
    #[serde(default)]
    pub suppress_toggle_key: bool,
    #[serde(default = "default_paste_mode")]
    pub paste_mode: PasteMode,
}

fn default_toggle_key() -> ToggleKey {
    ToggleKey::RightAlt
}

fn default_paste_mode() -> PasteMode {
    PasteMode::Clipboard
}

impl Default for Settings {
    fn default() -> Self {
        Settings {
            toggle_key: default_toggle_key(),
            suppress_toggle_key: false,
            paste_mode: default_paste_mode(),
        }
    }
}

impl Settings {
    pub fn load() -> Settings {
        let path = config::settings_path();
        if !path.exists() {
            return Settings::default();
        }

        match std::fs::read_to_string(&path).map(|t| serde_json::from_str::<Settings>(&t)) {
            Ok(Ok(settings)) => settings,
            Ok(Err(e)) => {
                log_warn!("Settings file is not valid, using defaults: {e}");
                Settings::default()
            }
            Err(e) => {
                log_warn!("Could not read settings, using defaults: {e}");
                Settings::default()
            }
        }
    }

    pub fn save(&self) {
        match serde_json::to_string_pretty(self) {
            Ok(text) => {
                if let Err(e) = std::fs::write(config::settings_path(), text) {
                    log_error!("Failed to save settings: {e}");
                }
            }
            Err(e) => log_error!("Failed to serialise settings: {e}"),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn defaults_match_the_other_platforms() {
        let settings = Settings::default();
        assert_eq!(settings.toggle_key, ToggleKey::RightAlt);
        // Suppression breaks AltGr, so it must stay opt-in.
        assert!(!settings.suppress_toggle_key);
        assert_eq!(settings.paste_mode, PasteMode::Clipboard);
    }

    #[test]
    fn toggle_key_ids_round_trip() {
        for key in ToggleKey::ALL {
            assert_eq!(ToggleKey::from_id(key.id()), Some(key));
        }
        assert_eq!(ToggleKey::from_id("nope"), None);
    }

    #[test]
    fn missing_fields_fall_back_to_defaults() {
        let settings: Settings = serde_json::from_str("{}").unwrap();
        assert_eq!(settings.toggle_key, ToggleKey::RightAlt);
        assert_eq!(settings.paste_mode, PasteMode::Clipboard);
    }
}
