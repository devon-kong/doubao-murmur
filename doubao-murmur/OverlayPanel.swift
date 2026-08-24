import AppKit
import SwiftUI

class OverlayPanel: NSPanel {
    private let appState: AppState
    private weak var textView: NSTextView?
    var onCancel: (() -> Void)?

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

    func showOverlay() {
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
        focusTextInput()
        print("[OverlayPanel] ✅ Overlay is now visible (isVisible=\(isVisible), isKeyWindow=\(isKeyWindow))")
    }

    func focusTextInput() {
        makeKey()
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.makeKey()
            self.makeFirstResponder(self.textView)
        }
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
        textView.unmarkText()
        textView.string = ""
        textView.setSelectedRange(NSRange(location: 0, length: 0))
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { // ESC
            print("[OverlayPanel] ESC key received via keyDown")
            onCancel?()
        } else {
            super.keyDown(with: event)
        }
    }

    private func installTextView(_ textView: NSTextView) {
        self.textView = textView
        if isVisible {
            focusTextInput()
        }
    }
}
