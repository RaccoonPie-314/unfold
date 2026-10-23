import CoreGraphics
import Foundation

/// Turns a raw `CGEvent` into the text the system already decided the user typed.
///
/// Ruling R-P2-1: `CGEvent.keyboardGetUnicodeString` returns the payload the active keyboard
/// layout produced, which is exactly what the target app is going to receive. There is
/// deliberately no `UCKeyTranslate` call in this file -- re-translating the key code ourselves
/// would let the tap disagree with the app about which character was typed.
public enum KeyboardDecoder {
    private static let bufferLimit = 16

    /// The full payload the target app will receive. Layouts can produce more than one scalar per
    /// keystroke, so this is the primitive that must not lose information.
    public static func characters(from event: CGEvent) -> String? {
        // This SDK imports the two lengths as Swift `Int` under the label
        // `actualStringLength`, and the buffer as an `UnsafeMutablePointer<UniChar>!`, so the
        // buffer is addressed explicitly rather than through an implicit array conversion.
        var buffer = [UniChar](repeating: 0, count: bufferLimit)
        var length = 0

        buffer.withUnsafeMutableBufferPointer { storage in
            event.keyboardGetUnicodeString(maxStringLength: bufferLimit,
                                           actualStringLength: &length,
                                           unicodeString: storage.baseAddress)
        }

        guard length > 0 else { return nil }
        return String(utf16CodeUnits: buffer, count: min(length, bufferLimit))
    }

    /// The single-character case, which is all the matcher's `Character`-based vocabulary accepts.
    public static func character(from event: CGEvent) -> Character? {
        characters(from: event).flatMap { $0.count == 1 ? $0.first : nil }
    }

    public static func keyCode(from event: CGEvent) -> Int {
        Int(event.getIntegerValueField(.keyboardEventKeycode))
    }
}
