//! Global keyboard listener built on WH_KEYBOARD_LL. Mirrors the CGEventTap on
//! macOS and the XRecord listener on Linux.
//!
//! RegisterHotKey — which Tauri's global-shortcut plugin uses — cannot bind a bare
//! modifier such as right Alt, so a low-level hook is the only option. The hook
//! needs a thread with a message pump, so it gets one of its own.
//!
//! Known limitation: UIPI stops the hook from seeing keystrokes while an elevated
//! window has focus, unless this process is elevated too.

use std::sync::atomic::{AtomicBool, AtomicI32, Ordering};
use std::sync::mpsc::Sender;
use std::sync::OnceLock;

use windows::Win32::Foundation::{HINSTANCE, HWND, LPARAM, LRESULT, WPARAM};
use windows::Win32::System::LibraryLoader::GetModuleHandleW;
use windows::Win32::UI::Input::KeyboardAndMouse::{
    VK_ESCAPE, VK_LCONTROL, VK_PAUSE, VK_RCONTROL, VK_RMENU, VK_RSHIFT, VK_SCROLL,
};
use windows::Win32::UI::WindowsAndMessaging::{
    CallNextHookEx, DispatchMessageW, GetMessageW, SetWindowsHookExW, TranslateMessage,
    HHOOK, KBDLLHOOKSTRUCT, LLKHF_INJECTED, MSG, WH_KEYBOARD_LL, WM_KEYDOWN, WM_KEYUP,
    WM_SYSKEYDOWN, WM_SYSKEYUP,
};

use crate::settings::ToggleKey;
use crate::{log_error, log_info};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum HotkeyEvent {
    Toggle,
    Cancel,
}

static TOGGLE_VK: AtomicI32 = AtomicI32::new(0xA5);
static SUPPRESS: AtomicBool = AtomicBool::new(false);
static TOGGLE_DOWN: AtomicBool = AtomicBool::new(false);
static OTHER_KEY_PRESSED: AtomicBool = AtomicBool::new(false);
static SENDER: OnceLock<Sender<HotkeyEvent>> = OnceLock::new();

pub fn virtual_key_for(key: ToggleKey) -> i32 {
    let vk = match key {
        ToggleKey::RightAlt => VK_RMENU,
        ToggleKey::RightControl => VK_RCONTROL,
        ToggleKey::RightShift => VK_RSHIFT,
        ToggleKey::ScrollLock => VK_SCROLL,
        ToggleKey::Pause => VK_PAUSE,
    };
    vk.0 as i32
}

pub fn apply(key: ToggleKey, suppress: bool) {
    TOGGLE_VK.store(virtual_key_for(key), Ordering::Relaxed);
    SUPPRESS.store(suppress, Ordering::Relaxed);
    log_info!("Hotkey set to {:?}, suppress={suppress}", key);
}

/// Installs the hook on a dedicated thread and pumps messages there forever.
pub fn start(sender: Sender<HotkeyEvent>, key: ToggleKey, suppress: bool) {
    apply(key, suppress);
    if SENDER.set(sender).is_err() {
        return;
    }

    std::thread::spawn(|| unsafe {
        let module = match GetModuleHandleW(None) {
            Ok(module) => module,
            Err(e) => {
                log_error!("GetModuleHandle failed: {e}");
                return;
            }
        };

        let hook = match SetWindowsHookExW(
            WH_KEYBOARD_LL,
            Some(hook_proc),
            HINSTANCE(module.0),
            0,
        ) {
            Ok(hook) => hook,
            Err(e) => {
                log_error!("SetWindowsHookEx failed: {e}");
                return;
            }
        };
        log_info!("Keyboard hook installed");

        let mut message = MSG::default();
        while GetMessageW(&mut message, HWND::default(), 0, 0).as_bool() {
            let _ = TranslateMessage(&message);
            DispatchMessageW(&message);
        }

        let _ = windows::Win32::UI::WindowsAndMessaging::UnhookWindowsHookEx(hook);
    });
}

unsafe extern "system" fn hook_proc(code: i32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
    if code < 0 {
        return CallNextHookEx(HHOOK::default(), code, wparam, lparam);
    }

    if process(wparam, lparam) {
        return LRESULT(1);
    }

    CallNextHookEx(HHOOK::default(), code, wparam, lparam)
}

/// Returns true when the event should be swallowed.
unsafe fn process(wparam: WPARAM, lparam: LPARAM) -> bool {
    let info = &*(lparam.0 as *const KBDLLHOOKSTRUCT);
    let message = wparam.0 as u32;

    let is_down = message == WM_KEYDOWN || message == WM_SYSKEYDOWN;
    let is_up = message == WM_KEYUP || message == WM_SYSKEYUP;
    if !is_down && !is_up {
        return false;
    }

    let vk = info.vkCode as i32;
    let toggle_vk = TOGGLE_VK.load(Ordering::Relaxed);

    if vk == toggle_vk {
        if is_down {
            // Guard against auto-repeat clearing the "no other key" flag.
            if !TOGGLE_DOWN.swap(true, Ordering::Relaxed) {
                OTHER_KEY_PRESSED.store(false, Ordering::Relaxed);
            }
        } else {
            let fire = TOGGLE_DOWN.swap(false, Ordering::Relaxed)
                && !OTHER_KEY_PRESSED.load(Ordering::Relaxed);
            if fire {
                emit(HotkeyEvent::Toggle);
            }
        }
        return SUPPRESS.load(Ordering::Relaxed);
    }

    if !is_down {
        return false;
    }

    // Pressing AltGr synthesises a left-Ctrl down. Counting it as "another key"
    // would mean the toggle never fires on layouts that have AltGr — the Windows
    // counterpart of the Linux AltGr fix in commit 37098ef.
    let synthetic_altgr_control = vk == VK_LCONTROL.0 as i32
        && ((info.flags.0 & LLKHF_INJECTED.0) != 0 || (info.scanCode & 0x200) != 0);
    if synthetic_altgr_control {
        return false;
    }

    if TOGGLE_DOWN.load(Ordering::Relaxed) {
        OTHER_KEY_PRESSED.store(true, Ordering::Relaxed);
    }

    // ESC cancels. Never swallowed: the focused app still needs its Escape.
    if vk == VK_ESCAPE.0 as i32 {
        emit(HotkeyEvent::Cancel);
    }

    false
}

fn emit(event: HotkeyEvent) {
    if let Some(sender) = SENDER.get() {
        // Never block inside the hook: a stalled callback freezes input for the
        // whole desktop.
        let _ = sender.send(event);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_toggle_key_maps_to_a_virtual_key() {
        assert_eq!(virtual_key_for(ToggleKey::RightAlt), 0xA5);
        assert_eq!(virtual_key_for(ToggleKey::RightControl), 0xA3);
        assert_eq!(virtual_key_for(ToggleKey::RightShift), 0xA1);
        assert_eq!(virtual_key_for(ToggleKey::ScrollLock), 0x91);
        assert_eq!(virtual_key_for(ToggleKey::Pause), 0x13);
    }
}
