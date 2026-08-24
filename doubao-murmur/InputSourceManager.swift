import Carbon
import Foundation

/// Selects the installed Doubao input source using macOS's public Text Input
/// Services API and restores the source that was active before a voice-input session.
final class InputSourceManager {
    static let doubaoInputSourceID = "com.bytedance.inputmethod.doubaoime.pinyin"

    private var previousInputSource: TISInputSource?

    func saveCurrentInputSource() -> Bool {
        guard previousInputSource == nil else { return true }
        guard let inputSource = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else {
            return false
        }
        previousInputSource = inputSource
        return true
    }

    func selectDoubaoInputSource() -> Bool {
        guard let inputSource = inputSource(withID: Self.doubaoInputSourceID) else {
            return false
        }
        return TISSelectInputSource(inputSource) == noErr
    }

    func restorePreviousInputSource() {
        defer { previousInputSource = nil }
        guard let previousInputSource else { return }
        let status = TISSelectInputSource(previousInputSource)
        if status != noErr {
            print("[InputSourceManager] ⚠️ Failed to restore input source (status=\(status))")
        }
    }

    private func inputSource(withID inputSourceID: String) -> TISInputSource? {
        let sources = TISCreateInputSourceList(nil, false).takeRetainedValue() as NSArray
        for sourceObject in sources {
            let source = sourceObject as! TISInputSource
            guard let property = TISGetInputSourceProperty(source, kTISPropertyInputSourceID)
            else {
                continue
            }
            let identifier = Unmanaged<CFString>.fromOpaque(property).takeUnretainedValue() as String
            if identifier == inputSourceID {
                return source
            }
        }
        return nil
    }
}
