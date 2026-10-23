import CoreGraphics
import Foundation

/// Turns a raw `CGEvent` into the text the system already decided the user typed.
///
/// Ruling R-P2-1: `CGEvent.keyboardGetUnicodeString` returns the payload the active keyboard
/// layout produced, which is exactly what the target app is going to receive. There is
/// deliberately no `UCKeyTranslate` call in this file -- re-translating the key code ourselves
/// would let the tap disagree with the app about which character was typed.
public enum KeyboardDecoder {
    /// Hard ceiling on the UTF-16 payload one keystroke may carry.
    ///
    /// `CGEventKeyboardGetUnicodeString` clamps `actualStringLength` to `maxStringLength`, so a
    /// fixed-size buffer silently truncates an over-wide payload -- mid-surrogate-pair truncation
    /// decodes to U+FFFD with no signal. The header documents the way out: called with a NULL
    /// string and a max length of 0, the function "still returns the actual count of Unicode
    /// characters in the event" without writing anything. We read the true length first, then
    /// allocate exactly that, so no truncation can occur by construction.
    ///
    /// The ceiling is the explicit failure mode for everything else. No credible layout emits
    /// more than a few dozen units per keystroke -- a skin-tone ZWJ family, the widest realistic
    /// grapheme, is 19 -- so a payload beyond 64 units means a corrupt or hostile event. Refusing
    /// it with `nil` is honest ("this event carries nothing worth matching"); trimming it would
    /// type half an emoji into the user's document. The value must be raised deliberately, never
    /// worked around with a trim.
    static let maxUnicodePayloadUnits = 64

    /// The full payload the target app will receive. Layouts can produce more than one scalar per
    /// keystroke, so this is the primitive that must not lose information.
    public static func characters(from event: CGEvent) -> String? {
        // Pass 1 (documented in the header): the true length, no buffer written, so nothing can be
        // clamped away. Both calls below keep the lengths as Swift `Int` under the
        // `actualStringLength` label and address the buffer explicitly rather than through the
        // implicit array-to-pointer conversion Swift is phasing out.
        var length = 0
        event.keyboardGetUnicodeString(maxStringLength: 0,
                                       actualStringLength: &length,
                                       unicodeString: nil)

        guard length > 0, length <= maxUnicodePayloadUnits else { return nil }

        // Pass 2: allocate exactly `length` units. A mismatch between the two passes means the
        // event lied about its own payload; fail closed with nil rather than decode a surprise.
        var buffer = [UniChar](repeating: 0, count: length)
        var written = 0
        buffer.withUnsafeMutableBufferPointer { storage in
            event.keyboardGetUnicodeString(maxStringLength: length,
                                           actualStringLength: &written,
                                           unicodeString: storage.baseAddress)
        }
        guard written == length else { return nil }
        return String(utf16CodeUnits: buffer, count: written)
    }

    /// The single-character case, which is all the matcher's `Character`-based vocabulary accepts.
    public static func character(from event: CGEvent) -> Character? {
        characters(from: event).flatMap { $0.count == 1 ? $0.first : nil }
    }

    public static func keyCode(from event: CGEvent) -> Int {
        Int(event.getIntegerValueField(.keyboardEventKeycode))
    }
}
