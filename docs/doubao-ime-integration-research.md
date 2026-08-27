> **历史调研快照（非当前操作说明）**：本文记录早期只读研究，部分描述已被当前实现取代。当前运行方式请见[当前使用方法与系统流程](current-usage-and-system-flow.md)与[交接索引](../hand-off/README.md)。

# 将 Doubao Murmur 的语音识别改为「豆包输入法」的调研

日期：2026-08-24
范围：只读检查本项目、已安装的豆包输入法和参考项目；未运行录音、未改动设置、未改动现有源码或构建产物。

## 结论

**不建议把这件事理解为“把现有 WebSocket 换成豆包输入法 API”。** 本次检查没有发现豆包输入法对外公开、可供第三方 App 调用的 ASR 启停、音频送入或识别结果回调接口。

最短且风险最低的验证路径是：**让豆包输入法本身在 MacBook Pro 本地完成语音识别和文字提交，Doubao Murmur 暂时退出或不接管同一快捷键**。这能验证输入法产生的中文文本是否会被网易 UU 转发到 Mac mini 的目标输入框，但它不会保留 Doubao Murmur 的 Overlay、识别文本回调和“复制后 `⌘V`”流程。

若这个人工端到端测试通过，后续可讨论一个“编排层”方案：Doubao Murmur 只选择豆包输入源并向其交付触发键，识别和落字仍完全由豆包输入法负责。它不是直接集成 ASR，且需要单独原型验证。**不要基于本次调研去调用私有符号、读取输入法私有数据库或逆向其网络协议。**

## 现有 Doubao Murmur 实际链路

当前 macOS 版不是把网页直接当作录音界面，而是：隐藏 `WKWebView` 用于豆包网页登录和提取会话参数；原生 `AVAudioEngine` 采集音频；原生 `URLSessionWebSocketTask` 连接 Web 端 ASR；最后写入剪贴板并模拟 `⌘V`。

```text
⌃ + /
  -> HotkeyManager（消费该事件）
  -> TranscriptionManager
  -> AVAudioEngine 采集本机麦克风
  -> Doubao Web 会话 Cookie / WSS 参数
  -> ws-samantha.doubao.com 的流式 ASR
  -> Overlay 文本
  -> 剪贴板 + 延迟 0.25 秒的 ⌘V
```

关键证据：

- `doubao-murmur/HotkeyManager.swift:127-142`：精确匹配 `Control + /` 后调用 `toggleRecording` 并 `return nil`，因此该组合键不会再传给前台 App 或另一个输入法。
- `doubao-murmur/TranscriptionManager.swift:156-209`：启动本机音频采集、加载网页会话参数并连接 ASR。
- `doubao-murmur/DoubaoASRClient.swift:38-79`：使用 `wss://ws-samantha.doubao.com/samantha/audio/asr`，并依赖网页 Cookie、`deviceId` 和 `webId`。
- `doubao-murmur/WebViewManager.swift:84-100,185-234`：加载 `https://www.doubao.com/chat`，从 Cookie 与 `localStorage` 提取连接参数。
- `doubao-murmur/PasteHelper.swift:5-38`：当前 UU 兼容性的关键是本地剪贴板后模拟 `⌘V`，而非输入法文本提交。

所以，改用输入法不是替换 `DoubaoASRClient` 的一个端点；它会取代“采集音频 → WSS → 文本回调 → Overlay → 剪贴板粘贴”这一整段职责。

## 已安装豆包输入法：可确认的事实与边界

本机已安装的输入法 Bundle 为 `/Library/Input Methods/DoubaoIme.app`，静态只读检查结果如下：

| 项目 | 观察结果 | 可得出的结论 |
|---|---|---|
| Bundle | `com.bytedance.inputmethod.doubaoime`，版本 `0.9.6`，Apple Developer ID 签名 | 是一个独立的 macOS 输入法，而非可嵌入 SDK。 |
| 输入源 ID | `com.bytedance.inputmethod.doubaoime.pinyin` | 可作为系统输入源被选择。 |
| 输入法框架 | `Info.plist` 声明 `InputMethodConnectionName=DoubaoIme_Connection`、`InputMethodServerControllerClass=DoubaoImeInputController`；二进制链接 `InputMethodKit.framework` | 通过 macOS 输入法机制向当前文本客户端提交文字。 |
| 语音能力 | 声明麦克风使用说明；二进制中可见 `DoubaoImeASRShortcutCoordinator`、`ASRShortcutSettingView`、`GlobalVoiceShortcutPromptPanel` 等符号字符串 | 输入法自身具备 ASR 和快捷键设置/处理能力。静态字符串不能证明某个具体组合键一定可配置。 |
| 输入源/快捷键处理 | 二进制中可见输入源恢复、Fn 长按、修饰键组合和全局快捷键相关字符串 | 输入法确实会管理自己的启动、停止和输入源状态。 |
| 对外接口 | 在 Bundle 信息、公开框架链接和限定的静态字符串检查中，未发现文档化的第三方 ASR 请求/结果回调 API | **未发现**不等于绝对不存在私有接口；但没有证据支持把私有机制当作产品依赖。 |

Apple 公开 SDK 也给出了相同的边界：

- `InputMethodKit` 的 `IMKServer` / `IMKInputController` 用于**实现一个输入法**，其会话由输入法与当前文本客户端建立。
- `TextInputSources.h` 的 `TISSelectInputSource` 可选择系统输入源；它不是“请求另一个输入法开始 ASR”或“获取该输入法最终文本”的 API。
- 输入法通常经 macOS Text Input 协议向当前客户端提交文本。网易 UU 是否把这种文本提交完整转发到远端，不能由 `⌘V` 已经可用推导出来，必须实机验证。

## `remote-mic-app` 参考项目究竟提供了什么

参考：[HD838A/remote-mic-app @ `c89e5cfc55ca5ddc84c52e1411446c782b0b13ca`](https://github.com/HD838A/remote-mic-app/tree/c89e5cfc55ca5ddc84c52e1411446c782b0b13ca)。

它不是豆包输入法的 ASR SDK 封装。它的模式是：

```text
小米蓝牙语音遥控器
  -> SayAll / Remote Mic 接收音频
  -> MiRemoteV 2ch 本地虚拟麦克风
  -> 豆包输入法从该音频设备采集
  -> 豆包输入法向当前本机文本客户端提交文字
```

具体证据：

- `Resources/zh-Hans.lproj/DoubaoInputMethodCompatibility.md` 明确写的是让豆包输入法从 `MiRemoteV 2ch` 虚拟麦克风取得遥控器音频。
- `Sources/RemoteMic/OnboardingFlow.swift:125-129` 为豆包输入法配置的输入源 ID 与本机安装版一致：`com.bytedance.inputmethod.doubaoime.pinyin`。
- `Sources/RemoteMic/OnboardingInputSourceSwitcher.swift` 使用公开的 `TISSelectInputSource` 选择输入源；没有调用豆包私有 ASR API。
- `Sources/RemoteMic/KeyboardInjector.swift:70-109` 将 Fn 作为 key code `63`，用 `CGEvent` 的 `.maskSecondaryFn` 发送按下/释放事件。
- README 明确说明：为 Typeless 设计的“Fn 点按”模式不适用于豆包输入法；豆包输入法等使用 **Fn 长按** 的工具应保持该模式关闭。

这对本项目的启示是“输入源选择 + 音频设备 + 触发键”的编排模式，而不是直接复用其代码或 ASR 协议。

> 许可边界：该参考仓库的 macOS App/驱动代码为 `GPL-3.0-only`。可以参考行为和测试思路；不要把其 Swift 源码复制进当前仓库，除非明确接受相应的 GPL 合规义务。

## 可选路径比较

| 路径 | 是否真的使用豆包输入法 | 是否保留现有 Overlay / 文本回调 / 自动粘贴 | UU 全屏不确定点 | 判断 |
|---|---|---|---|---|
| A. 直接使用豆包输入法（无代码） | 是 | 否，由输入法自行提交文字 | UU 是否转发 macOS Text Input 提交，而不只转发原始键盘/剪贴板操作 | **最先验证，推荐。** |
| B. Doubao Murmur 做“输入源 + 触发”编排 | 是，但只是驱动输入法，不读取 ASR 结果 | 基本不保留；除非另行设计，不应窥探目标输入框取回文本 | 还要验证合成 Fn 或输入法自定义快捷键能被 UU 前台状态接受 | 仅在 A 成功后考虑。 |
| C. 新建自己的 macOS 输入法 | 不会使用现成豆包输入法，只是自己实现输入法 | 可自行设计，但工作量大且仍需合法 ASR 服务 | 同样要验证 UU 的文本提交路径 | 不符合当前最小验证目标。 |
| D. 逆向豆包输入法私有 IPC、数据库或网络协议 | 可能 | 理论上可获得更多控制 | 版本、签名、隐私、合规和维护风险很高 | **不建议。** |
| E. 改为某个官方云 ASR SDK | 不是豆包输入法 | 可保留现有架构的大部分外观 | 准确率未必等于输入法；还会引入账号、授权和费用问题 | 是另一条产品路线，不是本题的直接答案。 |

## 最重要的快捷键冲突

现在 Doubao Murmur 会消费 `⌃ + /`。因此，在它运行时，即使豆包输入法也被配置为同一组合键，输入法也收不到该事件。

人工验证豆包输入法时，必须二选一：

1. 完全退出 Doubao Murmur，再让豆包输入法拥有自己的语音快捷键；或
2. 日后在新设计中由 Doubao Murmur 接管 `⌃ + /`，再将一个**不同的、明确可验证**的触发动作交给输入法。

当前不要让两个应用同时竞争同一个全局快捷键。

## 建议的零代码实机验证顺序

这一步是调研后的下一步，不是本次已执行的操作。

1. 退出 Doubao Murmur，确保它不再消费 `⌃ + /`。
2. 在 MacBook Pro 上确认豆包输入法已启用，并先用其设置页面配置/确认可用的语音触发方式。二进制中存在快捷键设置能力的证据，但“`⌃ + /` 一定可设且可在 UU 中工作”尚未实测。
3. 先在 MacBook Pro 本地的 TextEdit 中完成一次开始、说话、结束和文字提交。此步骤只验证输入法本身。
4. 再通过 UU 连接 Mac mini、进入全屏、聚焦远端文本框，重复同一句唯一测试短语。
5. 只有当文字**直接出现在 Mac mini 的远端输入框**中，才把“豆包输入法可替代当前 UU 场景中的 Web 端 ASR”标为通过。

建议记录下面四项，而不是只观察是否出现面板：

| 检查项 | 通过标准 |
|---|---|
| 本地输入法启动/停止 | 每次触发都开始和结束，无残留录音状态。 |
| 本地 TextEdit 提交 | 目标短语被正常提交为文本。 |
| UU 全屏远端提交 | 同一短语直接进入 Mac mini 的输入框。 |
| 快捷键竞争 | Doubao Murmur 退出时输入法能收到；二者同时运行时的行为被明确拒绝或另行设计。 |

如果第 3 步通过而第 4 步失败，问题是 UU 对 macOS 输入法文本提交的转发能力，而不是豆包输入法的识别准确率；这时不要仓促改造 Doubao Murmur。

## 若 A 路径通过，后续实现前的门槛

在任何代码修改前，至少应确认：

- 豆包输入法有稳定、用户可配置且不会与 UU 冲突的触发方式；
- UU 全屏能稳定转发输入法提交的中文文本；
- 输入源切换是否需要恢复、何时恢复，以及对用户正常打字的影响；
- 发生输入法未启用、麦克风不可用或焦点丢失时的可见失败提示；
- 不读取远端输入框内容，也不通过辅助功能抓取输入法候选窗来“伪造”识别结果回调；
- 如要借鉴 `remote-mic-app`，只借鉴设计/测试思路，不能直接复制 GPL-3.0-only 代码。

## 调研限制与证据等级

- 未运行豆包输入法、未查看其用户设置/数据库、未抓包、未调用私有接口；因此所有“可配置为 `⌃ + /`”和“UU 会转发输入法提交”的判断均为**待实机验证**。
- 本机 Firecrawl 抓取后端返回 `ECONNREFUSED 127.0.0.1:13002`，本机 SearXNG 搜索后端返回 `NETWORK`；未自动切换到付费检索后端。
- `remote-mic-app` 的公开 Git 远端和 GitHub 只读 API 可访问，以上引用固定到提交 `c89e5cfc55ca5ddc84c52e1411446c782b0b13ca`，避免后续分支变化影响结论。
- “未发现对外 API”来自输入法 Bundle 元数据、公开 Apple SDK 和限定的静态字符串检查，不能作为“绝对不存在私有接口”的证明。
