import AppKit
import Combine
import CoreGraphics
import Foundation

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

    private static let inputSourceSettleDelay: TimeInterval = 0.15
    private static let functionKeyStartDelay: TimeInterval = 0.10
    private static let finalTextQuietPeriod: TimeInterval = 0.35
    private static let stopSafetyTimeout: TimeInterval = 1.5
    /// Poll interval / budget for waiting until UU (or the previous app) is
    /// actually frontmost before publishing the clipboard.
    private static let frontmostPollInterval: TimeInterval = 0.05
    private static let frontmostWaitBudget: TimeInterval = 0.40

    private let appState: AppState
    private let overlayPanel: OverlayPanel
    private let hotkeyManager: HotkeyManager
    private let directPasteFailureHandler: DirectPasteFailureHandler
    private let directPasteFailurePresenter: RemoteClipboardFailurePresenting
    private let inputSourceManager = InputSourceManager()
    private var phase: SessionPhase = .idle
    private var functionKeyIsDown = false
    private var preparationWorkItem: DispatchWorkItem?
    private var functionKeyWorkItem: DispatchWorkItem?
    private var finalTextQuietWorkItem: DispatchWorkItem?
    private var stopSafetyWorkItem: DispatchWorkItem?
    private var clipboardPublishWorkItem: DispatchWorkItem?
    private var directPasteTask: Task<Void, Never>?
    private var pasteGeneration = UUID()
    private var previousFrontmostApp: NSRunningApplication?
    private var pasteTargetApp: NSRunningApplication?
    private var transcriptionTextObservation: AnyCancellable?

    init(appState: AppState, overlayPanel: OverlayPanel, hotkeyManager: HotkeyManager) {
        self.appState = appState
        self.overlayPanel = overlayPanel
        self.hotkeyManager = hotkeyManager
        directPasteFailureHandler = DirectPasteFailureHandler()
        directPasteFailurePresenter = RemoteClipboardFailurePresenter()
    }

    func start() {
        transcriptionTextObservation = appState.$transcriptionText
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.handleTranscriptionTextChanged()
                }
            }

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
        hotkeyManager.setEscapeHandlingEnabled(false)
        hotkeyManager.start()
        print("[InputMethodSessionManager] ✅ IME bridge started")
    }

    func stop() {
        cancelSession()
        transcriptionTextObservation?.cancel()
        transcriptionTextObservation = nil
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
        previousFrontmostApp = NSWorkspace.shared.frontmostApplication
        // Capture the destination at recording start. Do not infer it from a
        // window title or from whichever process is frontmost after dictation.
        pasteTargetApp = previousFrontmostApp

        phase = .preparing
        appState.transcriptionText = ""
        overlayPanel.clearText()
        appState.errorMessage = nil
        appState.recordingState = .starting
        hotkeyManager.setEscapeHandlingEnabled(true)
        overlayPanel.showOverlay()

        // Ensure the text client exists and owns focus before selecting the IME.
        let workItem = DispatchWorkItem { [weak self] in
            self?.selectInputSourceAndStartVoice()
        }
        preparationWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.inputSourceSettleDelay, execute: workItem)
    }

    private func selectInputSourceAndStartVoice() {
        guard phase == .preparing else { return }
        guard inputSourceManager.selectDoubaoInputSource() else {
            showInputSourceError("未找到或未启用豆包输入法")
            return
        }

        phase = .recording
        appState.recordingState = .recording
        overlayPanel.focusTextInput()

        // Give the newly selected input source a moment to become the active text client,
        // then simulate holding Fn to invoke Doubao's native voice input.
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.phase == .recording else { return }
            self.setFunctionKeyPressed(true)
        }
        functionKeyWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.functionKeyStartDelay, execute: workItem)
        print("[InputMethodSessionManager] ✅ Focused local NSTextView and selected Doubao input source")
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
        preparationWorkItem?.cancel()
        preparationWorkItem = nil
        functionKeyWorkItem?.cancel()
        functionKeyWorkItem = nil
        setFunctionKeyPressed(false)

        scheduleStopSafetyTimeout()
        if !trimmedTranscriptionText.isEmpty {
            scheduleFinalCompletion()
        }
        print("[InputMethodSessionManager] ⏹ Fn released; waiting for Doubao input text to settle")
    }

    private func handleTranscriptionTextChanged() {
        guard phase == .stopping else { return }
        guard !trimmedTranscriptionText.isEmpty else {
            finalTextQuietWorkItem?.cancel()
            finalTextQuietWorkItem = nil
            return
        }
        scheduleFinalCompletion()
    }

    /// The input method can rewrite partial text after Fn is released.  Only paste
    /// after it has remained unchanged for a short quiet period.
    private func scheduleFinalCompletion() {
        finalTextQuietWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.phase == .stopping else { return }
            print("[InputMethodSessionManager] Text settled; completing session")
            self.completeSession()
        }
        finalTextQuietWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.finalTextQuietPeriod, execute: workItem)
    }

    private func scheduleStopSafetyTimeout() {
        stopSafetyWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.phase == .stopping else { return }
            print("[InputMethodSessionManager] ⏱ Stop safety timeout; completing with current text")
            self.completeSession()
        }
        stopSafetyWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.stopSafetyTimeout, execute: workItem)
    }

    private func completeSession() {
        guard phase == .stopping else { return }
        let text = trimmedTranscriptionText
        let target = pasteTargetApp
        let route = PasteRouter().route(for: target)
        let generation = pasteGeneration
        if !text.isEmpty, route == .uuCompatibility {
            // Publish the final text to the local clipboard *before* returning
            // focus to UU. UU's local → remote clipboard sync is the slow step
            // (it is what made pastes lag one session behind); the earlier the
            // text is on the board, the longer UU has to push it before ⌘V.
            PasteHelper.copyOnly(text)
        }
        closeSession()
        if text.isEmpty {
            print("[InputMethodSessionManager] ⚠️ Session completed with no text to copy")
        } else {
            schedulePaste(text, route: route, target: target, generation: generation)
        }
        print("[InputMethodSessionManager] ✅ Session completed (text length: \(text.count))")
    }

    private func schedulePaste(
        _ text: String,
        route: PasteRoute,
        target: NSRunningApplication?,
        generation: UUID
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
                    if !isFrontmost {
                        // Preserve the established UU compatibility behaviour:
                        // its defensive clipboard algorithm still owns timing.
                        print("[InputMethodSessionManager] ⚠️ UU target did not become frontmost before compatibility paste")
                    }
                    PasteHelper.copyAndPasteForUUCompatibility(text)
                }
            },
            uuDirect: { [weak self] in
                self?.waitUntilPasteTargetIsFrontmost(target: target, generation: generation) { isFrontmost in
                    guard let self, isFrontmost else {
                        print("[InputMethodSessionManager] ⚠️ UU target was not restored; not sending direct clipboard request")
                        return
                    }
                    self.startDirectPaste(text, target: target, generation: generation)
                }
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
        closeSession()
        print("[InputMethodSessionManager] Session cancelled and previous input source restored")
    }

    private func closeSession() {
        preparationWorkItem?.cancel()
        preparationWorkItem = nil
        functionKeyWorkItem?.cancel()
        functionKeyWorkItem = nil
        finalTextQuietWorkItem?.cancel()
        finalTextQuietWorkItem = nil
        stopSafetyWorkItem?.cancel()
        stopSafetyWorkItem = nil
        setFunctionKeyPressed(false)
        phase = .idle
        hotkeyManager.setEscapeHandlingEnabled(false)
        overlayPanel.clearText()
        overlayPanel.hideOverlay()
        inputSourceManager.restorePreviousInputSource()
        activatePreviousFrontmostApp()
        appState.reset()
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

    private var trimmedTranscriptionText: String {
        overlayPanel.currentText().trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func invalidatePendingPaste() {
        pasteGeneration = UUID()
        clipboardPublishWorkItem?.cancel()
        clipboardPublishWorkItem = nil
        directPasteTask?.cancel()
        directPasteTask = nil
        PasteHelper.cancelPendingPaste()
    }

    private func isPasteTargetFrontmost(_ target: NSRunningApplication?) -> Bool {
        guard let target else { return true }
        guard !target.isTerminated else { return false }
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == target.processIdentifier
    }

    private func startDirectPaste(_ text: String, target: NSRunningApplication?, generation: UUID) {
        directPasteTask?.cancel()
        directPasteTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.pasteGeneration == generation {
                    self.directPasteTask = nil
                }
            }
            do {
                _ = try await RemoteClipboardClient().write(text: text)
                guard !Task.isCancelled, self.pasteGeneration == generation else { return }
                guard self.isPasteTargetFrontmost(target) else {
                    print("[InputMethodSessionManager] ⚠️ Direct clipboard ACK arrived after target focus changed; not pasting")
                    self.handleDirectPasteOutcome(.targetFocusChangedAfterAcknowledgement, text: text)
                    return
                }
                PasteHelper.pasteOnly()
            } catch is CancellationError {
                // A new session, ESC, stop, or termination intentionally owns
                // cancellation; a late ACK must never paste into another app.
            } catch {
                guard !Task.isCancelled, self.pasteGeneration == generation else { return }
                print("[InputMethodSessionManager] ⚠️ Direct clipboard request failed; not pasting")
                self.handleDirectPasteOutcome(.remoteWriteFailed, text: text)
            }
        }
    }

    private func handleDirectPasteOutcome(_ outcome: DirectPasteOutcome, text: String) {
        directPasteFailureHandler.handle(
            outcome: outcome,
            text: text,
            copyTextLocally: { PasteHelper.copyOnly($0) },
            present: { [weak self] prompt, onSwitchToCompatibility in
                self?.directPasteFailurePresenter.present(prompt, onSwitchToCompatibility: onSwitchToCompatibility)
            }
        )
    }

    private func setFunctionKeyPressed(_ isPressed: Bool) {
        guard functionKeyIsDown != isPressed else { return }
        if !FunctionKeyInjector.post(isPressed) {
            print("[InputMethodSessionManager] ⚠️ Failed to post synthetic Fn event")
        }
        functionKeyIsDown = isPressed
    }

    private func showInputSourceError(_ message: String) {
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
