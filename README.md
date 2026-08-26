# Doubao Murmur

macOS 菜单栏应用：用本机[豆包输入法](https://www.doubao.com/)做语音输入，再把结果复制并模拟 `⌘V` 粘贴到当前输入框（含网易 UU 等远控场景）。

<p align="center">
  <img src="docs/screenshots/overlay_pannel.png" width="500" alt="语音识别悬浮窗">
</p>

## 免责声明

- **本项目仅供个人学习和研究使用**，不得用于任何商业用途。
- 本项目通过系统输入源切换和合成按键，驱动已安装的豆包输入法完成语音识别，**并非豆包官方提供的 API 或 SDK**。
- 使用前需要自行安装并启用豆包输入法。识别由豆包输入法在本机完成。
- 本项目不会收集、存储或上传你的语音或识别结果。
- 使用本项目所产生的一切后果由使用者自行承担。
- 如果本项目侵犯了相关方的权益，请联系作者删除。

## 工作方式

1. 按 `⌃ Control + /`，应用打开悬浮输入框，切换到豆包输入法，并合成 Fn 开始语音输入。
2. 豆包输入法把识别文字写入悬浮框。
3. 再按 `⌃ Control + /`，应用等待文字稳定，写入剪贴板，把焦点还给原先的前台应用，再模拟 `⌘V`。
4. 按 `ESC` 取消：不复制、不粘贴，并恢复原来的输入法。

## 使用方式

### 要求

- macOS 13.0+
- 已安装并在「系统设置 → 键盘 → 输入法」中启用豆包输入法
- 授予本应用「辅助功能」权限（监听全局快捷键、合成按键）

### 安装

从 [Releases](../../releases) 下载 `Doubao-Murmur-vX.X.X.zip`，解压后将 `Doubao Murmur.app` 拖入「应用程序」文件夹。

### 使用流程

<img src="docs/screenshots/menu_bar.png" width="240" alt="菜单栏">

1. 将光标放到目标输入框
2. 按 `⌃ Control + /`，屏幕顶部出现悬浮窗，开始说话
3. 再按 `⌃ Control + /` 结束，文字会复制并粘贴到输入框
4. 按 `ESC` 取消本次输入

点击菜单中的「使用帮助」可查看说明：

<img src="docs/screenshots/help_pannel.png" width="400" alt="使用帮助">

| 操作 | 快捷键 |
|------|--------|
| 开始 / 停止 | `⌃ Control + /` |
| 取消 | `ESC` |

### 快速模式诊断日志

快速模式会把每笔请求的阶段和耗时追加到控制端：

```text
~/Library/Application Support/Doubao Murmur/paste-orders-controller.sqlite3
```

日志不保存识别文字、剪贴板内容或窗口标题；默认也不保存文字哈希，只保存请求标识、顺序、时间、长度、状态和错误码等诊断元数据。单笔回执超时只会在菜单中计为“状态未知”，不会阻断或自动重试后续输入。

## 开发

- 语言：Swift + SwiftUI
- 源码：[`doubao-murmur/`](doubao-murmur)
- 需要 macOS 13.0+、Xcode 15.0+、[XcodeGen](https://github.com/yonaskolb/XcodeGen)

```bash
git clone https://github.com/devon-kong/doubao-murmur.git
cd doubao-murmur
xcodegen generate
./scripts/build.sh
./scripts/run.sh
```

或 `./scripts/dev.sh` 一次完成构建和运行。

推送 `v*` tag 会触发 [`.github/workflows/release.yml`](.github/workflows/release.yml)，构建 macOS `.app` 并附加到 GitHub Release。

## License

[MIT](LICENSE)
