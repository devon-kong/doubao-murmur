# 当前使用方法与系统流程

本文是 Doubao Murmur build13 的**当前唯一权威运行说明**。历史中的旧触发方式、旧 worktree 或旧发布状态，均以[最新交接](../hand-off/260828-build13-physical-right-command-final-handoff.md)和本文为准。

## 1. 当前使用方法

### 所有模式共用的语音手势

1. 将光标置于要接收文本的目标输入框。
2. 按一次 `Control + /` 开始。应用等待三项就绪：热键完整释放、Overlay 的 `NSTextView` 已聚焦、豆包输入源已确认；随后**合成一次右 Command** 启动豆包。
3. 说完后，用户手动按一次**物理右 Command**停止豆包。应用不吞掉该键。
4. 只有本会话见过 marked text（下划线）并随后 `true -> false`，且物理右 Command 已抬起时，才冻结最终文字，并执行会话开始时已捕获的粘贴路由。

录音期间重复按 `Control + /` 会被忽略，不能作为停止方式。`ESC` 随时安全取消：不复制、不粘贴，恢复先前输入源和前台目标。

### 本机模式

普通本机应用自动走本机路由：冻结文字后恢复原目标，将文字复制到本机剪贴板并模拟 `Command-V`。目标没有恢复前台时不粘贴。

### UU 兼容模式

当目标是网易 UU，默认使用**兼容模式**：先让 UU 使用其正常剪贴板同步链路，再恢复目标并在剪贴板稳定窗口内投递本机 `Command-V`。菜单中的「剪贴板稳定时间」只影响兼容模式；出现旧剪贴板内容时可以增大该值后重试一笔新的语音输入。

### UU 快速模式

**快速模式**（用户有时称“极速模式”）使用 Mac mini 的 `murmur-mirror` helper，绕过 UU 的常规剪贴板等待：控制端经 UU 映射访问本机 loopback 端口，helper 在 Mac mini 写入剪贴板并投递 `Command-V`。启用前必须完成 helper 安装、辅助功能授权、健康检查和端口映射，见[helper 安装说明](../packaging/murmur-mirror/README.md)。

## 2. 完整系统流程

```text
MacBook target field focused
        |
        | Control + /  (start only; consumed by app)
        v
+------------------- session preparation -------------------+
| capture target app and PasteRouter route for this session   |
| Overlay NSTextView focus ready                              |
| Doubao input source selected and confirmed                  |
| Control + / fully released                                  |
+-----------------------------+-------------------------------+
                              |
                              v
                 synthetic right Command tap (start only)
                              |
                              v
                      Doubao voice input recording
                              |
                              | user presses physical right Command
                              | (keyCode 54, physical HID source; not consumed)
                              v
       physical_right_command_stop_down -> stopping / keep Overlay focus
                              |
               +--------------+--------------+
               |                             |
               v                             v
  physical right Command-up          marked text true -> false
               |                         (underline disappears)
               +--------------+--------------+
                              |
                              v
           both conditions -> next main loop final_text_locked
                              |
                              v
       restore prior app/input source and execute captured PasteRouter route
                              |
              +---------------+----------------+---------------+
              |                                |               |
              v                                v               v
           local                       uuCompatibility       uuDirect
      copy + Command-V          UU clipboard settle gate   helper request
                                                             + matching ACK
                                                              + helper Command-V
```

快速模式的网络和投递路径如下。两端都只绑定 loopback；UU 负责在两台机器间转发，不应把 helper 直接暴露到 LAN。

```text
MacBook Doubao Murmur
        |
        | HTTP to 127.0.0.1:17771
        v
UU port mapping on MacBook
127.0.0.1:17771  =====================>  Mac mini 127.0.0.1:17771
                                                     |
                                                     v
                                          murmur-mirror helper
                                          - validates protocol/identity
                                          - writes Mac mini clipboard
                                          - checks target/frontmost state
                                          - posts Command-V to target field
```

## 3. 状态、焦点与失败关闭

会话阶段为 `idle -> preparing -> recording -> stopping -> idle`。开始阶段缺少焦点、输入源确认或热键完整释放会取消，而不是猜测继续。停止阶段 Overlay 必须继续作为 key window，且其 `NSTextView` 必须是 first responder；焦点丢失会安全取消。

下划线只是 AppKit marked-text 状态的可见表现。当前实现不以“文本字串变化”或固定 sleep 判断完成；只以本会话确实观察到 marked text `true -> false` 作为提交证据。物理右 Command 抬起与 marked-text 提交可先后到达，但最终锁文只会授权一次。

以下情况均是失败关闭边界：

- 物理右 Command 按住期间出现普通键；该手势不是“裸右 Command”，取消且不粘贴。
- 1.5 秒内没有同时获得物理抬起和 marked-text 提交；取消且不复制。
- `ESC`、焦点丢失、输入源失败、目标未恢复前台；取消或停止自动粘贴。
- 快速模式 ACK 缺失或不匹配；该笔变为 `unconfirmed`，不自动重试，也不阻断之后的新会话。

“状态未知”或 `eventPosted=true` 均不能证明目标输入框已消费文字。观察到该状态时先检查目标框；不要重试同一笔订单，以免重复输入。

## 4. 两端安装与验证

### MacBook 控制端

- 安装 build13 `Doubao Murmur.app`，版本 `1.3.0 (13)`。
- 确认豆包输入法已启用，并为 App 授予辅助功能权限。
- 控制端诊断包：本开发机路径 `dist/Doubao-Murmur-v1.3.0-build13-physical-right-command-stop-diagnostic.zip`（`dist/` 未纳入 Git，clone 后不可取得）。
- SHA-256：`828000a82930dc97014ff1315ce850e807f3749c21296c1fd969400a71a97172`。
- GitHub `v1.3.0` Release 固定在 `aa469c2`，不包含 build13；需要 build13 的 GitHub 用户应从当前 `master` 自行构建，直到另行授权创建新 Release。

### Mac mini helper（仅快速模式）

- GitHub `v1.3.0` Release 可取得 `aa469c2` 的 helper 资产；本开发机也保留同一 helper 的 `dist/murmur-mirror-mac-mini-aa469c2ce657.zip` 副本（`dist/` 未纳入 Git）。其 SHA-256：`cb0247463cedf3dd2c11c77a80bc96d63275f963c11f74d08eda491fdbd477ff`。
- helper、LaunchAgent、健康检查和辅助功能授权的具体步骤见[helper 安装说明](../packaging/murmur-mirror/README.md)。
- 在 UU 中设置 MacBook loopback `127.0.0.1:17771` 到 Mac mini loopback `127.0.0.1:17771` 的 TCP 映射。

当前 helper 资产来源于 `aa469c2`，不是 build13 的重打包 helper。认证/token 仍未启用；仅在两端都保持 loopback、只通过 UU 映射使用时才符合当前边界。一旦暴露 LAN、多人共享或公开部署，认证是继续部署前的必要条件。

## 5. 日志与关键事件顺序

控制端订单日志：

```text
~/Library/Application Support/Doubao Murmur/paste-orders-controller.sqlite3
```

快速模式 helper 订单日志：

```text
~/Library/Application Support/Doubao Murmur/paste-orders-helper.sqlite3
```

日志不保存识别原文、剪贴板内容或窗口标题。排查时关联请求标识、会话标识、顺序和阶段时间；关键会话事件应按如下因果关系出现：

```text
right_command_start_completed
  -> marked_text_started
  -> physical_right_command_stop_down
  -> physical_right_command_stop_up
  -> marked_text_committed
  -> final_text_locked
  -> selected PasteRouter route
```

`physical_right_command_stop_up` 与 `marked_text_committed` 的先后可以交换；`final_text_locked` 必须在两者之后。若某一条件不出现，应看到取消或超时，而不是粘贴。

## 6. 已验证与未验证边界

已验证：用户已报告 build13 在 Codex 本地、UU 兼容模式、UU 快速模式均正常；代码自动测试为 46/46 通过。两轮 Codex 本地语音会话日志显示文字长度分别为 26 与 24，且均为下划线先消失、再冻结并粘贴；该日志是本地语音会话证据，不是 XCTest 记录。

未验证或不可由当前信号证明：

- `eventPosted=true` 不是目标应用实际插入文字的证明。
- GitHub `v1.3.0` tag/release 固定在 `aa469c2`，其资产尚不包含本次 build13 修复；本轮只推进 `master`，未重打 tag 或建 Release。
- 未经新一轮实机证据，不应把某个特定豆包版本、UU 版本或第三方目标应用的长期行为承诺为永久稳定。

## 7. 开发验证

```bash
xcodegen generate
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild test -project doubao-murmur.xcodeproj -scheme doubao-murmur \
  -destination 'platform=macOS'
```

生成的 Xcode 项目与临时 DerivedData 都是可再生成物；不要把构建目录写回仓库。接手工作前先阅读[最新交接](../hand-off/260828-build13-physical-right-command-final-handoff.md)。
