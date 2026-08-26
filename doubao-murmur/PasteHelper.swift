import Foundation
import AppKit

struct PasteHelper {
    /// UserDefaults key for the user-configurable paste quiet period.
    static let quietPeriodDefaultsKey = "pasteQuietPeriodSeconds"
    /// Verified against UU remote on a normal network; 0.25s was observed to
    /// paste the previous session's text when the network got slower.
    static let defaultQuietPeriod: TimeInterval = 1.0
    static let minimumQuietPeriod: TimeInterval = 0.1
    static let maximumQuietPeriod: TimeInterval = 10.0

    /// How long the local clipboard must keep *this* session's text before ⌘V.
    /// UU's ⌘V uses the *remote* clipboard; this quiet window is the outbound
    /// sync from the local Mac to the controlled machine. User-configurable
    /// from the status-bar menu because UU's sync latency varies by network.
    static var remoteSyncQuietPeriod: TimeInterval {
        let stored = UserDefaults.standard.double(forKey: quietPeriodDefaultsKey)
        guard stored > 0 else { return defaultQuietPeriod }
        return min(max(stored, minimumQuietPeriod), maximumQuietPeriod)
    }

    static func setQuietPeriod(_ value: TimeInterval) {
        UserDefaults.standard.set(
            min(max(value, minimumQuietPeriod), maximumQuietPeriod),
            forKey: quietPeriodDefaultsKey
        )
    }

    private static let pollInterval: TimeInterval = 0.05
    private static var pasteWorkItem: DispatchWorkItem?

    enum CompatibilityPasteFailure {
        case deadlineExpired
        case targetNotFrontmost
    }

    struct CompatibilityPasteFailureResult {
        let failure: CompatibilityPasteFailure
        /// The single fail-closed write was confirmed by an immediate read.
        let clipboardRetained: Bool
    }

    enum ClipboardDefensePolicy {
        static let minimumMaximumWait: TimeInterval = 2.0

        enum Phase {
            case defendingClipboard
            case finalEventAuthorization
        }

        enum Decision: Equatable {
            case continueDefending
            case postPasteEvent
            case resetStableWindow
            case deadlineExpired
            case targetNotFrontmost
        }

        static func maximumWait(for stableWindow: TimeInterval) -> TimeInterval {
            max(minimumMaximumWait, stableWindow * 2)
        }

        static func canStillSucceed(
            stableElapsed: TimeInterval,
            remainingBudget: TimeInterval,
            stableWindow: TimeInterval
        ) -> Bool {
            let remainingStableTime = max(0, stableWindow - stableElapsed)
            return remainingBudget >= remainingStableTime
        }

        /// Used by the controller before entering the compatibility loop.
        static func initialTargetDecision(targetIsFrontmost: Bool) -> Decision {
            targetIsFrontmost ? .continueDefending : .targetNotFrontmost
        }

        /// The compatibility loop uses this decision at every polling tick and
        /// again immediately before the irreversible Command-V event.
        static func decision(
            phase: Phase,
            now: TimeInterval,
            deadline: TimeInterval,
            targetIsFrontmost: Bool,
            clipboardMatches: Bool
        ) -> Decision {
            guard now < deadline else { return .deadlineExpired }
            guard targetIsFrontmost else { return .targetNotFrontmost }
            switch phase {
            case .defendingClipboard:
                return .continueDefending
            case .finalEventAuthorization:
                return clipboardMatches ? .postPasteEvent : .resetStableWindow
            }
        }
    }

    static func cancelPendingPaste() {
        pasteWorkItem?.cancel()
        pasteWorkItem = nil
    }

    /// Local applications do not need UU's remote clipboard settling or
    /// defensive rewrites: restore focus, write once, then paste immediately.
    static func copyAndPasteLocally(_ text: String) {
        cancelPendingPaste()
        guard writeClipboard(text) else { return }
        log("⌘V locally")
        pasteOnly()
    }

    /// Compatibility path for UU's local → remote clipboard synchronisation.
    /// This intentionally preserves the existing quiet-period and defensive
    /// rewrite algorithm, including a user-customised value.
    static func copyAndPasteForUUCompatibility(
        _ text: String,
        isPasteTargetFrontmost: @escaping () -> Bool,
        onFailure: @escaping (CompatibilityPasteFailureResult) -> Void
    ) {
        cancelPendingPaste()
        let existing = NSPasteboard.general.string(forType: .string)
        if existing == text {
            // Already on the board (written at session finalize). Do NOT
            // rewrite: a changeCount bump can reset UU's outbound-sync
            // debounce and push the remote update past our ⌘V.
            log("local clipboard already has this text; defending without rewrite")
        } else {
            log("local clipboard differs (now \(existing?.count ?? 0) chars); writing this session's text")
            guard writeClipboard(text) else { return }
        }
        defendThenPaste(
            text,
            isPasteTargetFrontmost: isPasteTargetFrontmost,
            onFailure: onFailure
        )
    }

    @discardableResult
    static func copyOnly(_ text: String) -> Bool {
        writeClipboard(text)
    }

    /// Posts a local paste event. The direct UU route intentionally does not
    /// call this: its helper posts Command-V on the controlled Mac instead.
    static func pasteOnly() {
        simulatePaste()
    }

    /// UU bidirectional clipboard:
    /// 1. A copy on the remote machine leaves that text on the remote board.
    /// 2. When UU becomes frontmost it often applies remote → local, stealing
    ///    our write.
    /// 3. ⌘V is executed on the remote, so we must keep rewriting until the
    ///    local board stays on this session's text long enough for local →
    ///    remote sync, then paste.
    private static func defendThenPaste(
        _ text: String,
        isPasteTargetFrontmost: @escaping () -> Bool,
        onFailure: @escaping (CompatibilityPasteFailureResult) -> Void
    ) {
        // `systemUptime` is monotonic, unlike `Date`, so a wall-clock change
        // cannot extend the permission window for posting Command-V.
        let startedAt = ProcessInfo.processInfo.systemUptime
        let stableWindow = remoteSyncQuietPeriod
        let maximumWait = ClipboardDefensePolicy.maximumWait(for: stableWindow)
        let deadline = startedAt + maximumWait
        var stableSince: TimeInterval? = startedAt

        func failClosed(_ failure: CompatibilityPasteFailure, now: TimeInterval) {
            let retained = writeClipboard(text)
            let elapsed = max(0, now - startedAt)
            log(
                "compatibility paste stopped after \(String(format: "%.2f", elapsed))s " +
                    "(reason=\(failure), clipboardRetained=\(retained))"
            )
            pasteWorkItem = nil
            onFailure(CompatibilityPasteFailureResult(failure: failure, clipboardRetained: retained))
        }

        func scheduleNextTick() {
            let workItem = DispatchWorkItem { tick() }
            pasteWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + pollInterval, execute: workItem)
        }

        func tick() {
            var now = ProcessInfo.processInfo.systemUptime
            let tickDecision = ClipboardDefensePolicy.decision(
                phase: .defendingClipboard,
                now: now,
                deadline: deadline,
                targetIsFrontmost: isPasteTargetFrontmost(),
                clipboardMatches: true
            )
            switch tickDecision {
            case .deadlineExpired:
                failClosed(.deadlineExpired, now: now)
                return
            case .targetNotFrontmost:
                failClosed(.targetNotFrontmost, now: now)
                return
            case .continueDefending:
                break
            case .postPasteEvent, .resetStableWindow:
                assertionFailure("Unexpected compatibility decision while defending clipboard")
                return
            }

            let current = NSPasteboard.general.string(forType: .string)
            if current != text {
                log("clipboard stolen (now \(current?.count ?? 0) chars); rewriting this session's text")
                guard writeClipboard(text) else { return }
                stableSince = ProcessInfo.processInfo.systemUptime
                now = stableSince ?? now
            }

            let stableElapsed = stableSince.map { max(0, now - $0) } ?? 0
            if stableElapsed >= stableWindow {
                if NSPasteboard.general.string(forType: .string) != text {
                    guard writeClipboard(text) else { return }
                    stableSince = ProcessInfo.processInfo.systemUptime
                } else {
                    // Re-read all authorization inputs immediately before the
                    // irreversible event. A delayed main-queue tick must never
                    // turn an expired or unfocused session into a paste.
                    now = ProcessInfo.processInfo.systemUptime
                    let clipboardMatches = NSPasteboard.general.string(forType: .string) == text
                    let finalDecision = ClipboardDefensePolicy.decision(
                        phase: .finalEventAuthorization,
                        now: now,
                        deadline: deadline,
                        targetIsFrontmost: isPasteTargetFrontmost(),
                        clipboardMatches: clipboardMatches
                    )
                    switch finalDecision {
                    case .postPasteEvent:
                        log("⌘V (stable \(String(format: "%.2f", stableElapsed))s)")
                        pasteWorkItem = nil
                        simulatePaste()
                        return
                    case .deadlineExpired:
                        failClosed(.deadlineExpired, now: now)
                        return
                    case .targetNotFrontmost:
                        failClosed(.targetNotFrontmost, now: now)
                        return
                    case .resetStableWindow:
                        // A changed clipboard restarts stability; it is not
                        // an authorization to post an event yet.
                        guard writeClipboard(text) else { return }
                        stableSince = ProcessInfo.processInfo.systemUptime
                        scheduleNextTick()
                        return
                    case .continueDefending:
                        assertionFailure("Unexpected final compatibility decision")
                        return
                    }
                }
            }

            now = ProcessInfo.processInfo.systemUptime
            let remainingBudget = max(0, deadline - now)
            let currentStableElapsed = stableSince.map { max(0, now - $0) } ?? 0
            let canStillSucceed = ClipboardDefensePolicy.canStillSucceed(
                stableElapsed: currentStableElapsed,
                remainingBudget: remainingBudget,
                stableWindow: stableWindow
            )
            if now >= deadline || !canStillSucceed {
                failClosed(.deadlineExpired, now: now)
                return
            }

            scheduleNextTick()
        }

        tick()
    }

    private static func log(_ message: String) {
        print("[PasteHelper \(Self.timestamp())] \(message)")
    }

    private static func timestamp() -> String {
        let now = Date()
        let calendar = Calendar.current
        let h = calendar.component(.hour, from: now)
        let m = calendar.component(.minute, from: now)
        let s = calendar.component(.second, from: now)
        let ms = calendar.component(.nanosecond, from: now) / 1_000_000
        return String(format: "%02d:%02d:%02d.%03d", h, m, s, ms)
    }

    @discardableResult
    private static func writeClipboard(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setString(text, forType: .string) else {
            log("❌ Failed to write transcription text to the clipboard")
            return false
        }
        guard pasteboard.string(forType: .string) == text else {
            log("❌ Clipboard did not retain transcription text after write")
            return false
        }
        log("✅ Copied transcription text (length: \(text.count))")
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
