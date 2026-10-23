import Foundation

/// The engine's output vocabulary, one array per `Matcher.feed(_:)` call.
///
/// ## The positional contract
///
/// `MatchAction` cannot itself say which action concerns the keystroke the adapter is holding, so
/// the ordering carries that meaning and the adapter must read it this way:
///
/// - **The final action concerns the event in hand.** It is `.swallow` (the engine took it),
///   `.emit(that same character)` (it is passed through), or `.emit(that same character)` following
///   an expansion. A `feed` result never ends with `.expand`.
/// - **Every action before it concerns characters swallowed earlier**, in the order they were
///   swallowed: either the buffer released verbatim as `.emit`s, or the single `.expand(combo)` that
///   consumed the buffer -- which is why the trigger itself never has to be deleted from the document.
///
/// The adapter posts the leading actions first, then handles the last one against the event in hand.
/// It never re-posts a character that is still in the engine's hands, and it never synthesises a
/// keystroke for something the event in hand already represents. Telling those two apart with a
/// `case repost(Character)` on the enum belongs to Plan 2, which owns the adapter.
public enum MatchAction: Equatable, Sendable {
    /// Send this character to the target app verbatim.
    case emit(Character)
    /// Suppress the keystroke event; it belongs to a possible trigger.
    case swallow
    /// The buffer completed a trigger: insert it and stop suppressing.
    case expand(Combo)
}

/// The one definition of "word character" the whole engine shares: a Unicode letter or digit.
/// Everything else -- space, punctuation, Return, Tab, emoji, a combining mark on its own -- is a
/// delimiter. `TriggerIndex` refuses triggers the matcher could never reach with this, and `Matcher`
/// uses it to decide whether a keystroke extends the buffer or fires the delimiter path.
///
/// The input unit is Swift's `Character`, an extended grapheme cluster: a mark folded into the letter
/// it modifies travels inside that letter, and one that arrives as its own event is a delimiter.
public func isWordCharacter(_ character: Character) -> Bool {
    character.isLetter || character.isNumber
}
