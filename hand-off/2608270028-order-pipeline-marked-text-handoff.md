# UU 连续订单与豆包 marked-text 完成交接

时间：2026-08-27 00:28 CST
仓库：`/Users/devon/claude/doubao-murmur`
分支：`codex/uu-direct-paste`

## 背景与目标

快速模式此前把上一笔请求的回执状态当作全局门：远端已经快速完成剪贴板写入和 Command-V，但 ACK 丢失或迟到时，上一笔会进入未确认状态，并阻断后续语音输入。当前实现把每次粘贴视为独立订单；单笔 `unconfirmed` 只表示控制端无法确认回执，不再阻断后续录音和发送，也不会自动重试。

控制端和 helper 现在分别写入 SQLite 事件日志。每条事件包含 UTC 毫秒时间和当前进程内的 monotonic 纳秒时间，可关联分析录音、发送、helper 接收、剪贴板写入、主线程粘贴、响应构建、socket 发送、控制端收到响应及校验 ACK 等阶段。日志默认不保存识别原文、剪贴板内容、窗口标题或文字哈希。

日志位置：

```text
控制端：~/Library/Application Support/Doubao Murmur/paste-orders-controller.sqlite3
helper：~/Library/Application Support/Doubao Murmur/paste-orders-helper.sqlite3
```

## 快速模式订单设计

- 协议升级为 v2；请求和 ACK 均携带 `requestId`、`controllerSessionId`、`sequence`。
- 每次录音生成独立 `requestId`；同一控制端进程使用稳定的 `controllerSessionId` 和递增 `sequence`。
- 控制端允许多笔 HTTP 请求同时等待 ACK，慢 ACK 不占用全局输入门。
- helper 的连接接收并发；剪贴板写入、目标应用复查和 Command-V 仍在 AppKit 主线程串行执行。
- 响应 JSON 构建和 socket 发送移出主线程粘贴关键区，因此某连接返回缓慢不会阻止下一连接进入粘贴关键区。
- ACK 可逆序返回，控制端按订单身份独立归属和校验。
- 单笔超时或回执异常进入 `unconfirmed`，不写控制端剪贴板、不弹模态窗口、不激活 App、不阻断后续订单、不自动重试。
- `eventPosted=true` 仅表示 helper 已投递 Command-V 事件，不表示目标应用已确定消费或插入文字。

## 两种模式共同使用的豆包交互优化

以下启动和完成流程属于语音输入会话本身，兼容模式和快速模式共同使用，并非快速模式专属。

第一次热键后立即启动两条独立 readiness 路径：

1. 临时 `NSTextView` 成为 panel 的 first responder，并确认 overlay 是 key window。
2. 选择豆包输入源，并通过当前 TIS 输入源 ID 再次确认。

AppKit 和 TIS 操作仍留在主线程。成功路径不再使用固定 `0.15s` input-source 延迟或 `0.10s` Fn 延迟。两条 readiness 无论以何种顺序完成，都只授权一次 Fn-down；录音 UI 仅在 Fn-down 成功发出后进入 `recording`。session generation、readiness gate 和 focus request token 会拦截取消后的迟到回调。

第二次热键立即发出 Fn-up，同时保持 overlay 可见、key window 和 `NSTextView` first responder。自定义 `NSTextView` 在 `setMarkedText`、`insertText`、`unmarkText` 调用 `super` 后报告 AppKit marked-text 状态；正常完成的唯一门是本轮确实观察到 marked text 为 true，随后在 stopping 阶段观察到 true→false（界面蓝色下划线消失、IME commit）。commit 后的下一次主线程事件循环直接读取并冻结 `NSTextView.string`，之后才隐藏、恢复输入源和程序清理。

正常完成没有文字 quiet period，也没有最长自动超时。如果 Fn-up 时 marked 已为 false，但本轮先前确实见过 true，也会在下一主循环完成。如果本轮从未出现 marked text，或 marked text 永不消失，会一直保持 `stopping`；仅 ESC 或应用退出可以取消。程序自身的清空和 `unmarkText` 会抑制回调，不能伪造本轮 commit。

仅在 direct identity 存在时，控制端 SQLite 还会记录以下安全时间事件：

```text
focus_ready
input_source_ready
fn_down_posted
marked_text_started
fn_up_posted
marked_text_committed
final_text_locked
```

## 独立审核与自动验证

主代理已完成源码只读独立审核并通过。最终自动验证结果：

```text
完整 XCTest：30/30 passed，0 failures
App Release build：成功，x86_64 arm64
helper Release build：成功，x86_64 arm64
git diff --check：通过
```

30 项测试保留原有 21 项订单、协议、SQLite 和兼容模式安全门，并新增 readiness/marked-text/安全清理/生命周期日志 9 项确定性测试。

## 尚未验证

- 未做真实豆包输入法端到端验收。
- 未做真实 Mac mini 端到端验收。
- 未做真实控制端到 helper 的 `/paste` 端到端验收。
- 未打包、未安装、未 push。

## 残余风险

- 需要用实际豆包输入法版本确认其语音流程稳定经过 AppKit marked-text true→false。
- 如果豆包从未产生 marked text，或下划线永不消失，系统会按设计停在 `stopping`，必须 ESC 取消。
- TIS 当前采用选择后立即确认；若某台机器输入源状态传播不同步，会安全取消，不会使用固定延迟猜测成功。
- helper 的粘贴关键区按到达顺序串行，尚未做持久化 FIFO 重排。
- `eventPosted` 不能证明目标应用已经消费 Command-V；日志用于定位事件投递与 ACK 返回之间的差异。
- helper 的跨进程重启幂等、持久化任务队列、`/paste-status` 和自动重试均未实现；当前设计明确禁止自动重试未确认订单。
- protocol v2 不向后兼容旧 helper；控制端与 helper 必须配套升级。

## 建议手工验收

1. 兼容模式至少连续测试 5 次：确认第一次热键后的开头不丢字；第二次热键后仅在蓝色下划线消失后锁文和粘贴。
2. 快速模式至少连续测试 5 次，执行同样的启动和 marked-text 完成检查。
3. 在 marked text 未提交或模拟异常 stopping 时按 ESC，确认 overlay 关闭、Fn 状态和原输入源恢复，且不会粘贴半成品。
4. 快速模式连续提交多笔短文本，确认上一笔 ACK 慢或超时不阻断下一笔录音和发送。
5. 对照两端 SQLite 的 `request_id`、`controller_session_id`、`sequence`，验证逆序回执和超时订单可独立关联。
6. 配套安装 protocol v2 控制端与 helper 后再测试，不能让 v2 控制端连接旧版 helper。

## Git 基线

提交前已执行 `git fetch origin`。当时：

```text
HEAD:                            d49d080c61771995c4f4e37263ff0061db99a541
origin/codex/uu-direct-paste:    d49d080c61771995c4f4e37263ff0061db99a541
ahead/behind:                    0/0
```

旧的未跟踪构建目录、研究文档和历史交接文件均保留，未纳入本次提交。
