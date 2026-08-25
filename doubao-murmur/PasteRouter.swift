import AppKit
import Foundation

enum UUPasteMode: String, CaseIterable {
    case compatibility
    case direct

    var menuTitle: String {
        switch self {
        case .compatibility: return "兼容模式（UU 剪贴板同步）"
        case .direct: return "快速模式（被控制端直写）"
        }
    }
}

enum PasteRoute: Equatable {
    case local
    case uuCompatibility
    case uuDirect
}

/// Persisted independently from the existing quiet-period value. An absent or
/// invalid value intentionally keeps every upgrading user on compatibility.
struct PasteRoutingSettings {
    static let uuPasteModeDefaultsKey = "uuRemotePasteMode"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var uuPasteMode: UUPasteMode {
        get {
            guard let rawValue = defaults.string(forKey: Self.uuPasteModeDefaultsKey),
                  let mode = UUPasteMode(rawValue: rawValue) else {
                return .compatibility
            }
            return mode
        }
        nonmutating set {
            defaults.set(newValue.rawValue, forKey: Self.uuPasteModeDefaultsKey)
        }
    }
}

/// Keeps target identification and strategy selection free of session, HTTP,
/// clipboard, and window-title details. Only UU's verified bundle identifier
/// is eligible for either remote route.
struct PasteRouter {
    static let uuBundleIdentifier = "com.netease.uuremote"

    private let settings: PasteRoutingSettings

    init(settings: PasteRoutingSettings = PasteRoutingSettings()) {
        self.settings = settings
    }

    func route(for targetApp: NSRunningApplication?) -> PasteRoute {
        route(bundleIdentifier: targetApp?.bundleIdentifier)
    }

    func route(bundleIdentifier: String?) -> PasteRoute {
        guard bundleIdentifier == Self.uuBundleIdentifier else { return .local }
        return settings.uuPasteMode == .direct ? .uuDirect : .uuCompatibility
    }

    /// Both UU routes must publish the text locally before the app restores UU
    /// to the foreground. Compatibility needs time for normal sync; direct
    /// needs the same prepublish so both channels carry the same current text,
    /// reducing the risk of UU bidirectional sync overwriting the controlled
    /// Mac's freshly written clipboard. This never authorizes a paste by itself.
    static func shouldPrepublishLocalClipboard(for route: PasteRoute) -> Bool {
        switch route {
        case .local: return false
        case .uuCompatibility, .uuDirect: return true
        }
    }

    /// A small dispatch seam used by the session manager and isolated routing
    /// tests, so a new route cannot accidentally invoke another strategy.
    static func execute(
        _ route: PasteRoute,
        local: () -> Void,
        uuCompatibility: () -> Void,
        uuDirect: () -> Void
    ) {
        switch route {
        case .local: local()
        case .uuCompatibility: uuCompatibility()
        case .uuDirect: uuDirect()
        }
    }
}
