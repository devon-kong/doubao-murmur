# Doubao Murmur

macOS 菜单栏语音输入工具：使用本机[豆包输入法](https://www.doubao.com/)完成识别，再把已确认的文字粘贴到原目标输入框。支持本机、网易 UU **兼容模式**与 UU **快速模式**。

当前运行说明以[当前使用方法与系统流程](docs/current-usage-and-system-flow.md)为准；历史排查记录见[交接索引](hand-off/README.md)。

> GitHub 已发布的 `v1.3.0` 资产固定在 `aa469c2`，不包含 build13 的物理右 Command 停止修复。本轮只会推进 `master`，不会重打标签或修改已有 Release。

<p align="center">
  <img src="docs/screenshots/overlay_pannel.png" width="500" alt="语音识别悬浮窗">
</p>

## 要求与安装

- macOS 13.0+；已安装并启用豆包输入法。
- 在「系统设置 → 隐私与安全性 → 辅助功能」授予 Doubao Murmur 权限。
- [GitHub `v1.3.0` Release](https://github.com/devon-kong/doubao-murmur/releases/tag/v1.3.0) 固定在 `aa469c2`，不包含物理右 Command 的 build13 修复。
- 当前 `master` 含 build13 源码；在另行授权创建新 Release 前，GitHub 用户应从 `master` 自行构建，不应把现有 Release 当作 build13。

本开发机本地保留的 build13 控制端包（`dist/` 未纳入 Git，clone 后不可取得）：

```text
dist/Doubao-Murmur-v1.3.0-build13-physical-right-command-stop-diagnostic.zip
SHA-256: 828000a82930dc97014ff1315ce850e807f3749c21296c1fd969400a71a97172
```

## 免责声明

- 本项目仅供个人学习和研究使用，不得用于商业用途。
- 本项目通过系统输入源切换和合成按键驱动已安装的豆包输入法，不是豆包官方 API 或 SDK。
- 使用前需自行安装并启用豆包输入法；识别由该输入法在本机完成。
- 本项目不收集、存储或上传语音或识别结果。
- 使用本项目产生的后果由使用者自行承担；如认为本项目侵犯相关权益，请联系作者处理。

## 正确操作

1. 先把光标放到目标输入框。
2. 按一次 `⌃ Control + /` 开始。应用等待该热键完全释放、输入框聚焦和豆包输入法就绪后，合成一次右 `Command` 启动豆包。
3. 说完后，**手动按一次物理右 `Command`** 停止豆包。该键不会被应用吞掉。
4. 看到输入法的下划线消失后，应用在下一主循环冻结文字，恢复原目标，再按所选模式粘贴。

| 操作 | 行为 |
| --- | --- |
| `⌃ Control + /`（空闲） | 开始录音 |
| `⌃ Control + /`（录音中） | 忽略；不会停止或粘贴 |
| 物理右 `Command`（录音中） | 用户的停止手势 |
| `ESC` | 安全取消：不复制、不粘贴，恢复原输入法 |

## 粘贴模式

| 模式 | 适用场景 | 方式 |
| --- | --- | --- |
| 本机 | 普通本地应用 | 恢复原目标后复制并模拟 `⌘V` |
| 兼容模式 | UU 远控的默认选择 | 使用 UU 正常剪贴板同步；菜单可调整剪贴板稳定时间 |
| 快速模式 | 已配置 Mac mini helper 与 UU 端口映射 | 控制端请求 helper 直写远端剪贴板，再由 helper 投递 `⌘V` |

快速模式需要 Mac mini 安装 `murmur-mirror`，将 MacBook `127.0.0.1:17771` 映射到 Mac mini `127.0.0.1:17771`，并授予 helper 辅助功能权限。安装细节见[helper 安装说明](packaging/murmur-mirror/README.md)。

```text
Control + / (start only)
  -> capture original target and PasteRouter route for this session
  -> focus + Doubao input source ready + hotkey released
  -> synthetic right Command starts Doubao
  -> user presses physical right Command to stop
  -> marked text true -> false
  -> freeze text -> execute route captured at session start
  -> local / compatibility / fast paste route
```

## 故障与日志

- 未看到下划线消失、焦点丢失、物理右 `Command` 期间按了普通键，或等待超过 1.5 秒：会安全取消，不自动重试、不自动粘贴半成品。
- 快速模式单笔显示“状态未知”仅表示控制端未确认回执；先检查目标输入框，**不要重试该笔**。`eventPosted=true` 只说明 helper 投递了按键事件，不证明目标应用已消费文字。
- 控制端日志：`~/Library/Application Support/Doubao Murmur/paste-orders-controller.sqlite3`。
- helper 日志与验收请见[helper 安装说明](packaging/murmur-mirror/README.md)。

## 开发与测试

需要 Xcode 15+ 与 [XcodeGen](https://github.com/yonaskolb/XcodeGen)：

```bash
xcodegen generate
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild test -project doubao-murmur.xcodeproj -scheme doubao-murmur \
  -destination 'platform=macOS'
```

build13 自动测试为 46/46；用户已报告本机、UU 兼容模式和 UU 快速模式均正常。详细验证边界与接手步骤见[当前使用方法与系统流程](docs/current-usage-and-system-flow.md)。

## License

[MIT](LICENSE)
