# 豆包语音输入 (Doubao Murmur) — Windows 版

原生 C# / .NET 8 + WinUI 3 实现，与 macOS (Swift) 和 Linux (Python) 版共用同一套豆包
ASR 协议。

> macOS 用户请使用仓库根目录的版本，Linux / SteamOS 用户请看 [`../linux`](../linux)。

## 功能

- ⌨️ **全局热键**：右 `Alt` 开始 / 停止识别，`ESC` 取消（任意应用中均可用）
- 📝 **实时转写**：悬浮窗显示识别结果，不抢焦点、不挡输入
- 📋 **自动粘贴**：识别结果自动复制并粘贴到当前输入框
- 🔐 **登录一次**：内置 WebView2 登录豆包，凭证保存在本地
- 🛎 **系统托盘**：常驻托盘图标，可切换热键、开机自启

## 系统要求

- Windows 10 1809+ 或 Windows 11（x64 / ARM64）
- Microsoft Edge WebView2 Runtime（Windows 11 与较新的 Windows 10 已自带；
  缺失时安装程序会提示下载）
- 不需要安装 .NET —— 运行时已随程序打包

## 安装

从 [Releases](../../releases) 下载 `Doubao-Murmur-Setup-vX.Y.Z-win-x64.exe` 并运行。

安装到 `%LOCALAPPDATA%\Programs\Doubao Murmur`，**不需要管理员权限**。

> 程序未做代码签名，Windows SmartScreen 会提示「已保护你的电脑」。
> 点击「更多信息 → 仍要运行」即可。

也提供免安装的 `-portable.zip`，解压后直接运行 `DoubaoMurmur.exe`。

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

## 诊断工具

`DoubaoMurmur.Diag` 是一个独立的控制台程序，用来把「豆包连接是否正常」和
「界面是否接好」这两类问题分开排查：

```powershell
DoubaoMurmur.Diag params     # 检查本地凭证（不会打印任何 cookie 值）
DoubaoMurmur.Diag mic 5      # 采集 5 秒麦克风，报告字节数与峰值
DoubaoMurmur.Diag asr 8      # 用麦克风连接豆包，打印实时识别结果
DoubaoMurmur.Diag wav a.wav  # 改用 WAV 文件作为音频源
```

它读取主程序保存的 `%APPDATA%\doubao-murmur\asr_params.json`，所以要先登录一次。

## 开发

### 结构

```
windows/
  src/DoubaoMurmur.Core/   协议、状态机、音频、凭证 —— 无 UI 依赖，可单测
  src/DoubaoMurmur.App/    WinUI 3 外壳 + Win32 互操作（热键、粘贴、托盘、悬浮窗）
  tools/DoubaoMurmur.Diag/ 控制台诊断工具
  tests/DoubaoMurmur.Tests/ xUnit
  installer/installer.iss  Inno Setup 脚本
```

`Core` 层刻意不引用任何 `Microsoft.UI.*`：UI 线程调度通过 `IDispatcher` 抽象注入，
这样状态机可以在没有 WinUI 的情况下被完整测试。

### 构建

```powershell
dotnet test    windows/tests/DoubaoMurmur.Tests/DoubaoMurmur.Tests.csproj
dotnet publish windows/src/DoubaoMurmur.App/DoubaoMurmur.App.csproj `
  -c Release -r win-x64 -p:Platform=x64 -o publish/DoubaoMurmur
```

WinUI 3 没有 AnyCPU 配置，必须显式指定 `-p:Platform=x64`（或 `ARM64`）。

CI 在每次 push 时构建并上传产物，见
[`windows-ci.yml`](../.github/workflows/windows-ci.yml)。

### 与其他平台保持一致

豆包的接口会变，历史上的热修（`samantha_web_web_id` 改名、AltGr、终端检测）都发生在
协议层。目前有 Swift / Python / C# 三份实现，改动协议相关的东西时**三处都要同步**：

| 关注点 | macOS | Linux | Windows |
|---|---|---|---|
| WSS URL 与固定参数 | `DoubaoASRClient.swift` | `config.py` | `Core/AppConfig.cs` |
| 凭证提取 | `WebViewManager.swift` | `ui/login_window.py` | `UI/LoginWindow.xaml.cs` |
| 状态机 | `TranscriptionManager.swift` | `transcription.py` | `Core/TranscriptionManager.cs` |
| 注入脚本 | `Resources/inject-*.js` | `resources/inject-*.js` | `Assets/inject-*.js` |

注入脚本三处内容相同，Windows 侧在加载时把 WKWebView 的
`window.webkit.messageHandlers...` 桥接替换成 WebView2 的
`window.chrome.webview.postMessage`，以免脚本本身分叉。
