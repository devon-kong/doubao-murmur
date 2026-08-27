import AppKit
import CoreGraphics
import Foundation
import os

private let sessionLogger = Logger(
    subsystem: "com.doubao.murmur",
    category: "InputMethodSession"
)
private let functionKeyDiagnosticsLogger = Logger(
    subsystem: "com.doubao.murmur",
    category: "FunctionKeyDiagnostics"
)

struct RecordingReadinessGate {
    enum Action: Equatable {
        case none
        case postRightCommandStart
    }

    private var focusIsReady = false
    private var inputSourceIsReady = false
    private var hotkeyIsReleased = false
    private var didAuthorizeStart = false
    private var isCancelled = false

    mutating func markFocusReady() -> Action {
        focusIsReady = true
        return authorizationAction()
    }

    mutating func markInputSourceReady() -> Action {
        inputSourceIsReady = true
        return authorizationAction()
    }

    mutating func markHotkeyReleased() -> Action {
        hotkeyIsReleased = true
        return authorizationAction()
    }

    mutating func cancel() {
        isCancelled = true
    }

    private mutating func authorizationAction() -> Action {
        guard !isCancelled,
              focusIsReady,
              inputSourceIsReady,
              hotkeyIsReleased,
              !didAuthorizeStart else { return .none }
        didAuthorizeStart = true
        return .postRightCommandStart
    }
}

enum InputMethodSessionPhase: Equatable {
    case idle
    case preparing
    case recording
    case stopping
}

enum SessionToggleAction: Equatable {
    case start
    case ignoreWhileRecording
    case cancel
}

private enum RightCommandTapKind {
    case start

    var diagnosticPrefix: String {
        switch self {
        case .start: "right_command_start"
        }
    }
}

struct SessionTogglePolicy {
    static func action(for phase: InputMethodSessionPhase) -> SessionToggleAction {
        switch phase {
        case .idle:
            return .start
        case .preparing, .stopping:
            return .cancel
        case .recording:
            return .ignoreWhileRecording
        }
    }
}

struct MarkedTextCommitGate {
    enum Action: Equatable {
        case none
        case markedTextStarted
        case markedTextCommitted
        case focusLost
        case timedOut
    }

    private var didObserveMarkedText = false
    private var isStopping = false
    private var didCommit = false
    private var isCancelled = false

    mutating func observe(hasMarkedText: Bool) -> Action {
        guard !isCancelled else { return .none }
        if hasMarkedText {
            guard !didObserveMarkedText else { return .none }
            didObserveMarkedText = true
            return .markedTextStarted
        }
        guard isStopping, didObserveMarkedText, !didCommit else { return .none }
        didCommit = true
        return .markedTextCommitted
    }

    mutating func beginStopping(currentlyHasMarkedText: Bool) -> Action {
        guard !isCancelled else { return .none }
        isStopping = true
        return observe(hasMarkedText: currentlyHasMarkedText)
    }

    /// The panel must remain the active text client until the input method has
    /// committed its marked text. A lost focus is never recovered by assuming
    /// that the marked text was committed.
    mutating func observeFocus(isConfirmed: Bool) -> Action {
        guard !isCancelled, isStopping else { return .none }
        guard !isConfirmed else { return .none }
        isCancelled = true
        return .focusLost
    }

    /// This is an escape hatch only. It must not authorize a final-text lock,
    /// because an input method that never unmarks may still hold a partial
    /// composition.
    mutating func expireWaitingForCommit() -> Action {
        guard !isCancelled, isStopping, !didCommit else { return .none }
        isCancelled = true
        return .timedOut
    }

    mutating func cancel() {
        isCancelled = true
    }
}

/// A physical, bare right Command press is the user's stop gesture. Never
/// close the text client until that physical key has returned up and Doubao
/// has committed marked text for this stopping session.
struct PhysicalRightCommandStopGate {
    enum Action: Equatable {
        case none
        case startedStopping
        case scheduleFinalTextLock
        case nonBareCommand
        case timedOut
    }

    private var markedTextCommitted = false
    private var physicalRightCommandIsDown = false
    private var physicalRightCommandUpObserved = false
    private var didAuthorizeFinalLock = false
    private var isCancelled = false

    mutating func observePhysicalRightCommandDown() -> Action {
        guard !isCancelled, !physicalRightCommandIsDown, !physicalRightCommandUpObserved else { return .none }
        physicalRightCommandIsDown = true
        return .startedStopping
    }

    mutating func observePhysicalRightCommandUp() -> Action {
        guard !isCancelled, physicalRightCommandIsDown else { return .none }
        physicalRightCommandIsDown = false
        physicalRightCommandUpObserved = true
        return authorizationAction()
    }

    mutating func observeOrdinaryKeyDown() -> Action {
        guard !isCancelled, physicalRightCommandIsDown else { return .none }
        isCancelled = true
        return .nonBareCommand
    }

    mutating func markMarkedTextCommitted() -> Action {
        guard !isCancelled else { return .none }
        markedTextCommitted = true
        return authorizationAction()
    }

    mutating func expireWaiting() -> Action {
        guard !isCancelled, !didAuthorizeFinalLock else { return .none }
        isCancelled = true
        return .timedOut
    }

    mutating func cancel() {
        isCancelled = true
    }

    private mutating func authorizationAction() -> Action {
        guard markedTextCommitted,
              physicalRightCommandUpObserved,
              !didAuthorizeFinalLock else { return .none }
        didAuthorizeFinalLock = true
        return .scheduleFinalTextLock
    }
}

/// Focus an NSTextView, select Doubao's input source, and toggle voice input
/// with a synthetic right Command click after the physical hotkey is released.
@MainActor
final class InputMethodSessionManager {
    /// Poll interval / budget for waiting until UU (or the previous app) is
    /// actually frontmost before publishing the clipboard.
    private static let frontmostPollInterval: TimeInterval = 0.05
    private static let frontmostWaitBudget: TimeInterval = 0.40
    /// This is not a completion delay. Marked text is still the only normal
    /// completion signal; the deadline merely prevents a broken IME session
    /// from leaving the UI in `stopping` forever.
    private static let markedTextCommitSafetyTimeout: TimeInterval = 1.5
    private static let stoppingFocusPollInterval: TimeInterval = 0.10
    private static let rightCommandPressDuration: TimeInterval = 0.03

    private let appState: AppState
    private let overlayPanel: OverlayPanel
    private let hotkeyManager: HotkeyManager
    private let pasteOrderEventLogger: PasteOrderEventLogger
    private let directPasteOrderCoordinator: DirectPasteOrderCoordinator
    private let inputSourceManager = InputSourceManager()
    private var phase: InputMethodSessionPhase = .idle
    private var rightCommandIsDown = false
    private var rightCommandReleaseWorkItem: DispatchWorkItem?
    private var rightCommandTapKind: RightCommandTapKind?
    private var recordingReadinessGate = RecordingReadinessGate()
    private var markedTextCommitGate = MarkedTextCommitGate()
    private var physicalRightCommandStopGate = PhysicalRightCommandStopGate()
    private var sessionGeneration = UUID()
    private var finalTextLockIsScheduled = false
    private var stoppingFocusMonitorWorkItem: DispatchWorkItem?
    private var markedTextCommitTimeoutWorkItem: DispatchWorkItem?
    private var clipboardPublishWorkItem: DispatchWorkItem?
    private var currentDirectPasteIdentity: PasteOrderIdentity?
    private var currentPasteRoute: PasteRoute?
    private var pasteGeneration = UUID()
    private var previousFrontmostApp: NSRunningApplication?
    private var pasteTargetApp: NSRunningApplication?

    init(appState: AppState, overlayPanel: OverlayPanel, hotkeyManager: HotkeyManager) {
        self.appState = appState
        self.overlayPanel = overlayPanel
        self.hotkeyManager = hotkeyManager
        let eventLogger = PasteOrderEventLogger(
            side: "controller",
            databaseURL: PasteOrderEventLogger.defaultDatabaseURL(side: "controller")
        )
        pasteOrderEventLogger = eventLogger
        directPasteOrderCoordinator = DirectPasteOrderCoordinator(
            logger: eventLogger,
            onUnconfirmedCountChanged: { [weak appState] count in
                appState?.unconfirmedDirectPasteCount = count
            }
        )
    }

    func start() {
        hotkeyManager.onHotkeyEvent = { [weak self] event in
            Task { @MainActor in
                guard let self else { return }
                switch event {
                case .toggleRecording:
                    self.handleToggle()
                case .toggleHotkeyFullyReleased:
                    self.handleToggleHotkeyFullyReleased()
                case .physicalRightCommandStopDown:
                    self.handlePhysicalRightCommandStopDown()
                case .physicalRightCommandStopUp:
                    self.handlePhysicalRightCommandStopUp()
                case .physicalRightCommandStopInterruptedByOrdinaryKey:
                    self.handlePhysicalRightCommandStopInterruptedByOrdinaryKey()
                case .cancel:
                    self.cancelSession()
                }
            }
        }
        overlayPanel.onCancel = { [weak self] in
            Task { @MainActor in
                self?.cancelSession()
            }
        }
        overlayPanel.onMarkedTextStateChanged = { [weak self] hasMarkedText in
            self?.handleMarkedTextStateChanged(hasMarkedText)
        }
        hotkeyManager.setEscapeHandlingEnabled(false)
        hotkeyManager.start()
        print("[InputMethodSessionManager] ✅ IME bridge started")
    }

    func stop() {
        cancelSession()
        directPasteOrderCoordinator.cancelAllForShutdown()
        hotkeyManager.stop()
    }

    private func handleToggle() {
        switch SessionTogglePolicy.action(for: phase) {
        case .start:
            startSession()
        case .ignoreWhileRecording:
            logSessionEvent("toggle_ignored_while_recording")
            return
        case .cancel:
            cancelSession()
            print("[InputMethodSessionManager] Toggle cancelled the in-progress session")
        }
    }

    private func handleToggleHotkeyFullyReleased() {
        switch phase {
        case .preparing:
            applyReadinessAction(recordingReadinessGate.markHotkeyReleased())
        case .idle, .recording, .stopping:
            return
        }
    }

    private func startSession() {
        guard inputSourceManager.saveCurrentInputSource() else {
            showInputSourceError("无法保存当前输入法")
            return
        }

        invalidatePendingPaste()
        sessionGeneration = UUID()
        let generation = sessionGeneration
        recordingReadinessGate = RecordingReadinessGate()
        markedTextCommitGate = MarkedTextCommitGate()
        physicalRightCommandStopGate = PhysicalRightCommandStopGate()
        finalTextLockIsScheduled = false
        previousFrontmostApp = NSWorkspace.shared.frontmostApplication
        // Capture the destination at recording start. Do not infer it from a
        // window title or from whichever process is frontmost after dictation.
        pasteTargetApp = previousFrontmostApp
        NSApp.activate(ignoringOtherApps: true)
        let route = PasteRouter().route(for: pasteTargetApp)
        currentPasteRoute = route
        if route == .uuDirect {
            currentDirectPasteIdentity = directPasteOrderCoordinator.beginRecording()
        } else {
            currentDirectPasteIdentity = nil
        }

        phase = .preparing
        logSessionEvent("session_started", route: route, target: pasteTargetApp)
        appState.transcriptionText = ""
        overlayPanel.clearText()
        appState.errorMessage = nil
        appState.recordingState = .starting
        hotkeyManager.setEscapeHandlingEnabled(true)
        // Both readiness paths start immediately on the main actor. AppKit and
        // Text Input Services stay on their required thread; neither path waits
        // for a fixed delay or assumes the other has completed first.
        overlayPanel.showOverlay { [weak self] focusIsReady in
            guard let self,
                  self.phase == .preparing,
                  self.sessionGeneration == generation else { return }
            guard focusIsReady else {
                self.cancelPreparingSession(
                    message: "无法聚焦临时输入框",
                    reason: .focusReadinessFailed
                )
                return
            }
            self.recordDirectLifecycleEvent(.focusReady)
            self.logSessionEvent("focus_ready", focusStatus: self.overlayPanel.textInputFocusStatus)
            self.applyReadinessAction(self.recordingReadinessGate.markFocusReady())
        }

        guard inputSourceManager.selectAndConfirmDoubaoInputSource() else {
            cancelPreparingSession(
                message: "未找到、未启用或无法确认豆包输入法",
                reason: .inputSourceSelectionFailed
            )
            return
        }
        guard phase == .preparing, sessionGeneration == generation else { return }
        recordDirectLifecycleEvent(.inputSourceReady)
        logSessionEvent("input_source_ready")
        applyReadinessAction(recordingReadinessGate.markInputSourceReady())
    }

    private func applyReadinessAction(_ action: RecordingReadinessGate.Action) {
        guard action == .postRightCommandStart, phase == .preparing else { return }
        postRightCommandTap(kind: .start) { [weak self] posted in
            guard let self, self.phase == .preparing else { return }
            guard posted else {
                self.cancelPreparingSession(
                    message: "无法发出右 Command 启动事件",
                    reason: .functionKeyPostFailed
                )
                return
            }
            self.recordDirectLifecycleEvent(.functionKeyDownPosted)
            self.phase = .recording
            self.appState.recordingState = .recording
            self.logSessionEvent("right_command_start_completed", focusStatus: self.overlayPanel.textInputFocusStatus)
            print("[InputMethodSessionManager] ✅ Text client and Doubao input source ready; right Command tapped")
        }
    }

    private func handlePhysicalRightCommandStopDown() {
        guard phase == .recording else { return }

        guard physicalRightCommandStopGate.observePhysicalRightCommandDown() == .startedStopping else { return }
        logSessionEvent("physical_right_command_stop_down", focusStatus: overlayPanel.textInputFocusStatus)
        let focusStatus = overlayPanel.ensureTextInputFocus()
        logSessionEvent("pre_physical_right_command_stop_focus_checked", focusStatus: focusStatus)
        guard focusStatus.isConfirmed else {
            cancelSession(
                message: "临时输入框在物理右 Command 停止前失去焦点（\(focusStatus)）",
                reason: .stoppingFocusLost
            )
            return
        }

        phase = .stopping
        appState.recordingState = .stopping
        beginStoppingSafetyMonitoring()
        handleMarkedTextAction(
            markedTextCommitGate.beginStopping(
                currentlyHasMarkedText: overlayPanel.hasMarkedText
            )
        )
    }

    private func handlePhysicalRightCommandStopUp() {
        guard phase == .stopping else { return }
        logSessionEvent("physical_right_command_stop_up", focusStatus: overlayPanel.textInputFocusStatus)
        applyPhysicalRightCommandStopAction(
            physicalRightCommandStopGate.observePhysicalRightCommandUp()
        )
    }

    private func handlePhysicalRightCommandStopInterruptedByOrdinaryKey() {
        guard phase == .stopping else { return }
        applyPhysicalRightCommandStopAction(
            physicalRightCommandStopGate.observeOrdinaryKeyDown()
        )
    }

    private func handleMarkedTextStateChanged(_ hasMarkedText: Bool) {
        guard phase == .preparing || phase == .recording || phase == .stopping else { return }
        logSessionEvent(
            hasMarkedText ? "marked_text_state_true" : "marked_text_state_false",
            focusStatus: overlayPanel.textInputFocusStatus
        )
        handleMarkedTextAction(markedTextCommitGate.observe(hasMarkedText: hasMarkedText))
    }

    private func handleMarkedTextAction(_ action: MarkedTextCommitGate.Action) {
        switch action {
        case .none:
            return
        case .markedTextStarted:
            recordDirectLifecycleEvent(.markedTextStarted)
            logSessionEvent("marked_text_started", focusStatus: overlayPanel.textInputFocusStatus)
        case .markedTextCommitted:
            recordDirectLifecycleEvent(.markedTextCommitted)
            logSessionEvent("marked_text_committed", focusStatus: overlayPanel.textInputFocusStatus)
            applyPhysicalRightCommandStopAction(
                physicalRightCommandStopGate.markMarkedTextCommitted()
            )
        case .focusLost:
            cancelSession(
                message: "临时输入框在等待豆包提交时失去焦点；已安全取消，未粘贴文字",
                reason: .stoppingFocusLost
            )
        case .timedOut:
            cancelSession(
                message: "等待豆包提交超时；已安全取消，未粘贴可能未完成的文字",
                reason: .markedTextCommitTimedOut
            )
        }
    }

    private func applyPhysicalRightCommandStopAction(_ action: PhysicalRightCommandStopGate.Action) {
        switch action {
        case .none:
            return
        case .startedStopping:
            return
        case .scheduleFinalTextLock:
            scheduleFinalTextLockOnNextMainLoop()
        case .nonBareCommand:
            cancelSession(
                message: "物理右 Command 期间检测到普通按键；已安全取消，未复制或粘贴文字",
                reason: .sessionCancelled
            )
        case .timedOut:
            cancelSession(
                message: "等待豆包提交或物理右 Command 抬起超时；已安全取消，未复制或粘贴未确认文字",
                reason: .markedTextCommitTimedOut
            )
        }
    }

    private func beginStoppingSafetyMonitoring() {
        cancelStoppingSafetyMonitoring()
        let generation = sessionGeneration

        // Verify once on the very next main-loop turn after the stop toggle,
        // then keep
        // observing while waiting. The poll only detects focus loss; it never
        // decides that a transcription is complete.
        scheduleStoppingFocusVerification(generation: generation, immediately: true)

        let timeoutWorkItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.phase == .stopping,
                  self.sessionGeneration == generation else { return }
            self.logSessionEvent(
                "physical_right_command_stop_timeout",
                focusStatus: self.overlayPanel.textInputFocusStatus
            )
            self.applyPhysicalRightCommandStopAction(self.physicalRightCommandStopGate.expireWaiting())
        }
        markedTextCommitTimeoutWorkItem = timeoutWorkItem
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.markedTextCommitSafetyTimeout,
            execute: timeoutWorkItem
        )
    }

    private func scheduleStoppingFocusVerification(generation: UUID, immediately: Bool) {
        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.phase == .stopping,
                  self.sessionGeneration == generation else { return }
            let focusStatus = self.overlayPanel.textInputFocusStatus
            self.logSessionEvent("stopping_focus_checked", focusStatus: focusStatus)
            self.handleMarkedTextAction(
                self.markedTextCommitGate.observeFocus(
                    isConfirmed: focusStatus.isConfirmed
                )
            )
            guard self.phase == .stopping,
                  self.sessionGeneration == generation else { return }
            self.scheduleStoppingFocusVerification(generation: generation, immediately: false)
        }
        stoppingFocusMonitorWorkItem = workItem
        if immediately {
            DispatchQueue.main.async(execute: workItem)
        } else {
            DispatchQueue.main.asyncAfter(
                deadline: .now() + Self.stoppingFocusPollInterval,
                execute: workItem
            )
        }
    }

    private func cancelStoppingSafetyMonitoring() {
        stoppingFocusMonitorWorkItem?.cancel()
        stoppingFocusMonitorWorkItem = nil
        markedTextCommitTimeoutWorkItem?.cancel()
        markedTextCommitTimeoutWorkItem = nil
    }

    private func scheduleFinalTextLockOnNextMainLoop() {
        guard !finalTextLockIsScheduled else { return }
        finalTextLockIsScheduled = true
        let generation = sessionGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.phase == .stopping,
                  self.sessionGeneration == generation else { return }
            guard self.overlayPanel.textInputFocusStatus.isConfirmed else {
                self.logSessionEvent(
                    "final_text_lock_blocked_by_focus",
                    focusStatus: self.overlayPanel.textInputFocusStatus
                )
                self.handleMarkedTextAction(
                    self.markedTextCommitGate.observeFocus(isConfirmed: false)
                )
                return
            }
            let frozenText = self.overlayPanel.currentText()
            self.recordDirectLifecycleEvent(.finalTextLocked, textLength: frozenText.count)
            self.logSessionEvent(
                "final_text_locked",
                textLength: frozenText.count,
                focusStatus: self.overlayPanel.textInputFocusStatus
            )
            self.completeSession(withFrozenText: frozenText)
        }
    }

    private func completeSession(withFrozenText frozenText: String) {
        guard phase == .stopping else { return }
        guard !rightCommandIsDown else {
            cancelSession(
                message: "右 Command 尚未释放；已安全取消，未复制或粘贴文字",
                reason: .functionKeyPostFailed
            )
            return
        }
        let text = frozenText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            if let identity = currentDirectPasteIdentity {
                directPasteOrderCoordinator.abandonRecording(
                    identity: identity,
                    reason: .emptyTranscription
                )
            }
            closeSession(releasingRightCommand: false)
            print("[InputMethodSessionManager] ⚠️ Session completed with no text to copy")
            return
        }

        let target = pasteTargetApp
        // Freeze routing at recording start. A menu change applies to the next
        // recording and cannot create a late order without recording metadata.
        let route = currentPasteRoute ?? PasteRouter().route(for: target)
        let completedSessionID = sessionGeneration
        let generation = pasteGeneration
        let directIdentity = currentDirectPasteIdentity
        if route == .uuDirect, let directIdentity {
            directPasteOrderCoordinator.transcriptionReady(identity: directIdentity, textLength: text.count)
        } else if let directIdentity {
            directPasteOrderCoordinator.abandonRecording(
                identity: directIdentity,
                reason: .routeUnavailableBeforeSubmit
            )
        }
        logPasteRoute(route, target: target, event: "session completion")
        logSessionEvent(
            "session_completion_authorized",
            sessionID: completedSessionID,
            route: route,
            target: target,
            textLength: text.count
        )
        if PasteRouter.shouldPrepublishLocalClipboard(for: route) {
            // Compatibility mode starts UU's normal clipboard sync before the
            // controller restores focus. Direct mode stays out of this channel.
            let copied = PasteHelper.copyOnly(text)
            logSessionEvent(
                copied ? "compatibility_clipboard_prepublish_succeeded" : "compatibility_clipboard_prepublish_failed",
                sessionID: completedSessionID,
                route: route,
                target: target,
                textLength: text.count
            )
        }
        closeSession(releasingRightCommand: false)
        schedulePaste(
            text,
            route: route,
            target: target,
            generation: generation,
            directIdentity: directIdentity,
            traceSessionID: completedSessionID
        )
        print("[InputMethodSessionManager] ✅ Session completed (text length: \(text.count))")
    }

    private func schedulePaste(
        _ text: String,
        route: PasteRoute,
        target: NSRunningApplication?,
        generation: UUID,
        directIdentity: PasteOrderIdentity?,
        traceSessionID: UUID
    ) {
        clipboardPublishWorkItem?.cancel()
        PasteHelper.cancelPendingPaste()
        PasteRouter.execute(
            route,
            local: { [weak self] in
                self?.waitUntilPasteTargetIsFrontmost(target: target, generation: generation) { isFrontmost in
                    guard isFrontmost else {
                        print("[InputMethodSessionManager] ⚠️ Local target was not restored; not pasting")
                        return
                    }
                    PasteHelper.copyAndPasteLocally(text)
                }
            },
            uuCompatibility: { [weak self] in
                self?.logSessionEvent(
                    "compatibility_route_started",
                    sessionID: traceSessionID,
                    route: route,
                    target: target,
                    textLength: text.count
                )
                self?.waitUntilPasteTargetIsFrontmost(target: target, generation: generation) { isFrontmost in
                    guard let self else { return }
                    self.logSessionEvent(
                        isFrontmost ? "compatibility_target_frontmost" : "compatibility_target_not_frontmost",
                        sessionID: traceSessionID,
                        route: route,
                        target: target,
                        textLength: text.count
                    )
                    guard PasteHelper.ClipboardDefensePolicy.initialTargetDecision(
                        targetIsFrontmost: isFrontmost
                    ) == .continueDefending else {
                        print("[InputMethodSessionManager] ⚠️ UU target did not become frontmost; not pasting")
                        self.handleCompatibilityPasteFailure(
                            PasteHelper.CompatibilityPasteFailureResult(
                                failure: .targetNotFrontmost,
                                clipboardRetained: PasteHelper.copyOnly(text)
                            )
                        )
                        return
                    }
                    PasteHelper.copyAndPasteForUUCompatibility(
                        text,
                        isPasteTargetFrontmost: { [weak self] in
                            guard let self, self.pasteGeneration == generation else { return false }
                            return self.isPasteTargetFrontmost(target)
                        },
                        onFailure: { [weak self] result in
                            self?.handleCompatibilityPasteFailure(result)
                        }
                    )
                }
            },
            uuDirect: { [weak self] in
                guard let self, let identity = directIdentity else { return }
                self.directPasteOrderCoordinator.submit(
                    identity: identity,
                    text: text,
                    targetProcessIdentifier: target?.processIdentifier,
                    targetBundleIdentifier: target?.bundleIdentifier
                )
            }
        )
    }

    private func waitUntilPasteTargetIsFrontmost(
        target: NSRunningApplication?,
        attemptsRemaining: Int? = nil,
        generation: UUID,
        then work: @escaping (Bool) -> Void
    ) {
        guard generation == pasteGeneration else { return }
        let remainingAttempts = attemptsRemaining ?? Int(Self.frontmostWaitBudget / Self.frontmostPollInterval)
        let isReady = isPasteTargetFrontmost(target)
        if isReady || remainingAttempts <= 0 {
            work(isReady)
            return
        }
        let workItem = DispatchWorkItem { [weak self] in
            self?.waitUntilPasteTargetIsFrontmost(
                target: target,
                attemptsRemaining: remainingAttempts - 1,
                generation: generation,
                then: work
            )
        }
        clipboardPublishWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.frontmostPollInterval, execute: workItem)
    }

    private func cancelSession(
        message: String = "Session cancelled and previous input source restored",
        reason: DirectPasteCancellationReason = .sessionCancelled
    ) {
        invalidatePendingPaste()
        guard phase != .idle else { return }
        logSessionEvent(
            "session_cancelled",
            reason: reason.rawValue,
            focusStatus: overlayPanel.textInputFocusStatus
        )
        if let identity = currentDirectPasteIdentity {
            directPasteOrderCoordinator.abandonRecording(
                identity: identity,
                reason: reason
            )
        }
        closeSession()
        print("[InputMethodSessionManager] \(message)")
    }

    private func closeSession(releasingRightCommand: Bool = true) {
        logSessionEvent("session_closing", focusStatus: overlayPanel.textInputFocusStatus)
        hotkeyManager.cancelStopHotkeyReleaseTracking()
        recordingReadinessGate.cancel()
        markedTextCommitGate.cancel()
        physicalRightCommandStopGate.cancel()
        cancelStoppingSafetyMonitoring()
        sessionGeneration = UUID()
        finalTextLockIsScheduled = false
        overlayPanel.cancelTextInputFocusRequest()
        if releasingRightCommand {
            releaseRightCommandIfNeeded()
        }
        phase = .idle
        hotkeyManager.setEscapeHandlingEnabled(false)
        overlayPanel.hideOverlay()
        inputSourceManager.restorePreviousInputSource()
        overlayPanel.clearText()
        activatePreviousFrontmostApp()
        appState.reset()
        currentDirectPasteIdentity = nil
        currentPasteRoute = nil
    }

    private func activatePreviousFrontmostApp() {
        let app = previousFrontmostApp
        previousFrontmostApp = nil
        guard let app, !app.isTerminated else { return }
        if #available(macOS 14.0, *) {
            _ = app.activate()
        } else {
            app.activate(options: [.activateIgnoringOtherApps])
        }
    }

    private func invalidatePendingPaste() {
        pasteGeneration = UUID()
        clipboardPublishWorkItem?.cancel()
        clipboardPublishWorkItem = nil
        PasteHelper.cancelPendingPaste()
    }

    private func isPasteTargetFrontmost(_ target: NSRunningApplication?) -> Bool {
        guard let target else { return true }
        guard !target.isTerminated else { return false }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier
    }

    private func handleCompatibilityPasteFailure(_ result: PasteHelper.CompatibilityPasteFailureResult) {
        let alert = NSAlert()
        switch result.failure {
        case .deadlineExpired:
            alert.messageText = "兼容模式剪贴板未稳定"
            alert.informativeText = result.clipboardRetained
                ? "文字已重新复制到本机剪贴板，本次未自动粘贴。请手动粘贴，或调大剪贴板稳定时间。"
                : "本次未自动粘贴，且无法确认文字已重新复制到本机剪贴板。请检查剪贴板后手动粘贴。"
        case .targetNotFrontmost:
            alert.messageText = "兼容模式目标应用已切换"
            alert.informativeText = result.clipboardRetained
                ? "原目标应用未保持在前台，文字已重新复制到本机剪贴板，本次未自动粘贴。请回到目标输入框后手动粘贴。"
                : "原目标应用未保持在前台，本次未自动粘贴，且无法确认文字已重新复制到本机剪贴板。请检查剪贴板后手动粘贴。"
        }
        alert.alertStyle = .warning
        alert.addButton(withTitle: "好的")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func logPasteRoute(_ route: PasteRoute, target: NSRunningApplication?, event: String) {
        let bundleIdentifier = target?.bundleIdentifier ?? "<none>"
        let processIdentifier = target.map(\.processIdentifier) ?? -1
        print("[InputMethodSessionManager] route=\(route) targetBundle=\(bundleIdentifier) targetPID=\(processIdentifier) event=\(event)")
    }

    private func logSessionEvent(
        _ event: String,
        sessionID: UUID? = nil,
        reason: String = "none",
        route: PasteRoute? = nil,
        target: NSRunningApplication? = nil,
        textLength: Int = -1,
        focusStatus: TextInputFocusStatus? = nil
    ) {
        let resolvedSessionID = (sessionID ?? sessionGeneration).uuidString
        let phaseName = String(describing: phase)
        let routeName = route.map { String(describing: $0) }
            ?? currentPasteRoute.map { String(describing: $0) }
            ?? "none"
        let resolvedFocus = String(describing: focusStatus ?? overlayPanel.textInputFocusStatus)
        let targetApp = target ?? pasteTargetApp
        let targetPID = targetApp?.processIdentifier ?? -1
        let targetBundleIdentifier = targetApp?.bundleIdentifier ?? "none"
        let frontmostApp = NSWorkspace.shared.frontmostApplication
        let frontmostPID = frontmostApp?.processIdentifier ?? -1
        let frontmostBundleIdentifier = frontmostApp?.bundleIdentifier ?? "none"
        let hasMarkedText = overlayPanel.hasMarkedText
        sessionLogger.notice(
            "event=\(event, privacy: .public) session=\(resolvedSessionID, privacy: .public) phase=\(phaseName, privacy: .public) route=\(routeName, privacy: .public) focus=\(resolvedFocus, privacy: .public) marked=\(hasMarkedText, privacy: .public) rightCommandDown=\(self.rightCommandIsDown, privacy: .public) appActive=\(NSApp.isActive, privacy: .public) frontmostPID=\(frontmostPID, privacy: .public) frontmostBundle=\(frontmostBundleIdentifier, privacy: .public) textLength=\(textLength, privacy: .public) targetPID=\(targetPID, privacy: .public) targetBundle=\(targetBundleIdentifier, privacy: .public) reason=\(reason, privacy: .public)"
        )
    }

    private func postRightCommandTap(kind: RightCommandTapKind, completion: @escaping (Bool) -> Void) {
        guard !rightCommandIsDown,
              RightCommandInjector.post(isPressed: true)
        else {
            completion(false)
            return
        }
        rightCommandIsDown = true
        rightCommandTapKind = kind
        logSessionEvent("\(kind.diagnosticPrefix)_down")
        let generation = sessionGeneration
        let releaseWorkItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.sessionGeneration == generation,
                  self.rightCommandIsDown else { return }
            guard RightCommandInjector.post(isPressed: false) else {
                self.logSessionEvent("\(kind.diagnosticPrefix)_up_failed")
                completion(false)
                return
            }
            self.rightCommandIsDown = false
            self.rightCommandTapKind = nil
            self.logSessionEvent("\(kind.diagnosticPrefix)_up")
            completion(true)
        }
        rightCommandReleaseWorkItem = releaseWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.rightCommandPressDuration, execute: releaseWorkItem)
    }

    private func releaseRightCommandIfNeeded() {
        rightCommandReleaseWorkItem?.cancel()
        rightCommandReleaseWorkItem = nil
        guard rightCommandIsDown else { return }
        let kind = rightCommandTapKind
        guard RightCommandInjector.post(isPressed: false) else {
            logSessionEvent("right_command_release_retry_failed")
            print("[InputMethodSessionManager] ⚠️ Failed to release synthetic right Command; retaining down state")
            return
        }
        rightCommandIsDown = false
        rightCommandTapKind = nil
        if let kind {
            logSessionEvent("\(kind.diagnosticPrefix)_up")
        }
    }

    private func recordDirectLifecycleEvent(
        _ event: DirectPasteLifecycleEvent,
        textLength: Int? = nil
    ) {
        guard let identity = currentDirectPasteIdentity else { return }
        directPasteOrderCoordinator.recordLifecycleEvent(
            identity: identity,
            event: event,
            textLength: textLength
        )
    }

    private func cancelPreparingSession(
        message: String,
        reason: DirectPasteCancellationReason
    ) {
        guard phase == .preparing else { return }
        if let identity = currentDirectPasteIdentity {
            directPasteOrderCoordinator.abandonRecording(identity: identity, reason: reason)
        }
        closeSession()
        print("[InputMethodSessionManager] ❌ \(message)")
    }

    private func showInputSourceError(_ message: String) {
        if let identity = currentDirectPasteIdentity {
            directPasteOrderCoordinator.abandonRecording(
                identity: identity,
                reason: .inputSourceSelectionFailed
            )
        }
        if phase != .idle {
            closeSession()
        }
        print("[InputMethodSessionManager] ❌ \(message)")
    }
}

/// Posts the public virtual-key equivalent of the physical right Command key.
private enum RightCommandInjector {
    @discardableResult
    static func post(isPressed: Bool) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let event = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: 54, // kVK_RightCommand
                  keyDown: isPressed
              )
        else {
            return false
        }

        event.flags = isPressed ? [.maskCommand, .maskNonCoalesced] : .maskNonCoalesced
        event.type = .flagsChanged
        functionKeyDiagnosticsLogger.notice(
            "origin=injector isPressed=\(isPressed, privacy: .public) eventType=\(event.type.rawValue, privacy: .public) flags=\(event.flags.rawValue, privacy: .public) keyCode=\(event.getIntegerValueField(.keyboardEventKeycode), privacy: .public) sourcePID=\(event.getIntegerValueField(.eventSourceUnixProcessID), privacy: .public) sourceState=\(event.getIntegerValueField(.eventSourceStateID), privacy: .public) keyboardType=\(event.getIntegerValueField(.keyboardEventKeyboardType), privacy: .public)"
        )
        event.post(tap: .cghidEventTap)
        return true
    }
}
