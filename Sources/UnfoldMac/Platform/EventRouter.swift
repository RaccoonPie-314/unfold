import CoreGraphics
import Foundation
import UnfoldEngine

public enum RoutedEvent: Equatable {
    case keyDown(Character, Int)
    case keyUp(Int)
    case other
}

/// What the adapter should do with the event in hand.
///
/// There is no "swallow" decision any more. The adapter renders every keystroke and rewrites the
/// trigger on a match, so the router's only job is to say whether the matcher currently has a live
/// candidate and whether a combo should be expanded.
public enum RoutingDecision: Equatable {
    case passThrough
    /// The matcher advanced its candidate on this character. The event still renders.
    case buffered
    case expandThenPass(Combo, [Int])
}

public struct EventRouter {
    private var matcher: Matcher

    public init(matcher: Matcher) {
        self.matcher = matcher
    }

    /// Characters typed since the current candidate started. Already on screen, so exactly this many
    /// must be deleted before a replacement goes in.
    public var typedCount: Int { matcher.buffer.count }

    public var hasLivePrefix: Bool { !matcher.buffer.isEmpty }

    /// Records that a character reached the document, so the boundary reflects the user's screen.
    public mutating func noteRendered(_ character: Character) {
        matcher.noteRendered(character)
    }

    public mutating func route(_ event: RoutedEvent, flags: CGEventFlags) -> RoutingDecision {
        switch event {
        case .other, .keyUp:
            // Keyups matter to nobody now that nothing is held: the old ledger swallowed them to pair
            // with swallowed keydowns, and there are no swallowed keydowns left.
            return .passThrough

        case .keyDown(let character, let code):
            return routeKeyDown(character: character, code: code, flags: flags)
        }
    }

    /// Forgets the candidate and the boundary together. A drain happens on a focus change or after a
    /// pause, so the next word typed must be able to start clean.
    public mutating func forget() {
        matcher.forget()
    }

    private mutating func routeKeyDown(character: Character, code: Int,
                                       flags: CGEventFlags) -> RoutingDecision {
        // A shortcut is not prose. Command/Control/Option keystrokes must not feed the matcher at all.
        guard ModifierGate.mayConsiderExpansion(flags) else { return .passThrough }

        let actions = matcher.feed(character)
        if let combo = actions.compactMap({ action -> Combo? in
            if case .expand(let combo) = action { return combo }
            return nil
        }).first {
            return .expandThenPass(combo, [])
        }
        return hasLivePrefix ? .buffered : .passThrough
    }
}
