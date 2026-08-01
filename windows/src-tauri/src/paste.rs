//! Copies the transcription to the clipboard and synthesises the paste shortcut.
//! Mirrors PasteHelper.swift.

use windows::Win32::UI::Input::KeyboardAndMouse::{
    GetAsyncKeyState, SendInput, INPUT, INPUT_0, INPUT_KEYBOARD, KEYBDINPUT, KEYBD_EVENT_FLAGS,
    KEYEVENTF_EXTENDEDKEY, KEYEVENTF_KEYUP, KEYEVENTF_SCANCODE, KEYEVENTF_UNICODE, VIRTUAL_KEY,
    VK_LCONTROL, VK_LMENU, VK_LSHIFT, VK_LWIN, VK_RCONTROL, VK_RMENU, VK_RSHIFT, VK_RWIN,
};

use crate::settings::PasteMode;
use crate::win32;
use crate::{log_error, log_info, log_warn};

// Scan codes (set 1).
const SC_LCONTROL: u16 = 0x1D;
const SC_LSHIFT: u16 = 0x2A;
const SC_V: u16 = 0x2F;
const SC_INSERT: u16 = 0x52;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Shortcut {
    CtrlV,
    CtrlShiftV,
    ShiftInsert,
}

/// Apps whose paste shortcut is not Ctrl+V. Windows Terminal and modern conhost
/// both accept Ctrl+V, so unlike Linux this list stays very short.
fn shortcut_for(process: Option<&str>) -> Shortcut {
    match process {
        Some("mintty") => Shortcut::CtrlShiftV, // Git Bash / Cygwin
        Some("putty") => Shortcut::ShiftInsert,
        Some("kitty") | Some("alacritty") | Some("wezterm-gui") => Shortcut::CtrlShiftV,
        _ => Shortcut::CtrlV,
    }
}

pub fn deliver(text: &str, mode: PasteMode) {
    if text.is_empty() {
        return;
    }

    if mode == PasteMode::Typing {
        release_stuck_modifiers();
        type_unicode(text);
        log_info!("Typed {} chars directly", text.chars().count());
        return;
    }

    if let Err(e) = copy_to_clipboard(text) {
        log_error!("Clipboard write failed: {e}");
        return;
    }

    std::thread::sleep(crate::config::PASTE_DELAY);

    let process = win32::foreground_process_name();
    let shortcut = shortcut_for(process.as_deref());

    release_stuck_modifiers();
    send_shortcut(shortcut);
    log_info!(
        "Pasted into '{}' using {shortcut:?}",
        process.as_deref().unwrap_or("unknown")
    );
}

pub fn copy_to_clipboard(text: &str) -> Result<(), String> {
    // arboard retries internally when another process holds the clipboard open,
    // which is the most common cause of a dropped paste.
    let mut clipboard = arboard::Clipboard::new().map_err(|e| e.to_string())?;
    clipboard.set_text(text.to_string()).map_err(|e| e.to_string())
}

/// Drops any modifier the user might still be holding. Without this a held Alt
/// turns our Ctrl+V into Ctrl+Alt+V and nothing is pasted.
fn release_stuck_modifiers() {
    let modifiers = [
        VK_LMENU, VK_RMENU, VK_LCONTROL, VK_RCONTROL, VK_LSHIFT, VK_RSHIFT, VK_LWIN, VK_RWIN,
    ];

    let mut inputs = Vec::new();
    for key in modifiers {
        let down = unsafe { GetAsyncKeyState(key.0 as i32) };
        if (down as u16 & 0x8000) == 0 {
            continue;
        }
        inputs.push(key_input(key.0, 0, KEYEVENTF_KEYUP));
    }

    if !inputs.is_empty() {
        send(&inputs);
    }
}

fn send_shortcut(shortcut: Shortcut) {
    let inputs = match shortcut {
        Shortcut::CtrlShiftV => vec![
            scan_input(SC_LCONTROL, false, false),
            scan_input(SC_LSHIFT, false, false),
            scan_input(SC_V, false, false),
            scan_input(SC_V, true, false),
            scan_input(SC_LSHIFT, true, false),
            scan_input(SC_LCONTROL, true, false),
        ],
        Shortcut::ShiftInsert => vec![
            scan_input(SC_LSHIFT, false, false),
            scan_input(SC_INSERT, false, true),
            scan_input(SC_INSERT, true, true),
            scan_input(SC_LSHIFT, true, false),
        ],
        Shortcut::CtrlV => vec![
            scan_input(SC_LCONTROL, false, false),
            scan_input(SC_V, false, false),
            scan_input(SC_V, true, false),
            scan_input(SC_LCONTROL, true, false),
        ],
    };

    send(&inputs);
}

fn type_unicode(text: &str) {
    let mut inputs = Vec::new();
    for unit in text.encode_utf16() {
        inputs.push(key_input(0, unit, KEYEVENTF_UNICODE));
        inputs.push(key_input(0, unit, KEYEVENTF_UNICODE | KEYEVENTF_KEYUP));

        // Chunked so a long transcription does not allocate one huge block and
        // so the target app can keep up.
        if inputs.len() >= 200 {
            send(&inputs);
            inputs.clear();
        }
    }

    if !inputs.is_empty() {
        send(&inputs);
    }
}

/// Scan-code input: some apps and games ignore virtual-key events.
fn scan_input(scan_code: u16, key_up: bool, extended: bool) -> INPUT {
    let mut flags = KEYEVENTF_SCANCODE;
    if key_up {
        flags |= KEYEVENTF_KEYUP;
    }
    if extended {
        flags |= KEYEVENTF_EXTENDEDKEY;
    }
    key_input(0, scan_code, flags)
}

fn key_input(virtual_key: u16, scan_code: u16, flags: KEYBD_EVENT_FLAGS) -> INPUT {
    INPUT {
        r#type: INPUT_KEYBOARD,
        Anonymous: INPUT_0 {
            ki: KEYBDINPUT {
                wVk: VIRTUAL_KEY(virtual_key),
                wScan: scan_code,
                dwFlags: flags,
                time: 0,
                dwExtraInfo: 0,
            },
        },
    }
}

fn send(inputs: &[INPUT]) {
    let sent = unsafe { SendInput(inputs, std::mem::size_of::<INPUT>() as i32) };
    if sent as usize != inputs.len() {
        // Most common cause: the focused window belongs to an elevated process and
        // UIPI blocks synthetic input from this non-elevated one.
        log_warn!(
            "SendInput delivered {sent}/{} events; is the target window elevated?",
            inputs.len()
        );
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn terminals_that_need_ctrl_shift_v_are_recognised() {
        assert_eq!(shortcut_for(Some("mintty")), Shortcut::CtrlShiftV);
        assert_eq!(shortcut_for(Some("putty")), Shortcut::ShiftInsert);
    }

    #[test]
    fn everything_else_uses_plain_ctrl_v() {
        assert_eq!(shortcut_for(Some("chrome")), Shortcut::CtrlV);
        // Windows Terminal handles Ctrl+V itself.
        assert_eq!(shortcut_for(Some("windowsterminal")), Shortcut::CtrlV);
        assert_eq!(shortcut_for(None), Shortcut::CtrlV);
    }
}
