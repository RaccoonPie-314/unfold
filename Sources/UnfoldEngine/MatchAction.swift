import Foundation

public enum MatchAction: Equatable {
    /// Send this character to the target app verbatim.
    case emit(Character)
    /// Suppress the keystroke event; it belongs to a possible trigger.
    case swallow
    /// The buffer completed a trigger: insert it and stop suppressing.
    case expand(Combo)
}

func isWordCharacter(_ character: Character) -> Bool {
    character.isLetter || character.isNumber
}
