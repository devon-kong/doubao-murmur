//! Credentials needed to open a WSS ASR connection, persisted to
//! %APPDATA%\doubao-murmur\asr_params.json.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

use crate::config;
use crate::{log_error, log_info, log_warn};

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
pub struct AsrParams {
    pub cookies: BTreeMap<String, String>,
    /// The alias accepts the macOS build's file, which uses Swift's default
    /// Codable keys, so credentials can be copied over from a Mac.
    #[serde(alias = "deviceId")]
    pub device_id: String,
    #[serde(alias = "webId")]
    pub web_id: String,
}

impl AsrParams {
    pub fn cookie_header(&self) -> String {
        self.cookies
            .iter()
            .map(|(name, value)| format!("{name}={value}"))
            .collect::<Vec<_>>()
            .join("; ")
    }

    pub fn is_usable(&self) -> bool {
        !self.cookies.is_empty() && !self.device_id.is_empty() && !self.web_id.is_empty()
    }
}

pub fn load() -> Option<AsrParams> {
    let path = config::params_path();
    if !path.exists() {
        return None;
    }

    let text = match std::fs::read_to_string(&path) {
        Ok(text) => text,
        Err(e) => {
            log_error!("Failed to read params: {e}");
            return None;
        }
    };

    match serde_json::from_str::<AsrParams>(&text) {
        Ok(params) if params.is_usable() => Some(params),
        Ok(_) => {
            log_warn!("Params file present but incomplete");
            None
        }
        Err(e) => {
            log_error!("Failed to parse params: {e}");
            None
        }
    }
}

pub fn save(params: &AsrParams) {
    match serde_json::to_string_pretty(params) {
        Ok(text) => match std::fs::write(config::params_path(), text) {
            Ok(()) => log_info!("Saved ASR params ({} cookies)", params.cookies.len()),
            Err(e) => log_error!("Failed to save params: {e}"),
        },
        Err(e) => log_error!("Failed to serialise params: {e}"),
    }
}

pub fn clear() {
    match std::fs::remove_file(config::params_path()) {
        Ok(()) => log_info!("Cleared saved params"),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        Err(e) => log_error!("Failed to clear params: {e}"),
    }
}

pub fn has_saved() -> bool {
    config::params_path().exists()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cookie_header_joins_pairs() {
        let mut params = AsrParams::default();
        params.cookies.insert("a".into(), "1".into());
        params.cookies.insert("b".into(), "2".into());
        assert_eq!(params.cookie_header(), "a=1; b=2");
    }

    #[test]
    fn requires_every_field() {
        let mut params = AsrParams::default();
        assert!(!params.is_usable());

        params.cookies.insert("sessionid".into(), "s".into());
        params.device_id = "d".into();
        assert!(!params.is_usable());

        params.web_id = "w".into();
        assert!(params.is_usable());
    }

    #[test]
    fn accepts_the_macos_camel_case_file() {
        let json = r#"{"cookies":{"sessionid":"s"},"deviceId":"d","webId":"w"}"#;
        let params: AsrParams = serde_json::from_str(json).unwrap();
        assert_eq!(params.device_id, "d");
        assert_eq!(params.web_id, "w");
    }
}
