# Windows 原生支持实施计划

技术栈：**原生 C# / .NET + WinUI 3**，代码放在 `windows/` 独立一份，不改动 `linux/`。

## 已知取舍（决策前提，非待议项）

1. **协议层将成为第三份平行实现**（Swift / Python / C#）。git log 显示最近的热修全在协议层
   （`samantha_web_web_id` 改名、AltGr、终端检测），三份同步是长期成本。缓解措施见 Phase 3 的
   协议契约文档。
2. **WinUI 3 对本应用形态是其最弱场景**：「托盘常驻 + 无边框不抢焦点半透明悬浮窗」在 WinUI 3 下
   托盘要靠第三方包或 P/Invoke，逐像素透明不支持，`WS_EX_NOACTIVATE` 也得 P/Invoke。同为
   C#/.NET，换 WPF 这三处均原生解决。本计划按 WinUI 3 编写，但把这三处隔离在 `UI/` 层，
   若 Phase 0 spike 阶段觉得别扭，切 WPF 只影响该层。

---

## 一、目录结构

拆成三个工程，而不是一个：xUnit 无法方便地引用 WinUI 工程，把 Core 独立出来才能让状态机
在没有 WinUI 的环境里被完整测试。

```
windows/
  PLAN.md  README.md  Directory.Build.props
  src/DoubaoMurmur.Core/             # net8.0-windows 类库，零 UI 依赖，可单测
    AppConfig.cs                     # WSS URL / 固定参数 / 鉴权错误码 / 路径
    AppState.cs                      # INotifyPropertyChanged; LoginStatus, RecordingState
    AsrParams.cs  AsrParamsStore.cs  # %APPDATA%\doubao-murmur\asr_params.json
    IAsrClient.cs  DoubaoAsrClient.cs# ClientWebSocket
    IAudioSource.cs                  # 音频源抽象（见「四、构建与验证环境」）
    WasapiMicSource.cs               # NAudio WasapiCapture + 降混 + 重采样
    WavFileSource.cs                 # 测试用：把 WAV 按实时节奏喂进管道
    IDispatcher.cs                   # UI 线程调度抽象，隔离 WinUI
    TranscriptionManager.cs          # 状态机
    AppSettings.cs  UpdateChecker.cs  Log.cs
  src/DoubaoMurmur.App/              # WinUI 3 外壳，unpackaged + self-contained
    App.xaml(.cs)                    # 生命周期、单实例、组件装配
    Platform/                        # Win32 互操作
      NativeMethods.cs  LowLevelKeyboardHook.cs  HotkeyManager.cs
      PasteHelper.cs  ForegroundWindowInfo.cs
      TrayIcon.cs                    # Shell_NotifyIcon + 消息窗口 + Win32 弹出菜单
      WindowHelper.cs  WinUiDispatcher.cs  AutoStart.cs  SingleInstance.cs
    UI/
      OverlayWindow.xaml(.cs)  LoginWindow.xaml(.cs)  HelpWindow.xaml(.cs)
      Dialogs.cs                     # 原生 MessageBox（托盘应用没有稳定的 XamlRoot）
    Assets/  inject-websocket.js  inject-dom.js  AppIcon.ico
    app.manifest                     # PerMonitorV2
  tools/DoubaoMurmur.Diag/           # 控制台诊断工具
  tests/DoubaoMurmur.Tests/          # xUnit
  installer/installer.iss            # Inno Setup（放 installer/ 而非 build/：
                                     #  根 .gitignore 忽略了 build/）
.github/workflows/windows-ci.yml     # 每次 push：单测 + 出产物
.github/workflows/windows-release.yml# v* tag：x64 + ARM64，附加到 Release
```

---

## 二、Swift → C# 映射

| macOS | Windows | 关键 API |
|---|---|---|
| `DoubaoASRClient.swift` | `DoubaoAsrClient.cs` | `ClientWebSocket`；cookie 用 `Options.Cookies = CookieContainer`（比 `SetRequestHeader("Cookie")` 稳，后者在部分运行时算受限 header），`Origin` 用 `SetRequestHeader` |
| `AudioCaptureManager.swift` | `WasapiMicSource.cs` | NAudio `WasapiCapture`（设备原生 48kHz float32）→ `WdlResamplingSampleProvider` → `SampleToWaveProvider16` → 16kHz/mono/int16 |
| `ASRParamsStore.swift` | `AsrParamsStore.cs` | `System.Text.Json` |
| `TranscriptionManager.swift` | 同名 | `DispatcherQueue.TryEnqueue` 替 `DispatchQueue.main.async`；`DispatcherQueueTimer` 替 `asyncAfter` |
| `HotkeyManager.swift`(CGEventTap) | `LowLevelKeyboardHook.cs` | `SetWindowsHookEx(WH_KEYBOARD_LL)` |
| `PasteHelper.swift` | 同名 | `SetClipboardData(CF_UNICODETEXT)` + `SendInput` |
| `WebViewManager.swift`(WKWebView) | `LoginWindow.xaml.cs` | WebView2 |
| `OverlayPanel/OverlayView.swift` | `OverlayWindow.xaml` | AppWindow + P/Invoke |
| `UpdateChecker.swift` | 同名 | `HttpClient` + `AllowAutoRedirect=false` 读 Location |

---

## 三、四个技术难点

### 1. 登录提参（C# 这块反而最舒服）

```csharp
await webView.EnsureCoreWebView2Async(env);   // env 必须显式指定 userDataFolder
var core = webView.CoreWebView2;
core.Settings.UserAgent = WindowsChromeUa;
await core.AddScriptToExecuteOnDocumentCreatedAsync(injectWs);   // document-start, 全 frame
core.WebMessageReceived += OnWebMessage;                          // window.chrome.webview.postMessage
var cookies = await core.CookieManager.GetCookiesAsync(Origin);   // 含 HttpOnly ✅
var json    = await core.ExecuteScriptAsync(readLocalStorageJs);
```

- **JS 复用策略**：`inject-*.js` 从 `linux/src/doubao_murmur/resources/` 拷过来，加载时在 C# 侧字符串
  替换 `window.webkit.messageHandlers.asr_handler.postMessage(x)` →
  `window.chrome.webview.postMessage(JSON.stringify(x))`。与 Linux 版同样手法，避免 JS 三份分叉。
- 登录检测保持三路冗余：JS 拦 `/alice/profile/self` → `NavigationStarting` 查 `from_login=1`
  → DOM 轮询 `to_login_button`。
- 提参后 `Close()` WebView + 销毁窗口（对应 `destroyWebView()`）。登出用
  `core.Profile.ClearBrowsingDataAsync()`。
- **坑**：未打包应用必须显式
  `CoreWebView2Environment.CreateAsync(userDataFolder: %LOCALAPPDATA%\doubao-murmur\WebView2)`，
  否则默认在 exe 同级建目录，装在 Program Files 下直接失败。

### 2. 右 Alt 全局热键

`RegisterHotKey` 注册不了裸修饰键，必须低级钩子。五个坑：

- **delegate 必须静态强引用**，否则 GC 回收后钩子静默失效 —— C# 装钩子的经典 bug。
- **钩子回调里绝不做 I/O**：回调阻塞会卡住全系统输入。只判状态，动作用
  `DispatcherQueue.TryEnqueue` 派发。
- **AltGr 陷阱**：AltGr 布局按 AltGr 会合成伪 `LCONTROL`（`scanCode` 带 `0x200` 位 /
  `LLKHF_INJECTED`）。不过滤的话「右 Alt 期间按了其他键」永远成立，toggle 永不触发。这是
  Linux 侧 commit `37098ef` 的 Windows 对应问题。
- **裸 Alt 抬起会激活菜单栏/Ribbon**。要么吞掉 RAlt 的 down+up、检测到后续键时用 SendInput
  补发真 RAlt（脆但体验好），要么接受菜单闪一下。建议热键从一开始就可配置，默认右 Alt。
- **UIPI 硬限制**：焦点在提权窗口（任务管理器、管理员终端）时钩子收不到键、SendInput 也粘不进去。
  文档说明 + 可选「以管理员运行」。

### 3. 悬浮窗（WinUI 3 需要 P/Invoke 的三处）

- `WindowNative.GetWindowHandle` →
  `SetWindowLong(GWL_EXSTYLE, WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW)`。
  **这是整个应用的命门**：悬浮窗一旦抢焦点，识别结果就粘到自己身上了。
- `AppWindow.IsShownInSwitchers = false`；`OverlappedPresenter.SetBorderAndTitleBar(false, false)`；
  `IsAlwaysOnTop = true`。
- WinUI3 无逐像素透明 → 深色不透明背景 + `DwmSetWindowAttribute(DWMWA_WINDOW_CORNER_PREFERENCE)`
  做圆角，或用 `DesktopAcrylicBackdrop`。
- 定位用 `DisplayArea.GetFromPoint` 顶部居中；可拖动，位置存
  `%APPDATA%\doubao-murmur\overlay.json`（对齐 Linux 行为）。

### 4. 粘贴

- 剪贴板写入**必须重试**（约 10 次 × 50ms）—— 剪贴板经常被其他进程锁住，这是 Windows 上最常见
  的偶发失败。
- `SendInput` 用 `KEYEVENTF_SCANCODE` 变体，兼容只读扫描码的应用/游戏。
- 终端处理比 Linux 简单：Windows Terminal / 新 conhost 都吃 Ctrl+V。只需给少数例外留映射表：
  `mintty.exe`(Git Bash) → Ctrl+Shift+V，`putty.exe` → Shift+Insert。通过
  `GetForegroundWindow` → `GetWindowThreadProcessId` → `QueryFullProcessImageName` 取进程名。
- 兜底：`KEYEVENTF_UNICODE` 逐字输入（不动剪贴板），作为设置项。

### 其他 Windows 专属

- 单实例：`AppInstance.FindOrRegisterForKey` + `RedirectActivationToAsync`（Windows App SDK 对
  未打包应用也支持），第二次启动唤出控制面板。
- 托盘：WinUI3 无内置。用 `H.NotifyIcon.WinUI`（NuGet, MIT）或自行 P/Invoke `Shell_NotifyIcon`。
  菜单：登录豆包 / 退出登录 / 使用帮助 / 开机自启 / 检查更新 / 退出；图标随录音状态切换。
- 开机自启：`HKCU\Software\Microsoft\Windows\CurrentVersion\Run`，托盘加勾选项。
- 麦克风：Win11 有「允许桌面应用访问麦克风」开关，采集失败时提示并跳
  `ms-settings:privacy-microphone`。
- 更新：照搬 `UpdateChecker.swift`（不跟随重定向读 Location 拿 tag）；v1 只做「提示 + 打开下载页」，
  不做自动安装。

---

## 四、构建与验证环境

开发主机是 Apple Silicon macOS，没有本地 .NET/Windows 工具链；验证在维护者自己的
Windows 机器上进行。所以：**CI 负责编译与出产物，真机负责验证。**

### CI 做的（GitHub Actions `windows-latest`）

`windows-ci.yml` 在每次 push 时运行，产出三份 artifact：

| Artifact | 内容 |
|---|---|
| `DoubaoMurmur-win-x64` | 免安装目录，直接跑 `DoubaoMurmur.exe` |
| `DoubaoMurmur-installer-win-x64` | Inno Setup 安装包 |
| `DoubaoMurmur-diag-win-x64` | 控制台诊断工具 |

外加 Core 层 xUnit（状态机、URL 构造、鉴权错误码、凭证读写、版本比较）。
`windows-release.yml` 在打 `v*` tag 时同时出 x64 与 ARM64，并附加到 Release。

### CI 覆盖不到、只能真机验证的

豆包登录提参（要扫码）、麦克风采集（runner 无音频设备）、粘贴到真实应用、悬浮窗不抢焦点、
AltGr 布局、DPI / 多显示器、提权窗口限制。

### 两个为可测性而定的设计约束

1. **`IAudioSource` 抽象**：`WasapiMicSource` 用于生产，`WavFileSource` 把 WAV 按实时节奏
   喂进管道。「连 WSS → 推音频 → 收识别结果」这条链路因此可以脱离麦克风运行。
2. **Core 层零 UI 依赖**：`Core/` 不引用任何 `Microsoft.UI.*`，UI 线程调度通过 `IDispatcher`
   注入，状态机可以在没有 WinUI 的情况下被完整单测。

### 凭证安全

本仓库是公开仓库。**不要把真实豆包 cookie 放进 GitHub Secrets**：公开仓库的 secret 可被恶意
分支或 workflow 改动读取，而这些 cookie 等价于账号登录态。需要真实凭证的验证一律在本机进行，
`asr_params.json` 不出本机。诊断工具只打印 cookie 名称与掩码后的 id，不打印任何凭证值。

---

## 五、阶段划分

### Phase 0 — 风险验证（在维护者的 Windows 机器上，按顺序做）

诊断工具 `DoubaoMurmur.Diag` 就是为这一阶段准备的，它把「豆包连接是否正常」和
「WinUI 外壳是否接好」两类问题彻底分开。

1. **S2 最先做** —— 成本最低的端到端验证。把 macOS/Linux 装机的 `asr_params.json` 拷到
   `%APPDATA%\doubao-murmur\`，跑 `DoubaoMurmur.Diag asr 8`：裸连 WSS、推麦克风音频、打印识别
   结果。**同时验证** `ClientWebSocket` 能否带上 `Cookie` / `Origin` 头。若此处不通（豆包拒绝
   Windows 来源连接），整个方案需重新设计。
2. **S1** —— 主程序里真实登录一次，确认能导出全部 HttpOnly cookie + 两个 localStorage 值，
   写出合法的 `asr_params.json`（用 `DoubaoMurmur.Diag params` 复核）。
3. **S3** —— 热键 + 粘贴 + 悬浮窗不抢焦点，在 Notepad / Chrome / Windows Terminal / VS Code
   冒烟；并切到 AltGr 布局（de / fr）验证伪 LCtrl 过滤。

### Phase 1 — Core 层

`AppConfig` / `AppState` / `AsrParams(+Store)` / `DoubaoAsrClient` / `IAudioSource` +
`WasapiMicSource` + `WavFileSource` / `TranscriptionManager`，配 xUnit：URL 构造、消息解析、
鉴权错误码识别、状态机迁移、Store 往返、WavFileSource → mock WSS 的端到端。

### Phase 2 — Platform + UI 层

钩子 / 粘贴 / 悬浮窗 / 托盘 / 登录窗 / 单实例 / 自启 / 更新检查，按 `linux/src/doubao_murmur/app.py`
的接线方式组装。

### Phase 3 — 打包、CI、文档

- `dotnet publish -r win-x64 --self-contained` + `WindowsAppSDKSelfContained=true`
  （用户无需装 Windows App SDK 运行时）；`win-arm64` 作为 matrix 第二维
- Inno Setup：检测 WebView2 Runtime 注册表，缺失则跑 Evergreen Bootstrapper；装到
  `%LOCALAPPDATA%\Programs\Doubao Murmur` 免 UAC
- `windows-release.yml`（windows-latest / setup-dotnet / publish / iscc / 附加到 Release），
  与现有两个 workflow 同由 `v*` tag 触发；版本号从 tag 注入 `<Version>`
- README 加 Windows 段落 + `windows/README.md`；**明确写未签名会触发 SmartScreen 警告**
- **新增 `docs/asr-protocol.md`**：把 WSS URL、固定 query 参数、cookie/localStorage key 名、
  鉴权错误码、事件格式写成三份实现共同遵守的契约，配 PR checklist「协议改动需同步
  macOS/Linux/Windows 三处」—— 这是三份实现唯一现实的降险手段。

### Phase 4 — 硬化（VM 内人工执行）

Win10 22H2 / Win11；非 en-US 布局（AltGr）；100/125/150/200% DPI + 多显示器；提权窗口限制；
缺 WebView2 Runtime；麦克风隐私开关关闭；粘贴目标覆盖 Chrome / Word / Windows Terminal /
VS Code / 微信。

---

## 六、不移植

掌机触摸软键盘、layer-shell、evdev、flatpak、xdotool/ydotool 整套。
