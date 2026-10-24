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
            //
            // Fixed during Task 6's review (finding A): the release alone duplicated the user's text.
            // `releaseAll()` hands "ad" back to the app, and a matcher still holding "ad" then
            // expands the finished trigger on top of it -- `ad123 Main St`. Task 4's drains learned
            // the same lesson; a release reached from inside `route` is the same case, so the
            // discarded `reset()` actions are the characters `releaseAll()` just returned.
            let stranded = ledger.releaseAll()
            matcher.reset()
            return stranded.isEmpty ? .passThrough : .releaseThenPass(stranded)
        case .keyUp(let code):
            return ledger.expectKeyUp(for: code) ? .swallowAndRecord : .passThrough
        case .keyDown(let character, let code):
            return routeKeyDown(character: character, code: code, flags: flags)
        }
    }

    /// Releases everything the ledger holds and makes the matcher forget the prefix with it.
    ///
    /// Added during Task 4's review: releasing only the ledger left `matcher.buffer` holding the
    /// prefix the drain had just handed back, so finishing the trigger expanded it a second time --
    /// the app received the re-posted "ad" *and* the full replacement, duplicating the user's text.
    /// Discarding `matcher.reset()`'s release actions is deliberate: those characters are the same
    /// ones `releaseAll()` already returned to the caller.
    public mutating func drainForIdle() -> [Int] {
        let released = ledger.releaseAll()
        matcher.reset()
        return released
    }

    public mutating func drainForFocusChange() -> [Int] {
        let released = ledger.releaseAll()
        matcher.reset()
        return released
    }

    /// Forgets the half-typed trigger and the word boundary together. The drains are now
    /// self-contained -- each clears the matcher alongside the ledger -- so a coordinator no longer
    /// has to remember a `reset()` after every drain to avoid re-expanding a released prefix
    /// (Plan 1 residuals R3 and R4). The next field genuinely starts clean, which is why a trigger
    /// typed as the very first keystroke after a focus change needs one more character before it
    /// expands.
    public mutating func reset() {
        matcher.reset()
        ledger.clear()
    }

    private mutating func routeKeyDown(character: Character, code: Int,
                                       flags: CGEventFlags) -> RoutingDecision {
        // A blocking modifier means this is a shortcut, not prose. Hand back everything we were
        // holding before deciding anything else, so Cmd+anything is never assembled from eaten keys.
        //
        // The guard returns before `feed`, so this key never reaches the matcher -- and finding A's
        // bug was exactly that the released prefix stayed in `matcher.buffer` while the ledger was
        // emptied. The next keys then completed the trigger and expanded it on top of the text the
        // release had already put in the document.
        guard ModifierGate.mayConsiderExpansion(flags) else {
            let released = ledger.releaseAll()
            matcher.reset()
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
