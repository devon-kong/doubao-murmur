# build13 物理右 Command 停止：最终交接

时间：2026-08-28（Asia/Shanghai）

仓库：`/Users/devon/claude/doubao-murmur`
分支：`master`
实现基线：`00acf43c329d26127f5b582ab1e9fe8126d546bd`

> 本文是当前交接。运行说明以[当前使用方法与系统流程](../docs/current-usage-and-system-flow.md)为准；历史材料见[交接索引](README.md)。

## 1. 目标与结论

目标是消除合成停止右 Command 与恢复前台之间的时序竞态：开始仍由 `Control + /` 编排，但停止改由用户按**物理右 Command**交给豆包输入法自然处理。应用不消费该物理键，不再合成 stop Command。

当前实现已经把最终锁文改为双条件门：

```text
physical right Command-up observed
            +
marked text true -> false committed
            |
            v
next main loop final_text_locked -> PasteRouter
```

物理右 Command 按住期间出现普通按键，会作为非裸手势安全取消；焦点丢失、`ESC`、超时也安全取消。录音期间重复按 `Control + /` 被忽略，不会停止或粘贴。

## 2. 当前运行流程

```text
Control + / (start only)
  -> capture original target and PasteRouter route for this session
  -> wait: hotkey fully released + Overlay focus + Doubao input source ready
  -> synthetic right Command tap starts Doubao
  -> recording
  -> user physical right Command down (not consumed)
  -> stopping; keep Overlay NSTextView focused
  -> physical right Command up AND marked text true -> false
  -> next main loop freezes text
  -> restore target/input source
  -> execute local | UU compatibility | UU fast route captured at session start
```

快速模式另有一段安全链：

```text
MacBook app -> UU loopback mapping -> Mac mini murmur-mirror
  -> clipboard write -> target/frontmost check -> Command-V -> ACK validation
```

`eventPosted=true` 只证明 helper 投递了 Command-V，不代表目标字段一定消费文字。ACK 不确定的一笔不得自动重试。

## 3. 代码与测试

主要实现位于：

- `doubao-murmur/HotkeyManager.swift`：监听物理 HID 右 Command；仅接收 keyCode 54、`sourcePID=0`，不消费事件。
- `doubao-murmur/InputMethodSessionManager.swift`：`PhysicalRightCommandStopGate`，会话/焦点/超时与最终锁文门控。
- `doubao-murmurTests/PasteRouterTests.swift`：物理抬起与 marked commit 乱序、重复、取消、超时、非裸手势与合成启动排除测试。

提交前后的完整 XCTest 均为 **46/46 通过**。`git diff --check` 通过。用户已报告 Codex 本地、UU 兼容模式和 UU 快速模式都正常；这三项是用户实测报告，不应扩展为对所有输入法、UU 或目标应用版本的长期保证。

## 4. 安装包与校验

控制端 build13 诊断包仅保存在本开发机 `dist/`（`dist/` 未纳入 Git，clone 后不可取得）：

```text
dist/Doubao-Murmur-v1.3.0-build13-physical-right-command-stop-diagnostic.zip
SHA-256  828000a82930dc97014ff1315ce850e807f3749c21296c1fd969400a71a97172
```

Mac mini helper 在 GitHub `v1.3.0` Release 可取得；本开发机也保留如下 `dist/` 副本（同样未纳入 Git）：

```text
dist/murmur-mirror-mac-mini-aa469c2ce657.zip
SHA-256  cb0247463cedf3dd2c11c77a80bc96d63275f963c11f74d08eda491fdbd477ff
```

控制端已安装为 `/Applications/Doubao Murmur.app` build13；外部 build12 备份仍保留。helper 仍来源于 `aa469c2`，没有被伪称为 build13 helper。

## 5. Git、发布与清理状态

- 当前实现 commit：`00acf43`，位于本地 `master`；尚未 push 时不要声称 GitHub 已包含该修复。
- `origin/master` 基线是 `ca9272799eeca491772d2b4db8ed6ac10ce74d56`。
- 现有 GitHub tag/release `v1.3.0` 固定在 `aa469c2`，资产不包含 build13 修复。当前 `master` 含 build13 源码，GitHub 用户在另行授权创建新 Release 前需自行构建。本轮授权边界是只 push `master`；**不要打新 tag、不要建 Release、不要改写 v1.3.0**。
- 旧 release worktree 已移除；项目中旧 build 目录、`dist/backups`、旧 d49d080 ZIP 和 build2--build12 诊断 ZIP 已清理。`dist` 只保留上述两个当前包。
- 已清理内容采用可恢复的废纸篓路径；清空废纸篓前不能把全部逻辑体积差额当成已物理释放空间。

## 6. 两端边界、日志与风险

快速模式要求 Mac mini helper 只监听 `127.0.0.1:17771`，UU 在 MacBook 侧建立对应 loopback 映射。当前未配置认证/token；一旦对 LAN 暴露、多人共享或准备公开部署，认证必须成为部署前条件。

日志位置：

```text
controller: ~/Library/Application Support/Doubao Murmur/paste-orders-controller.sqlite3
helper:     ~/Library/Application Support/Doubao Murmur/paste-orders-helper.sqlite3
```

关键事件包括 `physical_right_command_stop_down`、`physical_right_command_stop_up`、`marked_text_committed` 和 `final_text_locked`。如果下划线没有消失、物理右 Command 没有完整抬起、焦点丢失或等待超过 1.5 秒，系统应取消而不是粘贴。

## 7. 接手第一步

先确认 `master` 是否仍指向 `00acf43` 或其后继、工作区没有混入无关变更，并阅读[当前使用方法与系统流程](../docs/current-usage-and-system-flow.md)。若用户授权 push，则只把已审核的 `master` 推到远端；发布资产仍需单独决定，不能从 push 自动推断 tag/Release 授权。
