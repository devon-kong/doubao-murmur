import AppKit
import Foundation

enum DirectPasteOutcome {
    case remoteWriteFailed
    /// The controller cannot prove that a one-shot remote event did not occur.
    /// Cancellation, a stale generation, and a lost/late acknowledgement all
    /// belong here and must be treated as ambiguous rather than harmless.
    case unconfirmed
    /// A preceding request remains unconfirmed, so this session deliberately
    /// did not create a second `/paste` request.
    case blockedByPreviousUnconfirmedRequest
    /// Recording did not start because direct mode remains blocked by a prior
    /// ambiguous request. There is no new transcription text to copy.
    case recordingBlockedByPreviousUnconfirmedRequest
}

/// Decides whether it is safe to start a new recording before the controller
/// touches focus, input sources, overlays, or captures a paste target.
enum DirectPasteSessionStartDecision: Equatable {
    case start
    case markInFlightUnconfirmedAndStop
    case blockedByPreviousUnconfirmedAndStop
}

struct DirectPasteSessionStartPolicy {
    static func decision(
        mode: UUPasteMode,
        gateState: DirectPasteRequestGateState
    ) -> DirectPasteSessionStartDecision {
        switch gateState {
        case .idle:
            return .start
        case .inFlight:
            return .markInFlightUnconfirmedAndStop
        case .unconfirmed:
            return mode == .compatibility ? .start : .blockedByPreviousUnconfirmedAndStop
        }
    }
}

/// A small main-actor-owned state machine for the one-shot `/paste` request.
/// Once an acknowledgement becomes ambiguous, direct mode stays blocked for
/// this process. Switching to compatibility mode does not reset this gate;
/// the controller must not create a second request that could race with the
/// first remote Command-V.
enum DirectPasteRequestGateState: Equatable {
    case idle
    case inFlight(UUID)
    case unconfirmed(UUID)
}

struct DirectPasteRequestGate {
    private(set) var state: DirectPasteRequestGateState = .idle

    mutating func begin(requestId: UUID) -> Bool {
        guard case .idle = state else { return false }
        state = .inFlight(requestId)
        return true
    }

    mutating func acknowledge(requestId: UUID) -> Bool {
        guard case let .inFlight(activeRequestId) = state, activeRequestId == requestId else {
            return false
        }
        state = .idle
        return true
    }

    mutating func markUnconfirmed(requestId: UUID) -> Bool {
        guard case let .inFlight(activeRequestId) = state, activeRequestId == requestId else {
            return false
        }
        state = .unconfirmed(requestId)
        return true
    }
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

    static let requestBlocked = RemoteClipboardFailurePrompt(
        title: "本轮未发送到被控制端",
        message: "上一轮被控制端粘贴仍未确认，因此本轮没有发送粘贴请求。本轮文字已尝试保留到本机剪贴板；请先检查上一轮目标输入框，不要自动重试，可切换到兼容模式。"
    )

    static let recordingBlocked = RemoteClipboardFailurePrompt(
        title: "快速模式仍被上一轮未确认请求阻断",
        message: "本轮录音尚未开始，也没有发送新的粘贴请求。请先检查上一轮目标输入框；可切换到兼容模式后重新开始录音。"
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
        case .remoteWriteFailed, .unconfirmed, .blockedByPreviousUnconfirmedRequest:
            return DirectPasteFailurePlan(shouldCopyLocally: true, shouldPresentWriteFailure: true, shouldPaste: false)
        case .recordingBlockedByPreviousUnconfirmedRequest:
            return DirectPasteFailurePlan(shouldCopyLocally: false, shouldPresentWriteFailure: true, shouldPaste: false)
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
            let prompt: RemoteClipboardFailurePrompt
            switch outcome {
            case .blockedByPreviousUnconfirmedRequest:
                prompt = .requestBlocked
            case .recordingBlockedByPreviousUnconfirmedRequest:
                prompt = .recordingBlocked
            case .remoteWriteFailed, .unconfirmed:
                prompt = .writeFailure
            }
            present(prompt) { self.switchToCompatibilityForFutureSessions() }
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
