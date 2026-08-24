import Foundation
import Cocoa
import os

private let logger = Logger(subsystem: "com.doubao.murmur", category: "HotkeyManager")

class HotkeyManager {
    enum HotkeyEvent {
        case toggleRecording
        case cancel
    }

    var onHotkeyEvent: ((HotkeyEvent) -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var accessibilityPollTimer: Timer?
    private var tapRetryCount = 0
    private let maxTapRetries = 30
    private var lastToggleTime: TimeInterval = 0
    private let debounceInterval: TimeInterval = 0.3
    private var shouldConsumeEscape = false

    init() {
        requestAccessibilityPermission()
    }

    func start() {
        let trusted = AXIsProcessTrusted()
        print("[HotkeyManager] Accessibility trusted: \(trusted)")

        if tryCreateEventTap() {
            tapRetryCount = 0
            return
        }

        print("[HotkeyManager] ❌ Failed to create event tap. Accessibility permission may be needed.")
        if !trusted {
            requestAccessibilityPermission()
        }
        startPollingForEventTap()
    }

    private func tryCreateEventTap() -> Bool {
        let eventMask: CGEventMask = 1 << CGEventType.keyDown.rawValue

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventMask,
            callback: hotkeyCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }

        eventTap = tap
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        print("[HotkeyManager] ✅ Event tap started successfully")
        return true
    }

    private func startPollingForEventTap() {
        accessibilityPollTimer?.invalidate()
        tapRetryCount = 0
        print("[HotkeyManager] ⏳ Polling for event tap creation (every 2s, max \(maxTapRetries) attempts)...")
        accessibilityPollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.tapRetryCount += 1
            print("[HotkeyManager] 🔄 Retry \(self.tapRetryCount)/\(self.maxTapRetries) to create event tap...")

            if self.tryCreateEventTap() {
                print("[HotkeyManager] ✅ Event tap created on retry \(self.tapRetryCount)")
                self.accessibilityPollTimer?.invalidate()
                self.accessibilityPollTimer = nil
                self.tapRetryCount = 0
                return
            }

            if self.tapRetryCount >= self.maxTapRetries {
                print("[HotkeyManager] ❌ Giving up after \(self.maxTapRetries) retries. Please remove and re-grant Accessibility permission, then restart the app.")
                self.accessibilityPollTimer?.invalidate()
                self.accessibilityPollTimer = nil
            }
        }
    }

    func stop() {
        accessibilityPollTimer?.invalidate()
        accessibilityPollTimer = nil
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    func setEscapeHandlingEnabled(_ isEnabled: Bool) {
        shouldConsumeEscape = isEnabled
        logger.notice("ESC handling enabled: \(isEnabled)")
    }

    private func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeRetainedValue(): true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        if !trusted {
            print("[HotkeyManager] Accessibility permission not granted. Please enable it in System Settings > Privacy & Security > Accessibility.")
        }
    }

    fileprivate func handleEvent(_ proxy: CGEventTapProxy, _ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // Re-enable the tap
            logger.warning("Event tap was disabled (type=\(type.rawValue)), re-enabling...")
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passRetained(event)
        }

        if type == .keyDown {
            let keyCode = event.getIntegerValueField(.keyboardEventKeycode)

            // Control + / (ANSI keycode 44), without other primary modifiers.
            let modifiers = event.flags.intersection([.maskShift, .maskControl, .maskAlternate, .maskCommand])
            if keyCode == 44 && modifiers == .maskControl {
                let now = ProcessInfo.processInfo.systemUptime
                if now - lastToggleTime > debounceInterval {
                    lastToggleTime = now
                    print("[HotkeyManager] 🎤 Control + / -> toggleRecording (handler set: \(onHotkeyEvent != nil))")
                    onHotkeyEvent?(.toggleRecording)
                } else {
                    print("[HotkeyManager] Control + / debounced (interval=\(now - lastToggleTime)s)")
                }
                return nil // Consume Control + /
            }

            // ESC key
            if keyCode == 53 {
                logger.notice(
                    "ESC pressed (keyCode=53, handler set: \(self.onHotkeyEvent != nil), shouldConsume: \(self.shouldConsumeEscape))"
                )
                guard shouldConsumeEscape else {
                    return Unmanaged.passRetained(event)
                }
                onHotkeyEvent?(.cancel)
                return nil // Consume ESC when we handle it
            }
        }

        return Unmanaged.passRetained(event)
    }
}

// C callback for CGEvent tap
private func hotkeyCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo = userInfo else {
        return Unmanaged.passRetained(event)
    }
    let manager = Unmanaged<HotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()
    return manager.handleEvent(proxy, type, event)
}
