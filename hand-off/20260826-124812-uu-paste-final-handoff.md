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
4. 若 `remainingBudget < remainingStableNeeded`，立即结束本轮：重新保留本轮文字到本机剪贴板、提示“兼容模式剪贴板未稳定”，且**不自动粘贴**。
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

这项措辞刻意不把 HTTP/传输失败表述为“受控端没有粘贴”：helper 可能已经投递事件，而 ACK 在返回途中丢失。

## 本分支提交

当前 HEAD：`57b6eaad05a44cb1366d6e5061da3eb99c731dbe`

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
