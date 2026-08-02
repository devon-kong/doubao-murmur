//! Launch at sign-in via the per-user Run key. No elevation needed.

use windows::core::PCWSTR;
use windows::Win32::Foundation::ERROR_SUCCESS;
use windows::Win32::System::Registry::{
    RegCloseKey, RegCreateKeyExW, RegDeleteValueW, RegOpenKeyExW, RegQueryValueExW,
    RegSetValueExW, HKEY, HKEY_CURRENT_USER, KEY_READ, KEY_WRITE, REG_OPTION_NON_VOLATILE, REG_SZ,
};

use crate::win32::wide;
use crate::{log_info, log_warn};

const RUN_KEY: &str = r"Software\Microsoft\Windows\CurrentVersion\Run";
const VALUE_NAME: &str = "DoubaoMurmur";

pub fn is_enabled() -> bool {
    let subkey = wide(RUN_KEY);
    let name = wide(VALUE_NAME);

    unsafe {
        let mut key = HKEY::default();
        if RegOpenKeyExW(
            HKEY_CURRENT_USER,
            PCWSTR(subkey.as_ptr()),
            0,
            KEY_READ,
            &mut key,
        ) != ERROR_SUCCESS
        {
            return false;
        }

        let mut size: u32 = 0;
        let status = RegQueryValueExW(
            key,
            PCWSTR(name.as_ptr()),
            None,
            None,
            None,
            Some(&mut size),
        );
        let _ = RegCloseKey(key);

        status == ERROR_SUCCESS && size > 0
    }
}

pub fn set_enabled(enabled: bool) {
    let Some(executable) = std::env::current_exe()
        .ok()
        .and_then(|path| path.to_str().map(str::to_string))
    else {
        log_warn!("Cannot change autostart: executable path unknown");
        return;
    };

    let subkey = wide(RUN_KEY);
    let name = wide(VALUE_NAME);

    unsafe {
        let mut key = HKEY::default();
        let status = RegCreateKeyExW(
            HKEY_CURRENT_USER,
            PCWSTR(subkey.as_ptr()),
            0,
            PCWSTR::null(),
            REG_OPTION_NON_VOLATILE,
            KEY_WRITE,
            None,
            &mut key,
            None,
        );
        if status != ERROR_SUCCESS {
            log_warn!("Could not open the Run key: {status:?}");
            return;
        }

        if enabled {
            // Quoted so a path containing spaces still launches.
            let command = wide(&format!("\"{executable}\""));
            let bytes = std::slice::from_raw_parts(
                command.as_ptr() as *const u8,
                command.len() * std::mem::size_of::<u16>(),
            );
            let status = RegSetValueExW(key, PCWSTR(name.as_ptr()), 0, REG_SZ, Some(bytes));
            if status != ERROR_SUCCESS {
                log_warn!("Could not write the Run value: {status:?}");
            }
        } else {
            let _ = RegDeleteValueW(key, PCWSTR(name.as_ptr()));
        }

        let _ = RegCloseKey(key);
    }

    log_info!("Autostart {}", if enabled { "enabled" } else { "disabled" });
}
