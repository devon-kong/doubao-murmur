# 豆包语音输入 (Doubao Murmur) — Windows 版

Rust + Tauri v2 实现，与 macOS (Swift) 和 Linux (Python) 版共用同一套豆包 ASR 协议。

> macOS 用户请使用仓库根目录的版本，Linux / SteamOS 用户请看 [`../linux`](../linux)。

## 功能

- ⌨️ **全局热键**：右 `Alt` 开始 / 停止识别，`ESC` 取消（任意应用中均可用）
- 📝 **实时转写**：半透明悬浮窗显示识别结果，不抢焦点、不挡输入
- 📋 **自动粘贴**：识别结果自动复制并粘贴到当前输入框
- 🔐 **登录一次**：内置 WebView2 登录豆包，凭证保存在本地
- 🛎 **系统托盘**：常驻托盘图标，可切换热键、开机自启

## 系统要求

- Windows 10 1809+ 或 Windows 11（x64 / ARM64）
- Microsoft Edge WebView2 Runtime（Windows 11 与较新的 Windows 10 已自带）

## 安装

从 [Releases](../../releases) 下载 `Doubao-Murmur-Setup-vX.Y.Z-x64.exe` 并运行，
安装到当前用户目录，**不需要管理员权限**。

> 程序未做代码签名，Windows SmartScreen 会提示「已保护你的电脑」。
> 点击「更多信息 → 仍要运行」即可。

也提供单文件免安装版 `Doubao-Murmur-vX.Y.Z-x64-portable.exe`，直接双击运行。

## 使用

1. 首次启动后，托盘图标 → 「登录豆包」，在弹出的窗口中完成登录，窗口会自动关闭
2. 把光标放到任意输入框
3. 按一下右 `Alt`，屏幕顶部出现悬浮窗，开始说话
4. 再按一下右 `Alt` 结束，文字自动粘贴到输入框
5. 想放弃这次识别就按 `ESC`

### 托盘菜单

| 项 | 说明 |
|---|---|
| 触发热键 | 右 Alt（默认）/ 右 Ctrl / 右 Shift / Scroll Lock / Pause |
| 拦截热键 | 让焦点窗口收不到该键。可避免按右 Alt 时唤出菜单栏，**但会同时禁用 AltGr**，欧洲键盘布局请勿开启 |
| 开机自启 | 写入当前用户的 `Run` 启动项，不需要管理员权限 |
| 打开日志 | `%LOCALAPPDATA%\doubao-murmur\app.log` |

### 已知限制

- **提权窗口**：焦点在以管理员身份运行的窗口（任务管理器、管理员终端等）时，
  Windows 的 UIPI 机制会让本程序既收不到按键、也粘贴不进去。需要在这类窗口里
  使用时，请同样以管理员身份运行本程序。
- **右 Alt 与菜单栏**：部分 Win32 程序里，单击 Alt 会激活菜单栏。可以打开
  「拦截热键」，或把热键改成右 Ctrl。

## 开发

### 结构

```
windows/
  ui/                       静态页面（悬浮窗、帮助），无前端构建链
  src-tauri/
    src/
      config.rs             WSS URL、固定参数、鉴权错误码、路径
      params.rs             凭证读写（兼容 macOS 的 camelCase 文件）
      asr.rs                WebSocket 客户端（tokio-tungstenite）
      audio.rs resample.rs  cpal 采集 + 降混 + 重采样到 16k mono int16
      controller.rs         状态机：idle → starting → recording → stopping
      hotkey.rs             WH_KEYBOARD_LL 全局钩子
      paste.rs              剪贴板 + SendInput
      login.rs              登录窗口与凭证提取
      overlay.rs tray.rs help.rs   Tauri 窗口与托盘
      win32.rs              WS_EX_NOACTIVATE、前台进程、消息框、单实例
    tauri.conf.json
```

### 为什么是 Tauri，以及 Tauri 没解决什么

早期版本用 C# / WinUI 3 实现，安装包 42 MB、占盘 160 MB——因为要自带 .NET 运行时、
WinUI 本身、以及整个 Windows SDK 的 CsWinRT 投影。Tauri 用系统自带的 WebView2，
安装包降到 **1.3 MB**。

但 Tauri 只替换了外壳。这个应用真正难的部分仍然是手写 Win32：

- `RegisterHotKey`（Tauri 的 global-shortcut 插件用的就是它）**注册不了裸修饰键**，
  所以 `hotkey.rs` 自己装 `WH_KEYBOARD_LL`，并在独立的消息循环线程上跑
- 该钩子要过滤 AltGr 合成的伪左 Ctrl，否则 AltGr 布局下 toggle 永不触发
  （Linux 侧 commit `37098ef` 的 Windows 对应问题）
- 悬浮窗要在第一次显示前打上 `WS_EX_NOACTIVATE`，否则识别结果会粘到它自己身上

### 登录提参的设计

登录页是 doubao.com，属于远程源，没有 Tauri IPC 桥——给第三方源开桥不划算。
所以注入脚本把两个 localStorage id、以及「profile 接口确认已登录」这个标记，
**镜像进一次性的一方 cookie**；宿主再用 `cookies_for_url()` 一次性拿到它们和
HttpOnly 会话 cookie。

整个握手只依赖一个 Tauri API，不需要 `webview2-com` 的 COM 互操作，
这是这次移植里最大的风险点，用这种方式绕开了。

### 构建

```powershell
cargo test --manifest-path windows/src-tauri/Cargo.toml
npm install -g @tauri-apps/cli@^2
cd windows; tauri build
```

CI 在每次 push 时构建并上传产物，见
[`windows-ci.yml`](../.github/workflows/windows-ci.yml)。

### 与其他平台保持一致

豆包的接口会变，历史上的热修（`samantha_web_web_id` 改名、AltGr、终端检测）都发生在
协议层。目前有 Swift / Python / Rust 三份实现，改动协议相关的东西时**三处都要同步**：

| 关注点 | macOS | Linux | Windows |
|---|---|---|---|
| WSS URL 与固定参数 | `DoubaoASRClient.swift` | `config.py` | `src/config.rs` |
| 凭证提取 | `WebViewManager.swift` | `ui/login_window.py` | `src/login.rs` |
| 状态机 | `TranscriptionManager.swift` | `transcription.py` | `src/controller.rs` |
| 注入脚本 | `Resources/inject-*.js` | `resources/inject-*.js` | `src/login.rs` 内的 `INIT_SCRIPT` |

Windows 的注入脚本没有复用另两个平台的文件：它们的登录检测靠 `postMessage` 回传宿主，
而这里改用 cookie 通道，逻辑不同。`/alice/profile/self` 的判定条件三处保持一致。
