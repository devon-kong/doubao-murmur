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
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "使用帮助", action: #selector(showHelp), keyEquivalent: "h"))
        menu.addItem(NSMenuItem(title: "检查更新", action: #selector(checkForUpdates), keyEquivalent: "u"))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "退出", action: #selector(quitApp), keyEquivalent: "q"))
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
        2. 第一次按 ⌃ Control + /，应用会打开输入框、切换豆包输入法并自动开始语音输入
        3. 第二次按 ⌃ Control + /，应用会停止语音输入，等待文字稳定后自动复制粘贴
        4. 按 ESC 取消本次输入，不复制粘贴，并恢复原来的输入法

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
