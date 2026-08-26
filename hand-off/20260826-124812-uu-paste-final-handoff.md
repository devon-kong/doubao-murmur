# UU 粘贴重设计：最终交接

更新时间：2026-08-26 12:48（Asia/Shanghai）

## 当前目标与最终决策

Doubao Murmur 在网易 UU 控制 Mac mini 时提供两条互不竞争的粘贴路径：

- **兼容模式**：沿用 UU 的本机到受控端剪贴板同步；用户设定的 `Q` 即“剪贴板稳定时间（秒）”。
- **快速模式**：控制端不再参与本地剪贴板同步或本地按键投递；Mac mini 上的 `murmur-mirror` 写入其本机剪贴板并投递一次 Command-V。

最终状态以当前工作树为准；下述早期提交中的“预发布控制端剪贴板”“等待 UU 前台”“0.3 秒 settle”和控制端 Command-V 均已被后续设计移除。

## 兼容模式

1. 采用单阶段轮询，每 `0.05s` 检查一次本机剪贴板。
2. 设最大预算 `maxWait = max(2.0, 2 * Q)`。
3. 剪贴板连续稳定满 `Q` 后，再做一次最终复查；只有复查仍为本轮文字才发送粘贴。
4. 若 `remainingBudget < remainingStableNeeded`，立即结束本轮：重新保留本轮文字到本机剪贴板、提示“兼容模式剪贴板未稳定”，且**不自动粘贴**。提示的完整内容为：
   - 标题：`兼容模式剪贴板未稳定`
   - 正文：`文字已重新复制到本机剪贴板，本次未自动粘贴。请手动粘贴，或调大剪贴板稳定时间。`
   - 按钮：`好的`
5. 菜单与帮助文案均使用“剪贴板稳定时间”。

## 快速模式

1. 控制端向受控端 helper 的 `POST /paste` 发送 `{ requestId, text }`；协议版本保持 `1`，现有 `POST /clipboard` 仍保留。
2. `requestId` 使用本轮唯一 UUID。helper 在同一进程内维护最多 256 条已完成请求的幂等缓存；重复 ID 返回首次结果，不再次投递按键。进行中的同 ID 请求返回冲突。
3. helper 使用 `AXIsProcessTrusted()` 检查辅助功能权限，写入并回读受控端系统剪贴板，发送前两次核验受控端前台 PID 未变化，然后只投递一次 Command-V。
4. 控制端严格校验 HTTP 200、`ok`、`protocolVersion`、文本 SHA-256、匹配的 `requestId` 与 `eventPosted == true`。不等待 UU 前台、不等 0.3 秒、不预发布控制端剪贴板，也不在控制端发送 Command-V。
5. 控制端不会自动重试 `/paste`。发生失败或回执不确定时，会将文字复制回控制端本机剪贴板并显示提示。

## 精确失败提示

- 标题：`被控制端粘贴未确认`
- 正文：`本次粘贴可能未执行，也可能已执行但回执丢失。请先检查目标输入框，不要自动重试；可检查被控制端助手、辅助功能权限和 UU 端口映射，或切换到兼容模式。`
- 按钮：`好的` / `切换到兼容模式`

这项措辞刻意不把 HTTP/传输失败表述为“受控端没有粘贴”：helper 可能已经投递事件，而 ACK 在返回途中丢失。

## 本分支提交

实现代码最新提交（不含本文档提交）：`57b6eaad05a44cb1366d6e5061da3eb99c731dbe`

最终发布后，`master` 与 `codex/uu-direct-paste` 指向同一份本文档所属的提交；本文不在正文中自引用该提交的哈希。

本次最终状态相关提交（较早方案由后续提交覆盖的部分，以当前代码为准）：

```text
1cdd4f0 fix(mac): prepublish clipboard before direct UU paste
83738d2 fix(mac): wait for UU before direct paste
3a02350 feat(mac): paste locally on controlled Mac
57b6eaa fix(mac): clarify unconfirmed remote paste
```

## 验证与独立审核证据

主 agent 独立审核后要求补齐的文案与不确定性提示已经修正。已执行的验证：

```text
git diff --check                              通过
完整 Debug XCTest                             13/13 通过
App Release build                             通过
codesign --verify --deep --strict             通过
murmur-mirror Release build                   通过
安全 smoke                                    通过
提示文案相关 PasteRouterTests                 10/10 通过
```

安全 smoke 仅调用 `/health`、无效的 `/paste` 请求及 `/clipboard` 往返，并恢复原剪贴板；它没有调用有效 `/paste`，不会触发真实 Command-V。

## 发布后独立 review / 当前暂停点

外部 ChatGPT 5.6 Sol / Pro 已完成仓库克隆和源码扫描，但正式 A-F 结构化输出因 ChatGPT Internal Server Error 未生成；不能把它表述为已有完整报告。以下核心 findings 已由主 agent 对照当前代码独立确认：

1. **P1：最长等待边界可被绕过。** `PasteHelper.defendThenPaste` 在 `stableElapsed >= stableWindow` 的成功分支先执行 `simulatePaste()`，`deadline` / 可达性判断位于其后。若主队列调度延迟，可能已经超过 `maxWait` 仍然粘贴，违反最长等待承诺。修复方向：任何成功粘贴前先验证 `now <= deadline`，并使用统一终止路径。
2. **P1：兼容模式缺少最终目标前台复查。** 它只在开始防守前等待目标 App 成为前台；Q 等待期间没有最终目标 PID / 前台复查。用户在此间切换 App 后，Command-V 可能发往其他前台 App。修复方向：将目标身份传入，粘贴前复查；失败时保留文字并提示，且不粘贴。
3. **P2：稳定性未涵盖同文本的剪贴板变动。** 当前只比较字符串，未使用 `NSPasteboard.changeCount`；若剪贴板在两个 `0.05s` tick 之间被改写后恢复相同文本，稳定窗口不会重置。修复方向：记录并复查 `changeCount`，任何变化都重置稳定计时；自身 rewrite 后要更新基线。
4. **缺失测试。** 需要覆盖：deadline 后的 tick 不得粘贴、等待中目标切换不得粘贴、`changeCount` 改变但文本相同必须重置，以及真实 timer / clipboard integration。快速模式还需要覆盖 Mac mini Accessibility、有效 `/paste`、ACK 丢失、幂等和 UU 端到端场景。

**当前结论：**快速模式未发现新的代码级 blocker；兼容模式在上述两项 P1 修复前暂停部署和实机验收。不要因为既有构建、XCTest 或安全 smoke 通过而绕过这个暂停点。

## Git 状态（写本文档前）

```text
branch: codex/uu-direct-paste
HEAD:   57b6eaad05a44cb1366d6e5061da3eb99c731dbe
origin/codex/uu-direct-paste: 与 HEAD 一致
origin/master: 0c74fbfea6e15574c4dd4746577ad52658c54f7f
```

`origin/master` 已在当前功能分支祖先链上，因此发布时只能做无冲突快进，不能 force push。未跟踪的 `build-mirror-release/`、`build-release/`、`docs/doubao-ime-integration-research.md` 和既有 `hand-off/` 内容不属于功能提交，必须保留且不纳入提交。

## 尚未完成

- 尚未将本版 `murmur-mirror` 部署到 Mac mini。
- 尚未为 Mac mini 的 helper 实测并确认辅助功能授权。
- 尚未用 UU 端口映射完成一次端到端真实粘贴验证。

## 已知风险与边界

- `eventPosted` 仅表示 helper 已投递 CGEvent，不能证明目标应用已经接收或插入了文本。
- 受控端前台应用在核验与事件投递之间仍存在不可完全消除的焦点竞态。
- loopback helper 没有新增额外认证；其网络暴露边界依赖 UU 端口映射与本机 loopback 监听配置。
- 幂等缓存是进程内状态；helper 重启会丢失它。因此发生传输不确定时禁止自动重试，以免重启边界外重复投递。
- 真实 Command-V 与 Mac mini 无障碍授权属于实机验证范围，当前构建、测试和安全 smoke 不能替代。

## 接手第一步

先在 Mac mini 上以将部署的 Release helper 检查 `/health` 中的 `accessibilityTrusted`，确认辅助功能授权与 UU 端口映射；随后只进行一次受控输入框的快速模式端到端验证，并先观察目标输入框。若 ACK 未确认，遵循提示检查输入框，**不要自动重试**。验证通过后再分别回归兼容模式的自定义 `Q`。
