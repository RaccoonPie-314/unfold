import CoreGraphics
import Foundation

public enum ModifierGate {
    /// Blocking modifiers mean the user is invoking a shortcut, not typing prose, so nothing in
    /// the sequence may be swallowed.
    private static let blocking: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate]

    public static func mayConsiderExpansion(_ flags: CGEventFlags) -> Bool {
        flags.isDisjoint(with: blocking)
    }

    /// The only events that carry a character worth feeding to the matcher.
    public static func isCharacterProducing(flags: CGEventFlags, type: CGEventType) -> Bool {
        type == .keyDown && mayConsiderExpansion(flags)
    }
}
