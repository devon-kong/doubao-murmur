import AppKit
import CoreGraphics
import Foundation

struct RecordingReadinessGate {
    enum Action: Equatable {
        case none
        case postFunctionKeyDown
    }

    private var focusIsReady = false
    private var inputSourceIsReady = false
    private var didAuthorizeFunctionKeyDown = false
    private var isCancelled = false

    mutating func markFocusReady() -> Action {
        focusIsReady = true
        return authorizationAction()
    }

    mutating func markInputSourceReady() -> Action {
        inputSourceIsReady = true
        return authorizationAction()
    }

    mutating func cancel() {
        isCancelled = true
    }

    private mutating func authorizationAction() -> Action {
        guard !isCancelled,
              focusIsReady,
              inputSourceIsReady,
              !didAuthorizeFunctionKeyDown else { return .none }
        didAuthorizeFunctionKeyDown = true
        return .postFunctionKeyDown
    }
}

struct MarkedTextCommitGate {
    enum Action: Equatable {
        case none
        case markedTextStarted
        case markedTextCommitted
    }

    static let automaticCompletionTimeout: TimeInterval? = nil

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

    mutating func cancel() {
        isCancelled = true
    }
}

/// Focus an NSTextView, select Doubao's input source, and hold
/// the Fn key synthetically while a voice-input session is active.
@MainActor
final class InputMethodSessionManager {
    private enum SessionPhase: Equatable {
        case idle
        case preparing
        case recording
        case stopping
    }

    /// Poll interval / budget for waiting until UU (or the previous app) is
    /// actually frontmost before publishing the clipboard.
    private static let frontmostPollInterval: TimeInterval = 0.05
    private static let frontmostWaitBudget: TimeInterval = 0.40

    private let appState: AppState
    private let overlayPanel: OverlayPanel
    private let hotkeyManager: HotkeyManager
    private let pasteOrderEventLogger: PasteOrderEventLogger
    private let directPasteOrderCoordinator: DirectPasteOrderCoordinator
    private let inputSourceManager = InputSourceManager()
    private var phase: SessionPhase = .idle
    private var functionKeyIsDown = false
    private var recordingReadinessGate = RecordingReadinessGate()
    private var markedTextCommitGate = MarkedTextCommitGate()
    private var sessionGeneration = UUID()
    private var finalTextLockIsScheduled = false
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
        switch phase {
        case .idle:
            startSession()
        case .preparing, .recording:
            stopSession()
        case .stopping:
            print("[InputMethodSessionManager] Stop is already in progress; ignoring toggle")
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
        finalTextLockIsScheduled = false
        previousFrontmostApp = NSWorkspace.shared.frontmostApplication
        // Capture the destination at recording start. Do not infer it from a
        // window title or from whichever process is frontmost after dictation.
        pasteTargetApp = previousFrontmostApp
        let route = PasteRouter().route(for: pasteTargetApp)
        currentPasteRoute = route
        if route == .uuDirect {
            currentDirectPasteIdentity = directPasteOrderCoordinator.beginRecording()
        } else {
            currentDirectPasteIdentity = nil
        }

        phase = .preparing
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
        applyReadinessAction(recordingReadinessGate.markInputSourceReady())
    }

    private func applyReadinessAction(_ action: RecordingReadinessGate.Action) {
        guard action == .postFunctionKeyDown, phase == .preparing else { return }
        guard setFunctionKeyPressed(true) else {
            cancelPreparingSession(
                message: "无法发出语音输入启动事件",
                reason: .functionKeyPostFailed
            )
            return
        }
        recordDirectLifecycleEvent(.functionKeyDownPosted)
        phase = .recording
        appState.recordingState = .recording
        print("[InputMethodSessionManager] ✅ Text client and Doubao input source ready; Fn pressed")
    }

    private func stopSession() {
        if phase == .preparing {
            // No Fn event has been sent yet, so a fast second toggle is simply a cancel.
            cancelSession()
            return
        }

        guard phase == .recording else { return }
        phase = .stopping
        appState.recordingState = .stopping
        if setFunctionKeyPressed(false) {
            recordDirectLifecycleEvent(.functionKeyUpPosted)
        } else {
            print("[InputMethodSessionManager] ⚠️ Failed to post Fn-up")
        }
        overlayPanel.maintainTextInputFocus()
        handleMarkedTextAction(
            markedTextCommitGate.beginStopping(
                currentlyHasMarkedText: overlayPanel.hasMarkedText
            )
        )
        print("[InputMethodSessionManager] ⏹ Fn released; waiting for marked text commit")
    }

    private func handleMarkedTextStateChanged(_ hasMarkedText: Bool) {
        guard phase == .preparing || phase == .recording || phase == .stopping else { return }
        handleMarkedTextAction(markedTextCommitGate.observe(hasMarkedText: hasMarkedText))
    }

    private func handleMarkedTextAction(_ action: MarkedTextCommitGate.Action) {
        switch action {
        case .none:
            return
        case .markedTextStarted:
            recordDirectLifecycleEvent(.markedTextStarted)
        case .markedTextCommitted:
            recordDirectLifecycleEvent(.markedTextCommitted)
            scheduleFinalTextLockOnNextMainLoop()
        }
    }

    private func scheduleFinalTextLockOnNextMainLoop() {
        guard !finalTextLockIsScheduled else { return }
        finalTextLockIsScheduled = true
        let generation = sessionGeneration
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.phase == .stopping,
                  self.sessionGeneration == generation else { return }
            let frozenText = self.overlayPanel.currentText()
            self.recordDirectLifecycleEvent(.finalTextLocked, textLength: frozenText.count)
            self.completeSession(withFrozenText: frozenText)
        }
    }

    private func completeSession(withFrozenText frozenText: String) {
        guard phase == .stopping else { return }
        let text = frozenText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            if let identity = currentDirectPasteIdentity {
                directPasteOrderCoordinator.abandonRecording(
                    identity: identity,
                    reason: .emptyTranscription
                )
            }
            closeSession()
            print("[InputMethodSessionManager] ⚠️ Session completed with no text to copy")
            return
        }

        let target = pasteTargetApp
        // Freeze routing at recording start. A menu change applies to the next
        // recording and cannot create a late order without recording metadata.
        let route = currentPasteRoute ?? PasteRouter().route(for: target)
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
        if PasteRouter.shouldPrepublishLocalClipboard(for: route) {
            // Compatibility mode starts UU's normal clipboard sync before the
            // controller restores focus. Direct mode stays out of this channel.
            PasteHelper.copyOnly(text)
        }
        closeSession()
        schedulePaste(
            text,
            route: route,
            target: target,
            generation: generation,
            directIdentity: directIdentity
        )
        print("[InputMethodSessionManager] ✅ Session completed (text length: \(text.count))")
    }

    private func schedulePaste(
        _ text: String,
        route: PasteRoute,
        target: NSRunningApplication?,
        generation: UUID,
        directIdentity: PasteOrderIdentity?
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
                self?.waitUntilPasteTargetIsFrontmost(target: target, generation: generation) { isFrontmost in
                    guard let self else { return }
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

    private func cancelSession() {
        invalidatePendingPaste()
        guard phase != .idle else { return }
        if let identity = currentDirectPasteIdentity {
            directPasteOrderCoordinator.abandonRecording(
                identity: identity,
                reason: .sessionCancelled
            )
        }
        closeSession()
        print("[InputMethodSessionManager] Session cancelled and previous input source restored")
    }

    private func closeSession() {
        recordingReadinessGate.cancel()
        markedTextCommitGate.cancel()
        sessionGeneration = UUID()
        finalTextLockIsScheduled = false
        overlayPanel.cancelTextInputFocusRequest()
        _ = setFunctionKeyPressed(false)
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

    @discardableResult
    private func setFunctionKeyPressed(_ isPressed: Bool) -> Bool {
        guard functionKeyIsDown != isPressed else { return true }
        guard FunctionKeyInjector.post(isPressed) else {
            print("[InputMethodSessionManager] ⚠️ Failed to post synthetic Fn event")
            return false
        }
        functionKeyIsDown = isPressed
        return true
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

/// Posts the public virtual-key equivalent of the physical Fn key.  This is a
/// local event only; no private input-method APIs or third-party code are used.
private enum FunctionKeyInjector {
    @discardableResult
    static func post(_ isPressed: Bool) -> Bool {
        guard let source = CGEventSource(stateID: .hidSystemState),
              let event = CGEvent(
                  keyboardEventSource: source,
                  virtualKey: 63, // kVK_Function
                  keyDown: isPressed
              )
        else {
            return false
        }

        event.flags = isPressed ? .maskSecondaryFn : []
        event.post(tap: .cghidEventTap)
        return true
    }
}
