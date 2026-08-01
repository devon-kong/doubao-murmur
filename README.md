# Doubao Murmur

通过劫持豆包 Web 版的语音识别能力，实现全局语音输入。支持 **macOS**、**Windows** 和 **Linux / SteamOS**（Steam Deck 等掌机）。

- **macOS**：按下右 `⌥ Option` 键开始/停止语音识别，识别结果自动复制到剪贴板并粘贴到当前光标所在的输入框。
- **Windows**：按下右 `Alt` 键开始/停止，用法与 macOS 一致；托盘菜单里可以把热键换成右 Ctrl / 右 Shift 等。详见 [Windows 版说明](windows/README.md)。
- **Linux / SteamOS**：按下右 `Alt` 键开始/停止；掌机上可在 Steam Input 桌面布局中把任意手柄按键（如 R3/R2）映射为右 Alt，即可**用手柄一键语音输入**。另外还内置了 **SteamOS 桌面模式的触摸软键盘**——可拖动 / 可缩放，并支持**分体**与**左 / 右单手**布局，方便掌机握持时打字。详见 [Linux 版说明](linux/README.md)。

<p align="center">
  <img src="docs/screenshots/overlay_pannel.png" width="500" alt="语音识别悬浮窗">
</p>

## 免责声明

- **本项目仅供个人学习和研究使用**，不得用于任何商业用途。
- 本项目通过内嵌 WKWebView 加载豆包（doubao.com）网页版来调用其语音识别功能，**并非官方提供的 API 或 SDK**。豆包的页面结构、接口随时可能变化，届时本项目可能无法正常工作。
- 使用本项目前，你需要拥有一个有效的豆包账号并自行完成登录。
- 本项目不会收集、存储或上传你的任何数据（包括语音数据和识别结果），所有处理均在本地完成，语音数据由豆包服务端处理。
- 使用本项目所产生的一切后果由使用者自行承担，作者不对因使用本项目而导致的任何损失或问题负责。
- 如果本项目侵犯了相关方的权益，请联系作者删除。

## 核心原理

首次使用时，应用通过内嵌 WebView 加载豆包网页版完成登录，提取认证凭证（Cookie、设备标识等）保存到本地后立即销毁 WebView 释放资源。

后续使用时无需再加载网页。应用直接使用本地保存的凭证，通过原生 WebSocket 连接豆包的流式语音识别服务，将麦克风采集的音频实时发送到服务端，接收识别结果后自动粘贴到当前输入框。

当凭证过期时，应用会自动检测并提示重新登录，登录后再次提取凭证并销毁 WebView，如此循环。

## 使用方式

### 安装

**macOS**：从 [Releases](../../releases) 页面下载最新版本的 `Doubao-Murmur-vX.X.X.zip`，解压后将 `Doubao Murmur.app` 拖入「应用程序」文件夹即可。

> 要求 macOS 13.0+

**Windows**：从 [Releases](../../releases) 页面下载 `Doubao-Murmur-Setup-vX.X.X-x64.exe` 运行即可（约 1.3 MB），安装到当前用户目录，不需要管理员权限。也提供单文件免安装版。

> 要求 Windows 10 1809+ / Windows 11；未做代码签名，SmartScreen 提示时点「更多信息 → 仍要运行」。
> 详细说明见 [Windows 版 README](windows/README.md)

**Linux / SteamOS (Steam Deck)**：从 [Releases](../../releases) 页面下载 `doubao-murmur.flatpak`，然后：

```bash
flatpak install --user doubao-murmur.flatpak
flatpak run com.doubao.Murmur
```

> 安装、手柄按键映射等详细说明见 [Linux 版 README](linux/README.md)

### 首次使用

1. **授予辅助功能权限**：首次启动时，系统会提示授予辅助功能权限（系统设置 → 隐私与安全性 → 辅助功能），这是监听全局快捷键所必需的。
2. **授予麦克风权限**：首次语音输入时，系统会提示授予麦克风权限。
3. **登录豆包**：点击菜单栏图标，选择「登录豆包」，在弹出的窗口中完成登录。登录成功后窗口会自动关闭。

### 快捷键

| 快捷键 | 功能 |
|--------|------|
| 右 `⌥ Option` | 开始 / 停止语音识别 |
| `ESC` | 取消当前语音识别（不复制、不粘贴） |

### 使用流程

<img src="docs/screenshots/menu_bar.png" width="240" alt="菜单栏">

1. 确保菜单栏显示「已登录」状态
2. 将光标定位到任意输入框
3. 按下右 `⌥ Option` 键，屏幕顶部出现悬浮窗，开始说话
4. 悬浮窗中会实时显示识别到的文字
5. 再次按下右 `⌥ Option` 键结束识别，文字会自动复制到剪贴板并粘贴到输入框
6. 如果想取消，按 `ESC` 即可

点击菜单中的「使用帮助」可查看快捷键和使用说明：

<img src="docs/screenshots/help_pannel.png" width="400" alt="使用帮助">

## 开发

### 环境要求

- macOS 13.0+
- Xcode 15.0+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

### 构建与运行

```bash
# 克隆项目
git clone <repo-url>
cd doubao-murmur

# 生成 Xcode 项目
xcodegen generate

# 构建
./scripts/build.sh

# 运行（构建后直接运行，日志输出到终端）
./scripts/run.sh

# 或者一步完成构建+运行
./scripts/dev.sh
```

### 发布

推送 `v*` 格式的 tag 会自动触发 GitHub Actions 构建并创建 Release：

```bash
git tag v1.1.0
git push origin v1.1.0
```

## License

[MIT](LICENSE)
