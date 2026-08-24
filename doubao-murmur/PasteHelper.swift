import Foundation
import AppKit

struct PasteHelper {
    /// How long the local clipboard must keep *this* session's text before ⌘V.
    /// UU's ⌘V uses the *remote* clipboard; this quiet window is the outbound
    /// sync from the local Mac to the controlled machine.
    private static let remoteSyncQuietPeriod: TimeInterval = 0.25
    private static let pollInterval: TimeInterval = 0.05
    private static let defendTimeout: TimeInterval = 1.50
    private static var pasteWorkItem: DispatchWorkItem?

    static func cancelPendingPaste() {
        pasteWorkItem?.cancel()
        pasteWorkItem = nil
    }

    static func copyAndPaste(_ text: String) {
        cancelPendingPaste()
        let existing = NSPasteboard.general.string(forType: .string)
        if existing == text {
            print("[PasteHelper] local clipboard already has this text; still waiting for remote sync")
        } else {
            print("[PasteHelper] local clipboard differs (now \(existing?.count ?? 0) chars); treating as remote X")
        }
        guard writeClipboard(text) else { return }
        defendThenPaste(text)
    }

    static func copyOnly(_ text: String) {
        _ = writeClipboard(text)
    }

    /// UU bidirectional clipboard:
    /// 1. A copy on the remote machine leaves that text on the remote board.
    /// 2. When UU becomes frontmost it often applies remote → local, stealing
    ///    our write.
    /// 3. ⌘V is executed on the remote, so we must keep rewriting until the
    ///    local board stays on this session's text long enough for local →
    ///    remote sync, then paste.
    private static func defendThenPaste(_ text: String) {
        let startedAt = Date()
        var stableSince: Date? = Date()

        func tick() {
            let now = Date()
            let current = NSPasteboard.general.string(forType: .string)
            if current != text {
                print("[PasteHelper] clipboard stolen (now \(current?.count ?? 0) chars); rewriting this session's text")
                guard writeClipboard(text) else { return }
                stableSince = Date()
            }

            let stableElapsed = stableSince.map { now.timeIntervalSince($0) } ?? 0
            let timedOut = now.timeIntervalSince(startedAt) >= defendTimeout
            if stableElapsed >= remoteSyncQuietPeriod || timedOut {
                if NSPasteboard.general.string(forType: .string) != text {
                    _ = writeClipboard(text)
                    let retry = DispatchWorkItem {
                        print("[PasteHelper] ⌘V after timeout rewrite")
                        simulatePaste()
                    }
                    pasteWorkItem = retry
                    DispatchQueue.main.asyncAfter(deadline: .now() + remoteSyncQuietPeriod, execute: retry)
                    return
                }
                print("[PasteHelper] ⌘V (stable \(String(format: "%.2f", stableElapsed))s)")
                simulatePaste()
                return
            }

            let workItem = DispatchWorkItem { tick() }
            pasteWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + pollInterval, execute: workItem)
        }

        tick()
    }

    @discardableResult
    private static func writeClipboard(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            print("[PasteHelper] ❌ Failed to write transcription text to the clipboard")
            return false
        }
        print("[PasteHelper] ✅ Copied transcription text (length: \(text.count))")
        return true
    }

    private static func simulatePaste() {
        let source = CGEventSource(stateID: .hidSystemState)

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: true)
        keyDown?.flags = .maskCommand

        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x09, keyDown: false)
        keyUp?.flags = .maskCommand

        keyDown?.post(tap: .cghidEventTap)
        keyUp?.post(tap: .cghidEventTap)
    }
}
