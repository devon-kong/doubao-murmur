import Foundation
import Cocoa
import os

private let logger = Logger(subsystem: "com.doubao.murmur", category: "HotkeyManager")
private let functionKeyDiagnosticsLogger = Logger(
    subsystem: "com.doubao.murmur",
    category: "FunctionKeyDiagnostics"
)

struct StopHotkeyReleaseGate {
    enum Action: Equatable {
        case slashReleased
        case controlReleased
        case fullyReleased
    }

    private var isPending = false
    private var didReleaseSlash = false
    private var didReleaseControl = false

    mutating func begin() -> Bool {
        guard !isPending else { return false }
        isPending = true
        didReleaseSlash = false
        didReleaseControl = false
        return true
    }

    mutating func observeSlashRelease() -> [Action] {
        guard isPending, !didReleaseSlash else { return [] }
        didReleaseSlash = true
        return resolvedActions(after: .slashReleased)
    }

    mutating func observeControlRelease() -> [Action] {
        guard isPending, !didReleaseControl else { return [] }
        didReleaseControl = true
        return resolvedActions(after: .controlReleased)
    }

    mutating func cancel() {
        isPending = false
        didReleaseSlash = false
        didReleaseControl = false
    }

    private mutating func resolvedActions(after release: Action) -> [Action] {
        guard didReleaseSlash, didReleaseControl else { return [release] }
        isPending = false
        return [release, .fullyReleased]
    }
}

enum PhysicalRightCommandEventFilter {
    static func isPhysicalRightCommand(keyCode: Int64, sourcePID: Int64) -> Bool {
        keyCode == 54 && sourcePID == 0
    }

    static func isPhysicalOrdinaryKeyDown(
        type: CGEventType,
        keyCode: Int64,
        sourcePID: Int64
    ) -> Bool {
        type == .keyDown && keyCode != 54 && sourcePID == 0
    }
}

class HotkeyManager {
    enum HotkeyEvent {
        case toggleRecording
        case toggleHotkeyFullyReleased
        case physicalRightCommandStopDown
        case physicalRightCommandStopUp
        case physicalRightCommandStopInterruptedByOrdinaryKey
        case cancel
    }

    var onHotkeyEvent: ((HotkeyEvent) -> Void)?

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var functionKeyDiagnosticsTap: CFMachPort?
    private var functionKeyDiagnosticsRunLoopSource: CFRunLoopSource?
    private var didAttemptFunctionKeyDiagnosticsTap = false
    private var accessibilityPollTimer: Timer?
    private var tapRetryCount = 0
    private let maxTapRetries = 30
    private var lastToggleTime: TimeInterval = 0
    private let debounceInterval: TimeInterval = 0.3
    private var shouldConsumeEscape = false
    private var stopHotkeyReleaseGate = StopHotkeyReleaseGate()
    private var physicalRightCommandIsDown = false

    init() {
        requestAccessibilityPermission()
    }

    func start() {
        let trusted = AXIsProcessTrusted()
        print("[HotkeyManager] Accessibility trusted: \(trusted)")

        if tryCreateEventTap() {
            tapRetryCount = 0
            startFunctionKeyDiagnosticsTapIfNeeded()
            return
        }

        print("[HotkeyManager] ❌ Failed to create event tap. Accessibility permission may be needed.")
        if !trusted {
            requestAccessibilityPermission()
        }
        startPollingForEventTap()
    }

    private func tryCreateEventTap() -> Bool {
        let eventMask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)

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

    private func startFunctionKeyDiagnosticsTapIfNeeded() {
        guard !didAttemptFunctionKeyDiagnosticsTap else { return }
        didAttemptFunctionKeyDiagnosticsTap = true

        let eventMask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue) |
            (1 << CGEventType.keyUp.rawValue) |
            (1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: functionKeyDiagnosticsCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ), let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            functionKeyDiagnosticsLogger.warning(
                "origin=hid_tap status=create_failed; main hotkey tap remains independent"
            )
            return
        }

        functionKeyDiagnosticsTap = tap
        functionKeyDiagnosticsRunLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
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
                self.startFunctionKeyDiagnosticsTapIfNeeded()
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
        if let tap = functionKeyDiagnosticsTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let source = functionKeyDiagnosticsRunLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        functionKeyDiagnosticsTap = nil
        functionKeyDiagnosticsRunLoopSource = nil
        didAttemptFunctionKeyDiagnosticsTap = false
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

    func beginStopHotkeyReleaseTracking() {
        guard stopHotkeyReleaseGate.begin() else { return }
        logger.notice("event=toggle_hotkey_pressed")
    }

    func cancelStopHotkeyReleaseTracking() {
        stopHotkeyReleaseGate.cancel()
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

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        if keyCode == 63 || keyCode == 54 { // kVK_Function / kVK_RightCommand
            let frontmostBundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none"
            functionKeyDiagnosticsLogger.notice(
                "origin=event_tap eventType=\(type.rawValue, privacy: .public) flags=\(event.flags.rawValue, privacy: .public) keyCode=\(keyCode, privacy: .public) sourcePID=\(event.getIntegerValueField(.eventSourceUnixProcessID), privacy: .public) sourceState=\(event.getIntegerValueField(.eventSourceStateID), privacy: .public) keyboardType=\(event.getIntegerValueField(.keyboardEventKeyboardType), privacy: .public) frontmostBundle=\(frontmostBundleIdentifier, privacy: .public)"
            )
            return Unmanaged.passRetained(event)
        }

        if type == .keyUp, keyCode == 44 {
            reportStopHotkeyReleaseActions(stopHotkeyReleaseGate.observeSlashRelease())
        }

        if type == .flagsChanged, !event.flags.contains(.maskControl) {
            reportStopHotkeyReleaseActions(stopHotkeyReleaseGate.observeControlRelease())
        }

        if type == .keyDown {
            // Control + / (ANSI keycode 44), without other primary modifiers.
            let modifiers = event.flags.intersection([.maskShift, .maskControl, .maskAlternate, .maskCommand])
            if keyCode == 44 && modifiers == .maskControl {
                let now = ProcessInfo.processInfo.systemUptime
                if now - lastToggleTime > debounceInterval {
                    lastToggleTime = now
                    beginStopHotkeyReleaseTracking()
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

    private func reportStopHotkeyReleaseActions(_ actions: [StopHotkeyReleaseGate.Action]) {
        for action in actions {
            switch action {
            case .slashReleased:
                logger.notice("event=slash_released")
            case .controlReleased:
                logger.notice("event=control_released")
            case .fullyReleased:
                logger.notice("event=toggle_hotkey_released")
                logger.notice("event=toggle_hotkey_fully_released")
                onHotkeyEvent?(.toggleHotkeyFullyReleased)
            }
        }
    }

    fileprivate func handleFunctionKeyDiagnosticsEvent(
        _ type: CGEventType,
        _ event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = functionKeyDiagnosticsTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passRetained(event)
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let sourcePID = event.getIntegerValueField(.eventSourceUnixProcessID)
        let isPhysicalRightCommand = PhysicalRightCommandEventFilter.isPhysicalRightCommand(
            keyCode: keyCode,
            sourcePID: sourcePID
        )
        if keyCode == 63 || keyCode == 54 || event.flags.contains(.maskSecondaryFn) {
            let frontmostBundleIdentifier = NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "none"
            functionKeyDiagnosticsLogger.notice(
                "origin=hid_tap eventType=\(type.rawValue, privacy: .public) flags=\(event.flags.rawValue, privacy: .public) keyCode=\(keyCode, privacy: .public) sourcePID=\(sourcePID, privacy: .public) sourceState=\(event.getIntegerValueField(.eventSourceStateID), privacy: .public) keyboardType=\(event.getIntegerValueField(.keyboardEventKeyboardType), privacy: .public) frontmostBundle=\(frontmostBundleIdentifier, privacy: .public)"
            )
        }

        if isPhysicalRightCommand, type == .flagsChanged {
            if event.flags.contains(.maskCommand) {
                physicalRightCommandIsDown = true
                functionKeyDiagnosticsLogger.notice("event=physical_right_command_stop_down")
                onHotkeyEvent?(.physicalRightCommandStopDown)
            } else {
                physicalRightCommandIsDown = false
                functionKeyDiagnosticsLogger.notice("event=physical_right_command_stop_up")
                onHotkeyEvent?(.physicalRightCommandStopUp)
            }
        } else if physicalRightCommandIsDown,
                  PhysicalRightCommandEventFilter.isPhysicalOrdinaryKeyDown(
                      type: type,
                      keyCode: keyCode,
                      sourcePID: sourcePID
                  ) {
            functionKeyDiagnosticsLogger.notice(
                "event=physical_right_command_stop_interrupted keyCode=\(keyCode, privacy: .public)"
            )
            onHotkeyEvent?(.physicalRightCommandStopInterruptedByOrdinaryKey)
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

private func functionKeyDiagnosticsCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo = userInfo else {
        return Unmanaged.passRetained(event)
    }
    let manager = Unmanaged<HotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()
    return manager.handleFunctionKeyDiagnosticsEvent(type, event)
}
