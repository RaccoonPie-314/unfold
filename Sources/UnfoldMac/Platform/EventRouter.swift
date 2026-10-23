import CoreGraphics
import Foundation
import UnfoldEngine

/// A keystroke as the router sees it: the decoded character plus the keycode the tap must act on,
/// the keycode alone for a release, or nothing the decoder could reduce to text.
///
/// Deliberately free of `CGEvent`. Task 5 owns the translation between these and real events, so the
/// whole routing decision -- the only place product logic meets swallowing -- is testable without
/// CoreGraphics state, without accessibility permissions, and without a live tap.
public enum RoutedEvent: Equatable {
    case keyDown(Character, Int)
    case keyUp(Int)
    case other
}

/// What the tap should do with the event in hand, plus the keycodes to re-post first, in order.
///
/// The arrays are keycode lists, not characters: a re-post is a hardware event, and the app needs the
/// same keycode it was originally eaten with. The order matters -- the oldest eaten key goes back
/// first, or the released prefix arrives scrambled.
public enum RoutingDecision: Equatable {
    case passThrough
    case swallowAndRecord
    case releaseThenPass([Int])
    case expandThenPass(Combo, [Int])
}

public struct EventRouter {
    private var matcher: Matcher
    private var ledger = SwallowLedger<Int>()

    public init(matcher: Matcher) {
        self.matcher = matcher
    }

    public var bufferedCount: Int { ledger.pendingCount }

    public mutating func route(_ event: RoutedEvent, flags: CGEventFlags) -> RoutingDecision {
        switch event {
        case .other:
            // Added during Task 3's review. A key the decoder could not reduce to one character --
            // a multi-grapheme payload, a refused oversize payload, anything undecoded -- is a break
            // in the typing sequence. Passing it through while a partial prefix stays buffered
            // strands those characters: the app receives this key first and the old prefix re-posted
            // after it. Release in order, then let this one through.
            let stranded = ledger.releaseAll()
            return stranded.isEmpty ? .passThrough : .releaseThenPass(stranded)
        case .keyUp(let code):
            return ledger.expectKeyUp(for: code) ? .swallowAndRecord : .passThrough
        case .keyDown(let character, let code):
            return routeKeyDown(character: character, code: code, flags: flags)
        }
    }

    public mutating func drainForIdle() -> [Int] { ledger.releaseAll() }

    public mutating func drainForFocusChange() -> [Int] { ledger.releaseAll() }

    /// Forgets the half-typed trigger and the word boundary together. The coordinator drains and
    /// re-posts before calling this (Plan 1 residuals R3 and R4), so nothing is lost here -- but the
    /// next field genuinely starts clean, which is why a trigger typed as the very first keystroke
    /// after a focus change needs one more character before it expands.
    public mutating func reset() {
        matcher.reset()
        ledger.clear()
    }

    private mutating func routeKeyDown(character: Character, code: Int,
                                       flags: CGEventFlags) -> RoutingDecision {
        // A blocking modifier means this is a shortcut, not prose. Hand back everything we were
        // holding before deciding anything else, so Cmd+anything is never assembled from eaten keys.
        guard ModifierGate.mayConsiderExpansion(flags) else {
            let released = ledger.releaseAll()
            return released.isEmpty ? .passThrough : .releaseThenPass(released)
        }

        let actions = matcher.feed(character)

        // Plan 1's F3 invariant, relied on here: the LAST action concerns the event in hand, and
        // every LEADING `.emit` is a re-post of a character eaten earlier, in order.
        var expanded: Combo?
        var releasedCodes: [Int] = []
        for action in actions.dropLast() {
            switch action {
            case .expand(let combo): expanded = combo
            case .emit: if let next = ledger.release(1).first { releasedCodes.append(next) }
            case .swallow: break
            }
        }

        if let combo = expanded {
            // The trigger's own events are consumed by the expansion, and its keyups must be
            // allowed through afterwards.
            ledger.clear()
            return .expandThenPass(combo, releasedCodes)
        }

        if actions.last == .swallow {
            ledger.swallow(code)
            return .swallowAndRecord
        }

        return releasedCodes.isEmpty ? .passThrough : .releaseThenPass(releasedCodes)
    }
}
