# Mac mini 安装说明（无需 Xcode）

这个安装包只安装 Mac mini 被控制端所需的 `murmur-mirror`。Doubao Murmur 主 App 仍运行在 MacBook 控制端。

## 1. 安装 helper

1. 将整个解压后的文件夹复制到 Mac mini；不要只复制 `murmur-mirror` 单文件。
2. 双击 `install.command`。若 macOS 不允许直接打开，请右键它并选择“打开”。
3. 安装器会校验 SHA-256、代码签名和本机架构，然后安装到当前用户目录并启动，不需要 Xcode、Homebrew、命令行工具、管理员密码或 `sudo`。
4. 安装器会把旧版 helper 和 LaunchAgent 备份到：

   ```text
   ~/Library/Application Support/Doubao Murmur/backups/<时间戳>/
   ```

安装位置：

```text
helper:      ~/Library/Application Support/Doubao Murmur/murmur-mirror
LaunchAgent: ~/Library/LaunchAgents/com.doubao.murmur.mirror.plist
日志:        ~/Library/Logs/Doubao Murmur/
订单事件库:  ~/Library/Application Support/Doubao Murmur/paste-orders-helper.sqlite3
```

本包使用 ad-hoc 签名，没有 Apple 公证。安装器不会自动移除 Gatekeeper 隔离属性。若 LaunchAgent 日志明确显示被 macOS 阻止，先核对本包 SHA-256，再只对已安装 helper 执行：

```bash
xattr -d com.apple.quarantine "$HOME/Library/Application Support/Doubao Murmur/murmur-mirror"
launchctl kickstart -k "gui/$(id -u)/com.doubao.murmur.mirror"
```

## 2. 授予辅助功能权限

这是快速模式真实投递 Command-V 的必要条件。

1. 在 Mac mini 打开“系统设置 → 隐私与安全性 → 辅助功能”。
2. 点“+”。在文件选择框按 `Command-Shift-G`。
3. 输入：

   ```text
   ~/Library/Application Support/Doubao Murmur/murmur-mirror
   ```

4. 添加后打开其开关。
5. 双击 `verify.command`。通过条件包括：

   ```json
   {"ok":true,"protocolVersion":2,"accessibilityTrusted":true}
   ```

如果更新 helper 后权限变回 `false`，请在辅助功能列表中移除旧项，再重新添加上述实际路径。ad-hoc 签名无法保证跨构建沿用 TCC 授权。

## 3. 在 MacBook 的 UU 中配置端口映射

先用 UU 从 MacBook 连接这台 Mac mini，再在 MacBook 控制端操作：

1. 打开 UU 的“端口映射”。
2. 当前设备选择这台 Mac mini，点击“添加”。
3. 填写并“保存后立即启用”：

   | 字段 | 值 |
   | --- | --- |
   | 名称 | `murmur-mirror` |
   | 本地端口 | `17771` |
   | 目标地址 | `127.0.0.1` |
   | 目标端口 | `17771` |

UU 当前界面没有独立协议字段；该映射使用 TCP。启用成功后，UU 会在 MacBook 本机 `127.0.0.1:17771` 监听，再转发到 Mac mini 的 `127.0.0.1:17771`。

若提示“本地端口已被占用”，先检查 MacBook 是否还运行了本地 `murmur-mirror` 或已有同端口规则；不要随意改端口，因为当前 Doubao Murmur 固定访问 `127.0.0.1:17771`。

## 4. 在 MacBook 验证映射

在 MacBook 的 Terminal 运行：

```bash
curl --fail --silent --show-error --max-time 3 \
  http://127.0.0.1:17771/health
```

通过条件：

```json
{"ok":true,"protocolVersion":2,"accessibilityTrusted":true}
```

JSON 字段顺序可能不同。若 `accessibilityTrusted` 为 `false`，回到第 2 步；连接失败则检查 Mac mini helper、UU 当前设备、规则启用状态和端口占用。

## 5. 一次性真实验收

1. 在 Mac mini 打开一个无副作用的空白文本框并保持为前台目标。
2. 在 MacBook 的 Doubao Murmur 选择快速模式，只发起一次短文本录音。
3. 验收目标是：文本只插入一次、插入到预期输入框。
4. 若控制端菜单显示某笔“状态未知”，先观察目标输入框，**不要重试该笔订单**；状态未知不会阻断后续快速输入。

订单事件库只记录请求标识、顺序、阶段时间、文字长度、目标进程和错误码等诊断元数据，不保存识别文字、剪贴板内容、窗口标题或默认文字哈希。分析问题时应通过 `request_id`、`controller_session_id` 和 `sequence` 与控制端事件库关联。

认证/token 当前按项目决策暂缓。前提是 helper 只监听 Mac mini loopback，UU 也只在 MacBook loopback 建立本地监听。若任何一端暴露到 LAN、长期开放给其他用户或准备公开分发，认证立即升级为部署前必做。
