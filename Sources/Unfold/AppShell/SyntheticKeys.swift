import CoreGraphics
import Foundation

/// Real keystrokes, posted from inside the app.
///
/// Nothing outside a trusted process can produce a key event this app's own tap will see: `CGEventPost`
/// from an untrusted shell is dropped, and accessibility-driven typing produces no events at all. So the
/// tests the app runs on itself type through this file.
///
/// Everything here is non-blocking -- nothing sleeps. A `usleep` between two posts would stall the main
/// thread, which is the thread that hosts the tap, and macOS disables a tap whose callback cannot run.
/// A harness that switches the tap off in order to test it measures nothing.
enum SyntheticKeys {
    private static let deleteKeyCode = 51
    private static let aKeyCode = 0
    private static let cKeyCode = 8
    private static let lKeyCode = 37
    private static let escapeKeyCode = 53

    /// Types text as unmarked key events, so the tap decodes them exactly like a person's fingers.
    /// `gap` is the inter-key interval and it is the variable under test: a rewrite that only survives
    /// a slow typist is not a rewrite that works.
    ///
    /// `repeats` holds a key down at the given character index: macOS answers a hold with extra keydowns
    /// carrying the auto-repeat flag and one keyup at the end, which is the shape a fast double-tap of
    /// the same letter makes. `addr` and `add` both contain `dd`, so this is not exotic typing.
    static func type(_ text: String, gap: TimeInterval = 0.04, repeats: [Int: Int] = [:],
                     completion: @escaping () -> Void = {}) {
        let characters = Array(text)
        type(characters, at: 0, gap: gap, repeats: repeats, completion: completion)
    }

    static func selectAll() {
        postPair(keyCode: aKeyCode, flags: .maskCommand)
    }

    /// A real backspace, not the scalar.
    static func backspace() {
        postPair(keyCode: deleteKeyCode, flags: [])
    }

    static func controlC() {
        postPair(keyCode: cKeyCode, flags: .maskControl)
    }

    /// Focuses a browser's address bar. A second text surface with a completely different input stack
    /// is the point -- an expander that only works in Cocoa text views is not working.
    static func focusAddressBar() {
        postPair(keyCode: lKeyCode, flags: .maskCommand)
    }

    static func escape() {
        postPair(keyCode: escapeKeyCode, flags: [])
    }

    private static func type(_ characters: [Character], at index: Int, gap: TimeInterval,
                             repeats: [Int: Int], completion: @escaping () -> Void) {
        guard index < characters.count else { completion(); return }
        post(character: characters[index], heldRepeats: repeats[index] ?? 0)
        DispatchQueue.main.asyncAfter(deadline: .now() + gap) {
            type(characters, at: index + 1, gap: gap, repeats: repeats, completion: completion)
        }
    }

    private static func post(character: Character, heldRepeats: Int = 0) {
        // A backspace in the script means the key, not the scalar -- that is what a person pressing
        // delete to fix a mistake actually sends.
        if character == "\u{08}" {
            postPair(keyCode: deleteKeyCode, flags: [])
            return
        }
        let source = CGEventSource(stateID: .combinedSessionState)
        let units = Array(String(character).utf16)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        down?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
        up?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
        // A `.combinedSessionState` source carries whatever modifiers are down right now, and the
        // first run arrived with Command attached -- which the modifier gate then correctly ignored.
        // A test that types must not pretend to hold a modifier.
        down?.flags = []
        up?.flags = []
        down?.post(tap: .cgSessionEventTap)
        for _ in 0..<heldRepeats {
            guard let repeatDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
            else { continue }
            repeatDown.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            // 0x400 is `kCGKeyboardEventAutorepeat`; it has no named member on CGEventFlags.
            repeatDown.flags = CGEventFlags(rawValue: 0x400)
            repeatDown.post(tap: .cgSessionEventTap)
        }
        up?.post(tap: .cgSessionEventTap)
    }

    private static func postPair(keyCode: Int, flags: CGEventFlags) {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(keyCode), keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cgSessionEventTap)
        up?.post(tap: .cgSessionEventTap)
    }
}
