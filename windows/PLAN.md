# Windows 版：设计决策与验证清单

实现已完成，代码见 [`src-tauri/`](src-tauri)，用法见 [README](README.md)。
本文件记录做过的取舍，以及真机验证要覆盖的项。

## 走到 Tauri 的过程

1. 最初评估了三条路：复用 Linux 的 Python 核心 + PySide6、原生 C#/WinUI 3、Tauri。
2. 先按 C# / WinUI 3 实现并跑通了 CI。产物 **安装包 42 MB、占盘 160 MB**——
   自带 .NET 运行时（~60 MB）、WinUI（~28 MB）、Windows SDK 的 CsWinRT 投影（23.7 MB）。
   期间还发现 `NAudio` metapackage 会连带 `NAudio.WinForms`，把整个
   `Microsoft.WindowsDesktop.App`（WPF + WinForms，59.8 MB）拖进自包含发布。
3. 改用 Tauri v2 重写：**安装包 1.30 MB，可执行文件 3.58 MB**。

C# 实现保留在本分支的历史里（`refactor(windows)!: replace the WinUI 3 port with Tauri`
之前的提交），需要时可回溯。

## 关键决策

**Tauri 只替换外壳。** 全局热键、粘贴、不抢焦点的窗口仍然是手写 Win32，
只是从 C# 的 P/Invoke 变成 Rust 的 `windows` crate。Tauri 真正省掉的是：
托盘 API、窗口管理、WebView 宿主、以及 CI 里 WinUI 那套 PRI / AppxPackage 工具链。

**热键必须自己写。** `RegisterHotKey`（Tauri 的 global-shortcut 插件用的就是它）
注册不了裸修饰键，所以 `hotkey.rs` 在独立的消息循环线程上装 `WH_KEYBOARD_LL`。

**登录提参走 cookie 通道，不走 IPC，也不碰 COM。** 详见 README 的对应小节。
这是整个移植里风险最大的一环，这个设计把它降到只依赖一个 Tauri API。

**音频自己重采样。** WASAPI 共享模式只按设备原生格式打开（通常 48 kHz），
`resample.rs` 用 biquad 低通 + 线性插值降到 16 kHz——语音 ASR 对此足够宽容，
省掉一个重采样库依赖。macOS 用 `AVAudioConverter` 做同一件事；Linux 靠 PipeWire，
不需要。

**不移植**：掌机触摸软键盘、layer-shell、evdev、flatpak。

## 真机验证清单

CI 只能保证编译、单测（34 项）和出产物。以下必须在真机上过一遍：

- [ ] 托盘图标出现，右键菜单可弹出，各项可点
- [ ] 「登录豆包」→ 完成登录 → 窗口自动关闭，托盘变「状态：已登录」
- [ ] `%APPDATA%\doubao-murmur\asr_params.json` 生成，cookie 数量 > 0
- [ ] 按右 Alt → 悬浮窗出现 → 说话 → 实时出字 → 再按 → 粘贴到输入框
- [ ] **悬浮窗不抢焦点**（识别结果没有粘到悬浮窗自己身上）
- [ ] 悬浮窗半透明、圆角正常；可拖动，重开后位置被记住
- [ ] `ESC` 取消，不粘贴
- [ ] 粘贴目标覆盖 Chrome / Word / Windows Terminal / VS Code / 微信
- [ ] 切到 AltGr 布局（de / fr），确认 AltGr+键 仍能打出重音字符，且右 Alt 单击仍能触发
- [ ] 托盘里换热键为右 Ctrl，验证生效
- [ ] 「拦截热键」勾选后，右 Alt 不再唤出菜单栏
- [ ] 「开机自启」勾选后重启，程序自动启动
- [ ] 多显示器 + 100/125/150/200% DPI 下悬浮窗位置正确
- [ ] 凭证过期时弹出重新登录提示（可手动删掉 `asr_params.json` 里的 cookie 值模拟）
- [ ] 提权窗口（管理员终端）下的行为符合文档描述（收不到键、粘不进去）

出问题先看 `%LOCALAPPDATA%\doubao-murmur\app.log`，托盘菜单「打开日志」可直接打开。
