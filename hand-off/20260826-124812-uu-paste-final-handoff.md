# UU 粘贴重设计：部署前最终交接

更新时间：2026-08-26（Asia/Shanghai）

## 结论

在“整体设计够用、认证本轮明确暂缓”的范围内，GPT 审查提出的 3 项 P1 已完成并通过主 agent 审核；兼容模式不再因为主队列延迟突破最长等待，也不会在原目标应用离开前台后向其他 App 发送 Command-V；快速模式不会在前一请求结果不确定时继续创建第二个请求。

当前可以进入 Mac mini 部署与一次性真实验收，但**尚未完成真实 UU 端到端验证**。若 UU 映射或 helper 不是严格 loopback，认证/token 立即升级为部署前必做，不能继续沿用本轮豁免。

## 当前设计

Doubao Murmur 在网易 UU 控制 Mac mini 时提供两条互不竞争的粘贴路径：

- **兼容模式**：沿用 UU 的 MacBook → Mac mini 剪贴板同步；用户设置的 `Q` 是剪贴板稳定时间。
- **快速模式**：MacBook 控制端向 `http://127.0.0.1:17771/paste` 发送 `{ requestId, text }`；UU 将此 loopback 端口映射到 Mac mini，Mac mini 上的 `murmur-mirror` 写入其系统剪贴板并投递一次 Command-V。

快速模式不预发布 MacBook 剪贴板，不在 MacBook 投递 Command-V，也不自动重试 `/paste`。

## 本轮完成的 P1

### 1. 兼容模式硬 deadline

- 使用 `ProcessInfo.processInfo.systemUptime`，避免墙上时钟变化延长授权窗口。
- 每个轮询 tick 首先检查 `now < deadline`。
- 真正投递 Command-V 前再次读取时间、目标前台状态和剪贴板内容。
- deadline 到期或已经不可能完成稳定窗口时，统一失败关闭：不粘贴，只尝试把本轮文字保留到本机剪贴板并提示用户。

### 2. 兼容模式最终目标 PID 门禁

- 录音开始时捕获原目标 `NSRunningApplication`。
- 进入剪贴板防守前、等待期间每个 tick、Command-V 最终授权点，都按原目标 PID 检查前台应用。
- 目标切换或 generation 失效时不粘贴，并明确提示“目标应用已切换”。

### 3. 快速模式单一 in-flight 与 unconfirmed gate

- 同一进程只允许一个 direct `/paste` 请求处于 in-flight。
- 取消、超时、网络错误、旧 generation、迟到或不匹配 ACK 均不能证明远端事件未发生，统一标记为 `unconfirmed`。
- 一旦进入 `unconfirmed`，本进程内快速模式持续阻断至 App 重启；兼容模式仍可使用，但不会重置 gate。
- 录音启动前置 gate 位于保存输入法、取消 pending work、捕获前台 App、显示 overlay 之前，避免警告框抢焦点后把错误 App 记成粘贴目标。
- 若用户在上一请求 in-flight 时再次开始录音：取消旧 Task、把旧请求标为 unconfirmed、本轮录音不开始；若已经 unconfirmed，本轮同样不开始且不会虚构或复制不存在的新文本。

Terra agent 负责 P1 实现；主 agent 在两轮审核反馈中要求补齐“不确定请求不能静默取消”和“录音 gate 必须早于所有焦点动作”，最终版本已覆盖。

## 验证证据

本轮最终门禁：

```text
git diff --check                              通过
完整 Debug XCTest                             29/29 通过
App Release build                             通过
App codesign --verify --deep --strict          通过
murmur-mirror Release build                   通过
```

测试新增覆盖包括：deadline 后 tick 不得进入剪贴板防守或投递、等待中/投递前目标切换、最终剪贴板复查、direct gate 状态机、取消/旧请求不确定性、录音前置阻断、兼容模式在 unconfirmed 下仍可启动。

这些门禁不是 Mac mini 的辅助功能授权、有效 `/paste` 或真实 UU 链路证明。

## Mac mini 无 Xcode 安装交付

仓库新增：

```text
packaging/murmur-mirror/install.command
packaging/murmur-mirror/verify.command
packaging/murmur-mirror/com.doubao.murmur.mirror.plist
packaging/murmur-mirror/README.md
scripts/package-murmur-mirror.sh
```

构建机运行 `scripts/package-murmur-mirror.sh` 会生成 universal `arm64 + x86_64`、ad-hoc 签名的 ZIP：

```text
dist/murmur-mirror-mac-mini-<commit-short-sha>.zip
```

`dist/` 已忽略，不把二进制提交到 Git。Mac mini 只需解压并运行 `install.command`，不需要 Xcode、Homebrew、Command Line Tools、管理员密码或 `sudo`。安装器会先校验 SHA-256/签名/架构，备份既有 helper 和 LaunchAgent，再安装到：

```text
~/Library/Application Support/Doubao Murmur/murmur-mirror
~/Library/LaunchAgents/com.doubao.murmur.mirror.plist
~/Library/Logs/Doubao Murmur/
```

完整安装、辅助功能授权、UU 字段和验收步骤见 `packaging/murmur-mirror/README.md`。

## GPT 后续建议：按触发条件再执行

以下不是本轮部署 blocker。遵循“先保持整体设计简单，证据显示有问题后再加复杂度”。

| 后续动作 | 触发条件 | 当前处理 |
| --- | --- | --- |
| 兼容模式纳入 `NSPasteboard.changeCount` | 实测出现剪贴板被改写后恢复同文本，或同文本变化造成误判 | 暂缓；当前按文本和最终复查 |
| request 携带前置协议版本 | 客户端/helper 需要独立升级、出现版本错配 | 暂缓；响应仍严格校验 v1 |
| 专用 `URLSession`、禁 redirect | 遇到代理/重定向/共享 session 行为，或开始公开分发 | 暂缓 |
| helper socket 读写超时、并发连接上限 | 异常连接能长期占用线程/FD，或压力测试显示资源风险 | 暂缓 |
| 更细 `phase` / `eventState` 响应 | 排障无法区分写剪贴板、目标核验、事件投递阶段 | 暂缓 |
| 幂等状态持久化 | helper 重启边界的重复风险成为真实问题，且产品允许定义持久化生命周期 | 暂缓；当前进程内 256 条缓存 + 禁止自动重试 |
| `postToPid` 或具体输入框识别 | 真实测试仍出现核验与事件投递之间的焦点竞态 | 暂缓；这是明显的复杂度升级 |
| ACK 丢失、有效 `/paste`、真实 timer/clipboard 集成测试 | 出现现场问题，或准备扩大部署范围 | 遇到问题后优先补相应复现测试 |
| 更大规模多 App 回归 | 从个人 MacBook/Mac mini 场景扩展到其他用户或多版本 macOS | 暂缓 |

### 认证的明确触发条件

本轮按用户指示略过认证。满足任一条件时，helper token/认证必须在继续部署前实现：

- Mac mini helper 不再只监听 `127.0.0.1`；
- MacBook 的 UU 本地监听不再只绑定 `127.0.0.1`；
- 映射可被 LAN 或其他用户访问；
- 服务长期开放、跨账号使用或准备公开分发。

## UU 配置口径

在 MacBook 控制端连接 Mac mini 后，打开“端口映射”并新增：

```text
名称：murmur-mirror
本地端口：17771
目标地址：127.0.0.1
目标端口：17771
```

选择“保存后立即启用”。UU 当前文案明确说明启用规则监听 MacBook 本机 `127.0.0.1`；界面没有独立协议字段，此 HTTP 映射使用 TCP。

MacBook 验证：

```bash
curl --fail --silent --show-error --max-time 3 \
  http://127.0.0.1:17771/health
```

通过条件（字段顺序可不同）：

```json
{"ok":true,"protocolVersion":1,"accessibilityTrusted":true}
```

## 尚未完成与部署边界

- 尚未把本轮生成的新 ZIP 安装到 Mac mini。
- 尚未在 Mac mini 对本轮二进制确认辅助功能授权。
- 尚未用有效 `/paste` 完成一次真实 Command-V。
- 尚未完成 UU 端到端的“正确输入框、只插入一次”验收。
- 尚未 push；本任务只授权 commit。

`eventPosted=true` 只证明 helper 提交了 CGEvent，不能证明目标 App 已经接收并插入文本。受控端的目标 PID 两次核验与真实事件投递之间仍存在无法完全消除的竞态。

## Git 对齐

本轮开始时：

```text
branch: codex/uu-direct-paste
HEAD:   2e89418dc56d59702cef1677dcfa8a12e1e560ba
origin/codex/uu-direct-paste: 2e89418dc56d59702cef1677dcfa8a12e1e560ba
origin/master:                2e89418dc56d59702cef1677dcfa8a12e1e560ba
```

本次提交包含 P1 源码/测试、本文档和可复现打包材料。提交哈希不在本文自引用，接手时用 `git log -1 --oneline` 获取。

以下既有未跟踪内容属于用户工作区，必须保留且不纳入本次提交：

```text
build-mirror-release/
build-release/
docs/doubao-ime-integration-research.md
hand-off/2608240903-handoff.md
hand-off/2608260250-uu-direct-paste-handoff.md
```

## 部署验收顺序

1. 把 `dist/murmur-mirror-mac-mini-<sha>.zip` 传到 Mac mini，解压并运行 `install.command`。
2. 在 Mac mini 的辅助功能中添加实际 helper 路径，再运行 `verify.command`，必须看到 `accessibilityTrusted=true`。
3. 在 MacBook 配置并启用 UU 端口映射，执行 `/health` 验证。
4. Mac mini 打开无副作用的空白文本框，快速模式只测试一次短文本。
5. 确认文本写入预期输入框且只出现一次；若回执不确定，先观察目标输入框，禁止自动重试。
6. 再回归兼容模式和用户自定义 `Q`。
