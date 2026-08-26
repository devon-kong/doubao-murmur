import AppKit
import Foundation

enum DirectPasteOutcome {
    case remoteWriteFailed
    case cancelledOrStale
}

struct DirectPasteFailurePlan: Equatable {
    let shouldCopyLocally: Bool
    let shouldPresentWriteFailure: Bool
    let shouldPaste: Bool
}

struct RemoteClipboardFailurePrompt: Equatable {
    let title: String
    let message: String

    static let writeFailure = RemoteClipboardFailurePrompt(
        title: "被控制端粘贴未确认",
        message: "本次粘贴可能未执行，也可能已执行但回执丢失。请先检查目标输入框，不要自动重试；可检查被控制端助手、辅助功能权限和 UU 端口映射，或切换到兼容模式。"
    )
}

/// Pure policy and a small effect boundary for direct-paste completion. It
/// deliberately contains no HTTP, AppKit, or session-generation details.
struct DirectPasteFailureHandler {
    private let settings: PasteRoutingSettings

    init(settings: PasteRoutingSettings = PasteRoutingSettings()) {
        self.settings = settings
    }

    static func plan(for outcome: DirectPasteOutcome) -> DirectPasteFailurePlan {
        switch outcome {
        case .remoteWriteFailed:
            return DirectPasteFailurePlan(shouldCopyLocally: true, shouldPresentWriteFailure: true, shouldPaste: false)
        case .cancelledOrStale:
            return DirectPasteFailurePlan(shouldCopyLocally: false, shouldPresentWriteFailure: false, shouldPaste: false)
        }
    }

    func handle(
        outcome: DirectPasteOutcome,
        text: String,
        copyTextLocally: (String) -> Void,
        present: @escaping (RemoteClipboardFailurePrompt, @escaping () -> Void) -> Void
    ) {
        let plan = Self.plan(for: outcome)
        if plan.shouldCopyLocally {
            copyTextLocally(text)
        }
        if plan.shouldPresentWriteFailure {
            present(.writeFailure) { self.switchToCompatibilityForFutureSessions() }
        }
    }

    func switchToCompatibilityForFutureSessions() {
        settings.uuPasteMode = .compatibility
    }
}

@MainActor
protocol RemoteClipboardFailurePresenting: AnyObject {
    func present(_ prompt: RemoteClipboardFailurePrompt, onSwitchToCompatibility: @escaping () -> Void)
}

/// The only AppKit-specific part of the direct-paste failure path. The gate
/// avoids duplicate modal alerts when multiple network completions race.
@MainActor
final class RemoteClipboardFailurePresenter: RemoteClipboardFailurePresenting {
    private var isPresenting = false

    func present(_ prompt: RemoteClipboardFailurePrompt, onSwitchToCompatibility: @escaping () -> Void) {
        guard !isPresenting else { return }
        isPresenting = true
        defer { isPresenting = false }

        let alert = NSAlert()
        alert.messageText = prompt.title
        alert.informativeText = prompt.message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好的")
        alert.addButton(withTitle: "切换到兼容模式")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn {
            onSwitchToCompatibility()
        }
    }
}
