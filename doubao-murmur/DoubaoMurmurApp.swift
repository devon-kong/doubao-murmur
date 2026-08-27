import SwiftUI

@main
struct DoubaoMurmurApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            EmptyView()
        }
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var hotkeyManager: HotkeyManager!
    private var inputMethodSessionManager: InputMethodSessionManager!
    private var overlayPanel: OverlayPanel!
    private var appUpdater: AppUpdater?
    private let appState = AppState.shared

    func applicationDidFinishLaunching(_ notification: Notification) {
        print("[AppDelegate] applicationDidFinishLaunching (IME bridge)")
        setupStatusItem()
        setupOverlay()
        setupHotkey()
        setupInputMethodSessionManager()
        print("[AppDelegate] ✅ IME bridge setup complete")
    }

    func applicationWillTerminate(_ notification: Notification) {
        inputMethodSessionManager?.stop()
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "waveform", accessibilityDescription: "Doubao Murmur")
        }
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        rebuildMenu()
    }

    private func rebuildMenu() {
        guard let menu = statusItem.menu else { return }
        menu.removeAllItems()

        let statusMenuItem = NSMenuItem(title: "豆包输入法语音输入", action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        if appState.unconfirmedDirectPasteCount > 0 {
            let unknownItem = NSMenuItem(
                title: "快速粘贴状态未知：\(appState.unconfirmedDirectPasteCount) 笔（后续输入不受影响）",
                action: nil,
                keyEquivalent: ""
            )
            unknownItem.isEnabled = false
            menu.addItem(unknownItem)
        }
        menu.addItem(NSMenuItem.separator())
        menu.addItem(makeUUPasteModeItem())
        menu.addItem(makePasteDelayItem())
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "使用帮助", action: #selector(showHelp), keyEquivalent: "h"))
        menu.addItem(NSMenuItem(title: "检查更新", action: #selector(checkForUpdates), keyEquivalent: "u"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(quitApp), keyEquivalent: "q"))
    }

    /// Inline paste-delay editor: the field always shows the current value;
    /// the stepper applies ±0.25s immediately, typing + Return also works.
    private func makePasteDelayItem() -> NSMenuItem {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 270, height: 28))

        let label = NSTextField(labelWithString: "剪贴板稳定时间(秒)")
        label.font = NSFont.menuFont(ofSize: 13)
        label.frame = NSRect(x: 20, y: 4, width: 132, height: 20)
        container.addSubview(label)

        let stepper = NSStepper(frame: NSRect(x: 232, y: 2, width: 20, height: 24))
        stepper.minValue = 0.25
        stepper.maxValue = 10
        stepper.increment = 0.25
        stepper.valueWraps = false
        stepper.doubleValue = PasteHelper.remoteSyncQuietPeriod
        stepper.target = self
        stepper.action = #selector(pasteDelayStepperChanged(_:))
        container.addSubview(stepper)

        let field = NSTextField(frame: NSRect(x: 166, y: 2, width: 58, height: 24))
        field.tag = Self.pasteDelayFieldTag
        field.stringValue = String(format: "%g", PasteHelper.remoteSyncQuietPeriod)
        field.alignment = .right
        field.target = self
        field.action = #selector(pasteDelayFieldChanged(_:))
        container.addSubview(field)

        let item = NSMenuItem()
        item.view = container
        return item
    }

    private func makeUUPasteModeItem() -> NSMenuItem {
        let item = NSMenuItem(title: "UU 远程粘贴方式", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let currentMode = PasteRoutingSettings().uuPasteMode
        for mode in UUPasteMode.allCases {
            let modeItem = NSMenuItem(title: mode.menuTitle, action: #selector(uuPasteModeChanged(_:)), keyEquivalent: "")
            modeItem.target = self
            modeItem.representedObject = mode.rawValue
            modeItem.state = mode == currentMode ? .on : .off
            submenu.addItem(modeItem)
        }
        item.submenu = submenu
        return item
    }

    @objc private func uuPasteModeChanged(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let mode = UUPasteMode(rawValue: rawValue) else { return }
        let settings = PasteRoutingSettings()
        settings.uuPasteMode = mode
        print("[AppDelegate] UU paste mode set to \(mode.rawValue)")
        rebuildMenu()
    }

    private static let pasteDelayFieldTag = 1001

    @objc private func pasteDelayStepperChanged(_ sender: NSStepper) {
        // Round to 2 decimals so 0.25 steps never accumulate float dust.
        let value = (sender.doubleValue * 100).rounded() / 100
        PasteHelper.setQuietPeriod(value)
        if let field = sender.superview?.viewWithTag(Self.pasteDelayFieldTag) as? NSTextField {
            field.stringValue = String(format: "%g", value)
        }
        print("[AppDelegate] Paste quiet period set to \(value)s (stepper)")
    }

    @objc private func pasteDelayFieldChanged(_ sender: NSTextField) {
        let raw = sender.stringValue
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: ".")
        guard let value = Double(raw), value >= 0.1, value <= 10 else {
            NSSound.beep()
            sender.stringValue = String(format: "%g", PasteHelper.remoteSyncQuietPeriod)
            return
        }
        PasteHelper.setQuietPeriod(value)
        sender.stringValue = String(format: "%g", value)
        if let stepper = sender.superview?.subviews.compactMap({ $0 as? NSStepper }).first {
            stepper.doubleValue = value
        }
        print("[AppDelegate] Paste quiet period set to \(value)s")
    }

    @objc private func showHelp() {
        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "未知"
        let buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "未知"

        let alert = NSAlert()
        alert.messageText = "Doubao Murmur"
        alert.informativeText = """
        版本: \(appVersion) (\(buildNumber))

        本版本使用本机豆包输入法完成语音输入。

        使用方法:
        1. 确保系统已启用豆包输入法
        2. 按 ⌃ Control + / 开始。热键完全释放、输入框聚焦和豆包输入法就绪后，应用会自动开始语音输入
        3. 说完后手动按一次物理右 Command 停止豆包；输入法下划线消失后，应用才冻结最终文字并按所选模式粘贴
        4. 录音期间重复按 ⌃ Control + / 会被忽略；按 ESC 则安全取消，不复制粘贴，并恢复原来的输入法

        UU 远程可选择兼容模式（UU 正常剪贴板同步）或快速模式（需 Mac mini helper 和端口映射）。

        兼容模式如出现旧剪贴板内容，可在菜单的「剪贴板稳定时间」调大秒数后回车。快速模式需先在 Mac mini 安装并验证 helper。

        如果豆包输入法未安装或未启用，本次会话不会开始。
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "好的")
        alert.runModal()
    }

    @objc private func checkForUpdates() {
        Task {
            do {
                if let update = try await UpdateChecker.check() {
                    let alert = NSAlert()
                    alert.messageText = "发现新版本"
                    alert.informativeText = "新版本 v\(update.version) 已发布，是否立即更新？"
                    alert.alertStyle = .informational
                    alert.addButton(withTitle: "立即更新")
                    alert.addButton(withTitle: "稍后再说")
                    NSApp.activate(ignoringOtherApps: true)
                    let response = alert.runModal()
                    if response == .alertFirstButtonReturn {
                        let updater = AppUpdater()
                        self.appUpdater = updater
                        updater.downloadAndInstall(update: update)
                    }
                } else {
                    let alert = NSAlert()
                    alert.messageText = "检查更新"
                    alert.informativeText = "当前已是最新版本。"
                    alert.alertStyle = .informational
                    alert.addButton(withTitle: "好的")
                    NSApp.activate(ignoringOtherApps: true)
                    alert.runModal()
                }
            } catch {
                let alert = NSAlert()
                alert.messageText = "检查更新失败"
                alert.informativeText = "无法连接到 GitHub，请检查网络连接。\n\(error.localizedDescription)"
                alert.alertStyle = .warning
                alert.addButton(withTitle: "好的")
                NSApp.activate(ignoringOtherApps: true)
                alert.runModal()
            }
        }
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }

    private func setupOverlay() {
        overlayPanel = OverlayPanel(appState: appState)
        print("[AppDelegate] Overlay panel created")
    }

    private func setupHotkey() {
        hotkeyManager = HotkeyManager()
        print("[AppDelegate] Hotkey manager created")
    }

    private func setupInputMethodSessionManager() {
        inputMethodSessionManager = InputMethodSessionManager(
            appState: appState,
            overlayPanel: overlayPanel,
            hotkeyManager: hotkeyManager
        )
        inputMethodSessionManager.start()
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu()
    }
}
