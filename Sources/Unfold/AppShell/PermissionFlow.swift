import AppKit
import ApplicationServices

enum PermissionFlow {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Only called from an explicit user action, never on launch: prompting unasked trains people
    /// to click through permission dialogs.
    static func prompt() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    static func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    /// Polls rather than observing, because there is no public notification for the grant. The
    /// interval is deliberately loose, and the poll continues after a grant on purpose: a revoked
    /// permission must reach the menu without a relaunch.
    static func waitUntilTrusted(interval: TimeInterval = 1.0, onChange: @escaping (Bool) -> Void) -> Timer {
        var last = isTrusted
        onChange(last)
        return Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { timer in
            let now = isTrusted
            if now != last {
                last = now
                onChange(now)
            }
        }
    }
}
