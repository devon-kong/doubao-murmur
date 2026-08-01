//! Notification-area icon and menu.

use tauri::menu::{CheckMenuItem, Menu, MenuItem, PredefinedMenuItem, Submenu};
use tauri::tray::TrayIconBuilder;
use tauri::{AppHandle, Manager, Wry};

use crate::controller::Event;
use crate::settings::ToggleKey;
use crate::{autostart, log_warn};

pub const TRAY_ID: &str = "main";

pub mod ids {
    pub const STATUS: &str = "status";
    pub const LOGIN: &str = "login";
    pub const LOGOUT: &str = "logout";
    pub const HELP: &str = "help";
    pub const OPEN_LOG: &str = "open_log";
    pub const CHECK_UPDATE: &str = "check_update";
    pub const AUTOSTART: &str = "autostart";
    pub const SUPPRESS: &str = "suppress";
    pub const QUIT: &str = "quit";
}

#[derive(Debug, Clone, Copy)]
pub struct TrayState {
    pub logged_in: bool,
    pub recording: bool,
    pub toggle_key: ToggleKey,
    pub suppress_toggle_key: bool,
}

fn tooltip(state: &TrayState) -> String {
    if state.recording {
        "Doubao Murmur — 正在识别…".to_string()
    } else if state.logged_in {
        format!("Doubao Murmur — 已登录（{}）", state.toggle_key.short_label())
    } else {
        "Doubao Murmur — 未登录".to_string()
    }
}

fn build_menu(app: &AppHandle, state: &TrayState) -> tauri::Result<Menu<Wry>> {
    let status = MenuItem::with_id(
        app,
        ids::STATUS,
        if state.logged_in {
            "状态：已登录"
        } else {
            "状态：未登录"
        },
        false,
        None::<&str>,
    )?;

    let session = if state.logged_in {
        MenuItem::with_id(app, ids::LOGOUT, "退出登录", true, None::<&str>)?
    } else {
        MenuItem::with_id(app, ids::LOGIN, "登录豆包", true, None::<&str>)?
    };

    let help = MenuItem::with_id(app, ids::HELP, "使用帮助", true, None::<&str>)?;

    let key_items: Vec<CheckMenuItem<Wry>> = ToggleKey::ALL
        .into_iter()
        .map(|key| {
            CheckMenuItem::with_id(
                app,
                key.id(),
                key.label(),
                true,
                key == state.toggle_key,
                None::<&str>,
            )
        })
        .collect::<tauri::Result<_>>()?;
    let key_refs: Vec<&dyn tauri::menu::IsMenuItem<Wry>> = key_items
        .iter()
        .map(|item| item as &dyn tauri::menu::IsMenuItem<Wry>)
        .collect();
    let hotkeys = Submenu::with_id_and_items(app, "hotkeys", "触发热键", true, &key_refs)?;

    let suppress = CheckMenuItem::with_id(
        app,
        ids::SUPPRESS,
        "拦截热键（避免唤出菜单栏，会禁用 AltGr）",
        true,
        state.suppress_toggle_key,
        None::<&str>,
    )?;

    let autostart_item = CheckMenuItem::with_id(
        app,
        ids::AUTOSTART,
        "开机自启",
        true,
        autostart::is_enabled(),
        None::<&str>,
    )?;

    let open_log = MenuItem::with_id(app, ids::OPEN_LOG, "打开日志", true, None::<&str>)?;
    let check_update =
        MenuItem::with_id(app, ids::CHECK_UPDATE, "检查更新", true, None::<&str>)?;
    let quit = MenuItem::with_id(app, ids::QUIT, "退出", true, None::<&str>)?;

    Menu::with_items(
        app,
        &[
            &status,
            &PredefinedMenuItem::separator(app)?,
            &session,
            &help,
            &PredefinedMenuItem::separator(app)?,
            &hotkeys,
            &suppress,
            &autostart_item,
            &PredefinedMenuItem::separator(app)?,
            &open_log,
            &check_update,
            &PredefinedMenuItem::separator(app)?,
            &quit,
        ],
    )
}

/// Must run on the main thread.
pub fn create(app: &AppHandle, state: &TrayState) -> tauri::Result<()> {
    let menu = build_menu(app, state)?;
    let icon = app
        .default_window_icon()
        .cloned()
        .ok_or_else(|| tauri::Error::AssetNotFound("default window icon".into()))?;

    TrayIconBuilder::with_id(TRAY_ID)
        .icon(icon)
        .tooltip(tooltip(state))
        .menu(&menu)
        .show_menu_on_left_click(true)
        .on_menu_event(|app, event| dispatch(app, event.id().as_ref()))
        .build(app)?;

    Ok(())
}

/// Must run on the main thread.
pub fn refresh(app: &AppHandle, state: &TrayState) {
    let Some(tray) = app.tray_by_id(TRAY_ID) else {
        return;
    };

    match build_menu(app, state) {
        Ok(menu) => {
            let _ = tray.set_menu(Some(menu));
        }
        Err(e) => log_warn!("Could not rebuild the tray menu: {e}"),
    }
    let _ = tray.set_tooltip(Some(tooltip(state)));
}

fn dispatch(app: &AppHandle, id: &str) {
    let event = match id {
        ids::LOGIN => Event::ShowLogin,
        ids::LOGOUT => Event::Logout,
        ids::HELP => Event::ShowHelp,
        ids::OPEN_LOG => Event::OpenLog,
        ids::CHECK_UPDATE => Event::CheckUpdate,
        ids::AUTOSTART => Event::ToggleAutostart,
        ids::SUPPRESS => Event::ToggleSuppress,
        ids::QUIT => Event::Quit,
        other => match ToggleKey::from_id(other) {
            Some(key) => Event::SetToggleKey(key),
            None => return,
        },
    };

    crate::controller::send(app, event);
}
