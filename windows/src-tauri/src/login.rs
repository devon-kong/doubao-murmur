//! Doubao login window and credential extraction. Mirrors WebViewManager.swift.
//!
//! The page is loaded from doubao.com, so it has no Tauri IPC bridge — and giving
//! a remote origin one would be a poor trade. Instead the injected script mirrors
//! the two localStorage ids, and a "profile API said we are logged in" marker,
//! into first-party cookies. The host then reads those in the same call that
//! returns the HttpOnly session cookies, so the whole handshake needs exactly one
//! Tauri API and no COM interop.

use std::collections::BTreeMap;

use serde::Deserialize;
use tauri::{AppHandle, Manager, WebviewUrl, WebviewWindow, WebviewWindowBuilder};

use crate::config;
use crate::params::AsrParams;
use crate::{log_info, log_warn};

pub const WINDOW_LABEL: &str = "login";

/// Cookie names that only exist once an account session is established.
const SESSION_COOKIE_HINTS: &[&str] = &[
    "sessionid",
    "sessionid_ss",
    "sid_tt",
    "uid_tt",
    "passport_auth_status",
];

const INIT_SCRIPT: &str = r#"
(function () {
  'use strict';

  // Keep timers and session keep-alive requests running while the window is
  // hidden, matching inject-websocket.js on the other platforms.
  try {
    Object.defineProperty(document, 'visibilityState', {
      get: function () { return 'visible'; }, configurable: true
    });
    Object.defineProperty(document, 'hidden', {
      get: function () { return false; }, configurable: true
    });
    document.addEventListener('visibilitychange', function (e) {
      e.stopImmediatePropagation();
    }, true);
  } catch (e) {}

  function setCookie(name, value) {
    document.cookie = name + '=' + encodeURIComponent(value) + ';path=/';
  }

  function markLoggedIn() { setCookie('__dm_login', '1'); }

  function publishIds() {
    var device = '', web = '', unique = '';
    try {
      var raw = localStorage.getItem('samantha_web_web_id');
      if (raw) { device = String(JSON.parse(raw).web_id || ''); }
    } catch (e) {}
    try {
      var tea = localStorage.getItem('__tea_cache_tokens_497858');
      if (tea) {
        var parsed = JSON.parse(tea);
        web = String(parsed.web_id || '');
        unique = String(parsed.user_unique_id || '');
      }
    } catch (e) {}
    if (!web && !device) { return; }
    setCookie('__dm_ids', JSON.stringify({ d: device, w: web, u: unique }));
  }

  // Login detection watches the same profile API the macOS and Linux builds do.
  var originalFetch = window.fetch;
  window.fetch = function () {
    var target = arguments[0];
    var href = (typeof target === 'string') ? target : (target && target.url) || '';
    var promise = originalFetch.apply(this, arguments);
    if (href.indexOf('/alice/profile/self') !== -1) {
      promise.then(function (response) {
        response.clone().json().then(function (data) {
          if (data && data.code === 0 && data.data && data.data.profile_brief) {
            markLoggedIn();
          }
        }).catch(function () {});
      }).catch(function () {});
    }
    return promise;
  };

  var originalOpen = XMLHttpRequest.prototype.open;
  var originalSend = XMLHttpRequest.prototype.send;
  XMLHttpRequest.prototype.open = function (method, url) {
    this.__dmUrl = url;
    return originalOpen.apply(this, arguments);
  };
  XMLHttpRequest.prototype.send = function () {
    if (this.__dmUrl && String(this.__dmUrl).indexOf('/alice/profile/self') !== -1) {
      this.addEventListener('load', function () {
        try {
          var data = JSON.parse(this.responseText);
          if (data && data.code === 0 && data.data && data.data.profile_brief) {
            markLoggedIn();
          }
        } catch (e) {}
      });
    }
    return originalSend.apply(this, arguments);
  };

  publishIds();
  setInterval(publishIds, 800);
})();
"#;

/// Must run on the main thread.
pub fn build(app: &AppHandle) -> Result<WebviewWindow, String> {
    let url = tauri::Url::parse(config::LOGIN_URL).map_err(|e| e.to_string())?;

    WebviewWindowBuilder::new(app, WINDOW_LABEL, WebviewUrl::External(url))
        .title("Doubao Murmur - 登录豆包")
        .inner_size(1280.0, 860.0)
        .center()
        .resizable(true)
        .user_agent(config::WEBVIEW_USER_AGENT)
        // Unpackaged apps must name their own WebView2 profile directory.
        .data_directory(config::local_dir().join("WebView2"))
        .initialization_script(INIT_SCRIPT)
        .build()
        .map_err(|e| e.to_string())
}

#[derive(Debug, Default, Deserialize)]
struct Ids {
    #[serde(default)]
    d: String,
    #[serde(default)]
    w: String,
    #[serde(default)]
    u: String,
}

/// Reads the live session out of the login window. Returns None until the user
/// has actually signed in.
pub fn extract(window: &WebviewWindow) -> Option<AsrParams> {
    let url = tauri::Url::parse(config::ORIGIN).ok()?;
    let cookies = match window.cookies_for_url(url) {
        Ok(cookies) => cookies,
        Err(e) => {
            log_warn!("Could not read cookies: {e}");
            return None;
        }
    };

    let mut collected: BTreeMap<String, String> = BTreeMap::new();
    let mut ids_raw: Option<String> = None;
    let mut login_marker = false;

    for cookie in cookies {
        let name = cookie.name().to_string();
        let value = cookie.value().to_string();

        if name == config::IDS_COOKIE {
            ids_raw = Some(value);
        } else if name == config::LOGIN_COOKIE {
            login_marker = true;
        } else {
            collected.insert(name, value);
        }
    }

    if collected.is_empty() {
        return None;
    }

    let has_session = collected
        .keys()
        .any(|name| SESSION_COOKIE_HINTS.contains(&name.as_str()));
    if !login_marker && !has_session {
        return None;
    }

    let ids: Ids = serde_json::from_str(&percent_decode(ids_raw.as_deref()?)).ok()?;
    if ids.w.is_empty() && ids.d.is_empty() {
        return None;
    }

    let web_id = if ids.w.is_empty() {
        ids.d.clone()
    } else {
        ids.w.clone()
    };

    // doubao.com dropped samantha_web_web_id when it renamed its localStorage
    // keys; the tea SDK cache still carries the same id (Linux commit 538c950).
    let device_id = if !ids.d.is_empty() {
        ids.d
    } else if !ids.u.is_empty() {
        ids.u
    } else {
        web_id.clone()
    };

    let params = AsrParams {
        cookies: collected,
        device_id,
        web_id,
    };

    if !params.is_usable() {
        return None;
    }

    log_info!(
        "Extracted {} cookies, device={}, web={}",
        params.cookies.len(),
        preview(&params.device_id),
        preview(&params.web_id)
    );
    Some(params)
}

/// Drops the two marker cookies so they are not sent to doubao.com again.
pub fn clear_markers(window: &WebviewWindow) {
    let script = format!(
        "document.cookie='{}=;path=/;expires=Thu, 01 Jan 1970 00:00:00 GMT';\
         document.cookie='{}=;path=/;expires=Thu, 01 Jan 1970 00:00:00 GMT';",
        config::IDS_COOKIE,
        config::LOGIN_COOKIE
    );
    let _ = window.eval(&script);
}

fn preview(value: &str) -> String {
    if value.chars().count() <= 6 {
        "*".repeat(value.chars().count())
    } else {
        format!("{}…", value.chars().take(6).collect::<String>())
    }
}

fn percent_decode(input: &str) -> String {
    let bytes = input.as_bytes();
    let mut out = Vec::with_capacity(bytes.len());
    let mut index = 0;

    while index < bytes.len() {
        if bytes[index] == b'%' && index + 3 <= bytes.len() {
            if let Ok(byte) = u8::from_str_radix(&input[index + 1..index + 3], 16) {
                out.push(byte);
                index += 3;
                continue;
            }
        }
        out.push(bytes[index]);
        index += 1;
    }

    String::from_utf8_lossy(&out).into_owned()
}

pub fn is_open(app: &AppHandle) -> bool {
    app.get_webview_window(WINDOW_LABEL).is_some()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn percent_decoding_round_trips_the_ids_payload() {
        let encoded = "%7B%22d%22%3A%221%22%2C%22w%22%3A%222%22%2C%22u%22%3A%223%22%7D";
        assert_eq!(percent_decode(encoded), r#"{"d":"1","w":"2","u":"3"}"#);
    }

    #[test]
    fn percent_decoding_leaves_plain_text_alone() {
        assert_eq!(percent_decode("abc123"), "abc123");
    }

    #[test]
    fn percent_decoding_tolerates_a_trailing_escape() {
        assert_eq!(percent_decode("ab%"), "ab%");
        assert_eq!(percent_decode("ab%2"), "ab%2");
    }

    #[test]
    fn ids_payload_parses() {
        let ids: Ids = serde_json::from_str(r#"{"d":"dev","w":"web","u":"uniq"}"#).unwrap();
        assert_eq!(ids.d, "dev");
        assert_eq!(ids.w, "web");
        assert_eq!(ids.u, "uniq");
    }

    #[test]
    fn ids_payload_tolerates_missing_fields() {
        let ids: Ids = serde_json::from_str(r#"{"w":"web"}"#).unwrap();
        assert!(ids.d.is_empty());
        assert_eq!(ids.w, "web");
    }

    #[test]
    fn preview_masks_short_values() {
        assert_eq!(preview("abc"), "***");
        assert_eq!(preview("abcdefghij"), "abcdef…");
    }

    #[test]
    fn the_injected_script_publishes_both_markers() {
        assert!(INIT_SCRIPT.contains(config::IDS_COOKIE));
        assert!(INIT_SCRIPT.contains(config::LOGIN_COOKIE));
        assert!(INIT_SCRIPT.contains("/alice/profile/self"));
    }
}
