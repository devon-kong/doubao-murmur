import Foundation
import AppKit

struct PasteHelper {
    static func copyAndPaste(_ text: String) {
        guard !text.isEmpty else { return }

        // Copy to clipboard
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            print("[PasteHelper] ❌ Failed to write transcription text to the clipboard")
            return
        }
        print("[PasteHelper] ✅ Copied transcription text (length: \(text.count))")

        // Allow the frontmost app and any remote clipboard sync to settle before ⌘V.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            print("[PasteHelper] ⌘V")
            simulatePaste()
        }
    }

    static func copyOnly(_ text: String) {
        guard !text.isEmpty else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    private static func simulatePaste() {
        let source = CGEventSource(stateID: .hidSystemState)

        // Key down: ⌘V
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true) // 0x09 = V
        keyDown?.flags = .maskCommand

        // Key up: ⌘V
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        keyUp?.flags = .maskCommand

        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
}
