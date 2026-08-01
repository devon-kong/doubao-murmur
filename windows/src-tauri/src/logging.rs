//! Minimal file logger. This is a background tray process with no console, so the
//! log file is the only way to diagnose a failed hotkey, paste or connection.

use std::fs::OpenOptions;
use std::io::Write;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Mutex;
use std::time::{SystemTime, UNIX_EPOCH};

use crate::config;

static GATE: Mutex<()> = Mutex::new(());
static BROKEN: AtomicBool = AtomicBool::new(false);

const MAX_BYTES: u64 = 2 * 1024 * 1024;

pub fn write(level: &str, message: &str) {
    let line = format!("{} [{}] {}", timestamp(), level, message);
    #[cfg(debug_assertions)]
    println!("{line}");

    if BROKEN.load(Ordering::Relaxed) {
        return;
    }

    let _guard = GATE.lock();
    if let Err(_e) = append(&line) {
        BROKEN.store(true, Ordering::Relaxed);
    }
}

fn append(line: &str) -> std::io::Result<()> {
    let path = config::log_path();
    if let Ok(meta) = std::fs::metadata(&path) {
        if meta.len() > MAX_BYTES {
            let _ = std::fs::rename(&path, path.with_extension("log.1"));
        }
    }

    let mut file = OpenOptions::new().create(true).append(true).open(&path)?;
    writeln!(file, "{line}")
}

/// Seconds since the epoch. Formatting a wall-clock date would mean pulling in a
/// time crate for something only ever read while debugging.
fn timestamp() -> String {
    match SystemTime::now().duration_since(UNIX_EPOCH) {
        Ok(d) => {
            let secs = d.as_secs();
            let millis = d.subsec_millis();
            let time_of_day = secs % 86_400;
            format!(
                "{:02}:{:02}:{:02}.{:03}",
                time_of_day / 3600,
                (time_of_day % 3600) / 60,
                time_of_day % 60,
                millis
            )
        }
        Err(_) => "??:??:??.???".to_string(),
    }
}

#[macro_export]
macro_rules! log_info {
    ($($arg:tt)*) => { $crate::logging::write("INFO ", &format!($($arg)*)) };
}

#[macro_export]
macro_rules! log_warn {
    ($($arg:tt)*) => { $crate::logging::write("WARN ", &format!($($arg)*)) };
}

#[macro_export]
macro_rules! log_error {
    ($($arg:tt)*) => { $crate::logging::write("ERROR", &format!($($arg)*)) };
}
