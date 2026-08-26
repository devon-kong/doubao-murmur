import AppKit
import SwiftUI

class OverlayPanel: NSPanel {
    private let appState: AppState
    private weak var textView: IMETrackingTextView?
    private var focusRequestID: UUID?
    private var focusCompletion: ((Bool) -> Void)?
    var onCancel: (() -> Void)?
    var onMarkedTextStateChanged: ((Bool) -> Void)?

    override var canBecomeKey: Bool { true }

    init(appState: AppState) {
        self.appState = appState

        let width: CGFloat = 420
        let height: CGFloat = 76

        // Position at top-center of main screen
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let x = screenFrame.midX - width / 2
        let y = screenFrame.maxY - height - 20

        super.init(
            contentRect: NSRect(x: x, y: y, width: width, height: height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        self.level = .floating
        self.isOpaque = false
        self.backgroundColor = .clear
        self.hasShadow = true
        self.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.isMovableByWindowBackground = true
        self.hidesOnDeactivate = false

        let hostingView = NSHostingView(
            rootView: OverlayView(appState: appState) { [weak self] textView in
                self?.installTextView(textView)
            }
        )
        self.contentView = hostingView
    }

    func showOverlay(onFocusReady: @escaping (Bool) -> Void) {
        print("[OverlayPanel] showOverlay called")
        // Reposition to top-center in case screen changed
        if let screen = NSScreen.main {
            let width: CGFloat = 420
            let height: CGFloat = 76
            let x = screen.visibleFrame.midX - width / 2
            let y = screen.visibleFrame.maxY - height - 20
            let frame = NSRect(x: x, y: y, width: width, height: height)
            print("[OverlayPanel] Setting frame: \(frame)")
            setFrame(frame, display: true)
        }
        orderFrontRegardless()
        requestTextInputFocus(onReady: onFocusReady)
        print("[OverlayPanel] ✅ Overlay is now visible (isVisible=\(isVisible), isKeyWindow=\(isKeyWindow))")
    }

    func maintainTextInputFocus() {
        makeKey()
        if let textView {
            makeFirstResponder(textView)
        }
    }

    func cancelTextInputFocusRequest() {
        focusRequestID = nil
        focusCompletion = nil
    }

    var hasMarkedText: Bool {
        textView?.hasMarkedText() ?? false
    }

    func hideOverlay() {
        print("[OverlayPanel] hideOverlay called")
        resignKey()
        orderOut(nil)
    }

    /// Read directly from the AppKit text client before the panel is dismissed.
    /// This remains reliable even if SwiftUI's binding has not caught up with an
    /// input method's final committed text.
    func currentText() -> String {
        textView?.string ?? appState.transcriptionText
    }

    /// Clear the AppKit text client synchronously so a previous session's text
    /// cannot be drawn during the next panel presentation.
    func clearText() {
        guard let textView else { return }
        textView.clearProgrammatically()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // ESC
            print("[OverlayPanel] ESC key received via keyDown")
            onCancel?()
        } else {
            super.keyDown(with: event)
        }
    }

    private func installTextView(_ textView: IMETrackingTextView) {
        self.textView = textView
        textView.onMarkedTextStateChanged = { [weak self] hasMarkedText in
            self?.onMarkedTextStateChanged?(hasMarkedText)
        }
        attemptPendingTextInputFocus()
    }

    private func requestTextInputFocus(onReady: @escaping (Bool) -> Void) {
        let requestID = UUID()
        focusRequestID = requestID
        focusCompletion = onReady
        attemptPendingTextInputFocus()
    }

    private func attemptPendingTextInputFocus() {
        guard let requestID = focusRequestID,
              let textView else { return }
        makeKey()
        let accepted = makeFirstResponder(textView)
        DispatchQueue.main.async { [weak self, weak textView] in
            guard let self,
                  let textView,
                  self.focusRequestID == requestID else { return }
            let confirmed = accepted
                && self.isKeyWindow
                && self.firstResponder === textView
            let completion = self.focusCompletion
            self.focusRequestID = nil
            self.focusCompletion = nil
            completion?(confirmed)
        }
    }
}
