import AppKit
import CoreGraphics
import UnfoldEngine

public protocol TextInjecting {
    func insert(_ text: String, mode: InsertionMode)
}

public final class Injector: TextInjecting {
    private let pasteboard = NSPasteboard.general
    /// Restoring synchronously races the target app's read, so the restore is deferred and
    /// guarded by changeCount (ruling R-P2-4).
    private static let restoreDelay = 0.25
    private static let vKeyCode = 9

    public init() {}

    public func insert(_ text: String, mode: InsertionMode) {
        switch mode {
        case .paste: paste(text)
        case .keys: type(text)
        }
    }

    private func paste(_ text: String) {
        let saved = capture()
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let ourCount = pasteboard.changeCount
        postCmdV()

        DispatchQueue.main.asyncAfter(deadline: .now() + Injector.restoreDelay) { [pasteboard] in
            guard pasteboard.changeCount == ourCount else { return }
            // Qualified because an unqualified `restore` inside an instance method resolves against
            // `self`, and a static member cannot be called on an instance.
            Injector.restore(saved, to: pasteboard)
        }
    }

    /// Every type, not just `.string`: a user who copied an image and then expanded a snippet must
    /// get the image back. Losing their clipboard is a data-loss bug and outranks tidiness
    /// (ruling R-P2-4).
    private func capture() -> [(NSPasteboard.PasteboardType, Data)] {
        pasteboard.types?.compactMap { type in
            pasteboard.data(forType: type).map { (type, $0) }
        } ?? []
    }

    private static func restore(_ items: [(NSPasteboard.PasteboardType, Data)],
                                to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        for (type, data) in items { pasteboard.setData(data, forType: type) }
    }

    private func postCmdV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(Injector.vKeyCode), keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(Injector.vKeyCode), keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cgSessionEventTap)
        up?.post(tap: .cgSessionEventTap)
    }

    /// For apps that reject synthetic paste. Setting the unicode string directly sidesteps layout.
    private func type(_ text: String) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for scalar in text.unicodeScalars {
            // `var` only because `keyboardSetUnicodeString` takes an `inout` array; `let` will not compile.
            var utf16 = Array(String(scalar).utf16)
            let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
            // The real label on this SDK is `stringLength:`, not `maxLength:` -- the compiler decided.
            down?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            down?.post(tap: .cgSessionEventTap)
            CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)?.post(tap: .cgSessionEventTap)
        }
    }
}
