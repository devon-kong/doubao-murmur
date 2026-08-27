> **历史快照（非当前操作说明）**：本文保留当时的分支、时序与验证记录，可能包含已废弃的操作。当前实现请见[交接索引](README.md)与[build13 最终交接](260828-build13-physical-right-command-final-handoff.md)。

# Doubao Murmur：UU 快速模式实机调参交接

更新时间：2026-08-26 02:50（Asia/Shanghai）

## 1. 当前目标与暂停点

目标是在网易 UU 远程控制场景中提供两种互不干扰的粘贴方式：

- **兼容模式**：继续使用 UU 自带的本机到远端剪贴板同步，等待时间由用户自定义；
- **快速模式**：MacBook App 通过 UU 端口映射调用 Mac mini 上的 `murmur-mirror`，直写 Mac mini 系统剪贴板，收到匹配哈希 ACK 后再自动发送 `⌘V`。

当前暂停点：快速模式已能自动输入，但用于等待 UU 恢复键盘接收能力的固定 `0.30s` 偏保守。用户已确认兼容模式在自定义 `0.25s` 下可以正常同步。下一次继续时，优先把快速模式的等待值降到 `0.15s` 做连续实机验证，不要继续扩展架构。

## 2. 已完成与已验证

### 基础功能与发布分支

当前分支：

```text
codex/uu-direct-paste
```

远端分支已包含以下提交：

```text
87c0d91 fix(mac): make UU paste delay configurable and refresh overlay
70a3938 feat(mac): add direct remote clipboard prototype
5ea98e4 feat(mac): route paste behavior by target app
5445221 fix(mac): fail closed when remote clipboard write fails
32dcc97 fix(mac): preserve text when direct paste target is unavailable
```

远端分支当前停在：

```text
32dcc9702dd41ef0985932f0598efdf41e2bb33d
```

本地还有两个已提交、尚未推送的实机修复：

```text
1cdd4f0 fix(mac): prepublish clipboard before direct UU paste
83738d2 fix(mac): wait for UU before direct paste
```

本地 HEAD：

```text
83738d237432141dd01ae133b4be7c562e993579
```

未修改远端 `master`。不要在用户明确要求前推送这两个新提交。

### 当前快速模式实际流程

当前代码的顺序是：

```text
识别文本完成
→ 将同一文本写入 MacBook 的 NSPasteboard.general（不向窗口输入）
→ 关闭 Overlay 并激活之前的 UU App
→ 每 0.05s 检查 UU 是否已成为前台，最多等待 0.40s
→ POST /clipboard 到 127.0.0.1:17771
→ 校验 HTTP、protocolVersion、ok 和文本 SHA-256 ACK
→ 固定等待 0.30s
→ 再次检查 Task 未取消、generation 未变化、原 UU 仍在前台
→ 才发送一次 ⌘V
```

关键文件：

```text
doubao-murmur/InputMethodSessionManager.swift
doubao-murmur/PasteRouter.swift
doubao-murmur/PasteHelper.swift
doubao-murmur/RemoteClipboardClient.swift
doubao-murmur/RemoteClipboardFailureHandler.swift
doubao-murmurTests/PasteRouterTests.swift
```

### 决定性实机证据

1. Mac mini 的 `murmur-mirror + LaunchAgent` 已部署；MacBook 通过 UU 映射访问：

   ```bash
   curl --fail --silent --show-error http://127.0.0.1:17771/health
   ```

   当前返回：

   ```json
   {"protocolVersion":1,"ok":true}
   ```

2. 诊断日志已确认快速模式完整经过：

   ```text
   route=uuDirect
   direct local prepublish before target restoration
   direct POST start
   direct ACK success
   direct focus recheck frontmost=true
   direct paste execution
   ```

3. 有效的远端剪贴板验证：Mac mini 使用 shell 历史中的命令读取，得到：

   ```text
   e51f542be856343a796a4e9069370fcec4a52cf18fdff687f655b25c18cf843e
   ```

   该哈希精确对应：

   ```text
   快速模式证据一
   ```

   这证明 POST、helper 写入和远端剪贴板持久结果均正确。

4. 在没有 `0.30s` settle 的版本中，自动 `⌘V` 没有输入；用户等待约 1 秒后在 MacBook 手动按 `⌘V`，远端输入成功。这把故障定位到“UU 已是前台，但尚未准备好接收自动键盘事件”的短暂窗口，而不是 helper、LaunchAgent、端口映射或剪贴板写入。

5. 加入 ACK 后 `0.30s` settle 后，用户已确认快速模式自动输入成功。

6. 当前代码测试：XCTest `12/12` 通过；主 App 和 helper 的 Release 构建与签名通过。兼容模式 UI、Overlay 和用户自定义等待逻辑未修改。

## 3. 一个必须保留的测量教训

下面这个哈希：

```text
5473a815754d54f86d488ac7a698464cd9352d3f3628b030a46917ca81be37f8
```

不是旧剪贴板文本的证据。它恰好是命令字符串本身的 SHA-256：

```text
pbpaste | shasum -a 256
```

如果先把这条命令粘贴到 Mac mini 终端，粘贴动作会先覆盖远端剪贴板，随后 `pbpaste` 只会读到命令自身。此前据此推断“UU 覆盖直写文本”是无效判断，已经撤回。

后续检查 Mac mini 剪贴板时必须：

1. 不复制命令；
2. 用终端“上箭头”调出 shell 历史；
3. 直接按回车；
4. 输出出现后才可以复制结果。

## 4. 当前机器与安装状态

工作区：

```text
/Users/devon/claude/doubao-murmur
```

交接时 Git 状态：

```text
## codex/uu-direct-paste...origin/codex/uu-direct-paste [ahead 2]
?? build-mirror-release/
?? build-release/
?? docs/doubao-ime-integration-research.md
?? hand-off/
```

这些未跟踪目录和文件没有进入功能提交。不要执行 `git clean`，不要删除或覆盖 `docs/`、`hand-off/`。

当前安装 App：

```text
/Applications/Doubao Murmur uu.app
Version: 1.2.1
Bundle ID: com.doubao.murmur
Executable: Doubao Murmur uu
PID snapshot: 86780
```

交接时 App 已改回正常 LaunchServices 启动，`PPID=1`，不是依赖 Codex PTY 的前台诊断进程。PID 只是快照，接手时应重新检查。

当前设置：

```text
uuRemotePasteMode=direct
pasteQuietPeriodSeconds=0.25
```

最新安装前的可回滚 App：

```text
/tmp/doubao-murmur-uu-settle-install.tI4oOZ/rollback/Doubao Murmur uu.app
```

更早一层回滚：

```text
/tmp/doubao-murmur-uu-install.xmMT6l/rollback/Doubao Murmur uu.app
```

`/tmp` 路径可能被系统清理；如果明天仍需回滚，先确认文件存在。不要假定这些路径永久有效。

## 5. 明天的推荐调参步骤

### 第一步：只读核对

```bash
cd /Users/devon/claude/doubao-murmur
git status --short --branch
git rev-parse HEAD
git rev-parse origin/codex/uu-direct-paste
defaults read com.doubao.murmur uuRemotePasteMode
defaults read com.doubao.murmur pasteQuietPeriodSeconds
curl --fail --silent --show-error http://127.0.0.1:17771/health
pgrep -fl '^/Applications/Doubao Murmur uu\.app/Contents/MacOS/Doubao Murmur uu$'
```

预期：本地 HEAD 为 `83738d2`、远端分支为 `32dcc97`、模式为 `direct`、兼容等待为 `0.25`、health 正常。

### 第二步：将快速模式首测值改为 0.15s

只修改：

```text
doubao-murmur/PasteRouter.swift
doubao-murmurTests/PasteRouterTests.swift
```

把：

```swift
DirectPasteSettlePolicy.delay = 0.30
```

改为：

```swift
DirectPasteSettlePolicy.delay = 0.15
```

同步更新“尚待实机验证”的注释和精确值测试。不要改兼容模式 `PasteHelper.remoteSyncQuietPeriod`，不要新增菜单项，不要改 Overlay。

### 第三步：静态与构建验收

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project doubao-murmur.xcodeproj \
  -scheme doubao-murmur \
  -configuration Debug \
  -derivedDataPath build \
  test

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project doubao-murmur.xcodeproj \
  -scheme doubao-murmur \
  -configuration Release \
  -derivedDataPath build-release \
  build
```

验收：全部 XCTest 通过、Release build 成功、`git diff --check` 通过、Overlay diff 为 0、`pasteQuietPeriodSeconds` 前后仍为 `0.25`。

### 第四步：替换测试 App

Release 产物内部名是 `Doubao Murmur.app`。安装为 UU 测试版时，必须保持现有独立结构：

```text
/Applications/Doubao Murmur uu.app
Contents/MacOS/Doubao Murmur uu
CFBundleExecutable=Doubao Murmur uu
```

因此不能只把 bundle 外层目录改名；还要在临时 staging 中改内部 executable、更新 Info.plist、重新 ad-hoc 签名并执行：

```bash
codesign --verify --deep --strict '/Applications/Doubao Murmur uu.app'
```

替换前将当前 App 移到新的临时回滚目录；不要覆盖 `/Applications/Doubao Murmur.app`。

### 第五步：实机参数验收

快速模式 `0.15s` 连续测试至少 5 次：

- 5/5 自动输入成功：保留 `0.15s`；
- 任意一次自动输入失败、但稍后手动 `⌘V` 成功：改为 `0.20s`，重新连续测试 5 次；
- `0.20s` 仍偶发失败：使用已验证成功的 `0.30s`，不要继续盲目压缩；
- 出现 POST/ACK 失败提示：这是另一类问题，停止调时序，重新检查 helper/映射。

然后切换兼容模式，用当前自定义 `0.25s` 至少回归 3 次，确认原有模式没有被破坏。

## 6. 安全边界与不要做的事

- 快速模式唯一允许发送 `⌘V` 的条件仍必须是：POST 成功、ACK 哈希匹配、Task 未取消、generation 一致、原 UU 目标仍是前台。
- 延迟结束后必须重新检查焦点；不能因为 ACK 成功就盲贴。
- 不自动降级到兼容模式；失败应 fail-closed。
- 保留提示文案：`被控制端剪贴板写入失败`。
- 不改当前 Overlay UI，不把快速模式调参暴露成新的 UI 选项。
- 不改兼容模式的自定义等待设计。
- 不需要修改或重新部署 Mac mini 的 helper/LaunchAgent；有效证据已证明它们工作正常。
- Mac mini 不需要 Xcode；`murmur-mirror` 是已编译的命令行 helper，不是 GUI App。
- 不要根据 `5473...` 再推断剪贴板覆盖；那是测试命令自身的哈希。
- 不要推送本地新提交，除非用户在实机调参完成后明确要求。

## 7. 完成标准

明天这轮调参只有在以下条件全部满足后才算完成：

1. 快速模式选定的等待值连续 5 次自动输入成功；
2. 兼容模式自定义 `0.25s` 连续 3 次正常；
3. 12 个及后续新增 XCTest 全部通过；
4. Release 构建与签名通过；
5. `uuRemotePasteMode` 切换正常，`pasteQuietPeriodSeconds` 未被重置；
6. Overlay UI 无变化；
7. 失败路径仍不盲贴、不自动降级；
8. 用户确认后才推送 `codex/uu-direct-paste`，继续保持 `master` 不变。

## 8. 接手后的第一步

先执行第 5 节的只读核对，不要重新研究 helper 或端口映射。确认状态与本文一致后，将 `DirectPasteSettlePolicy.delay` 从 `0.30` 改为 `0.15`，完成测试、构建和可回滚安装，再做 5 次连续 UU 实机验证。
