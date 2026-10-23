import Foundation

public struct TriggerIndex: Sendable {
    public enum Problem: String, Equatable, Sendable, CustomStringConvertible {
        case empty
        case containsWhitespace
        case mustEndWithWordCharacter
        case containsNonWordCharacter
        case duplicateTrigger

        public var description: String {
            switch self {
            case .empty: return "trigger is empty"
            case .containsWhitespace: return "trigger contains whitespace"
            case .mustEndWithWordCharacter: return "trigger must end with a letter or digit"
            case .containsNonWordCharacter: return "trigger contains a character the matcher cannot type"
            case .duplicateTrigger: return "another enabled combo already uses this trigger"
            }
        }
    }

    public struct Rejection: Equatable, Sendable {
        public let combo: Combo
        public let problem: Problem

        public init(combo: Combo, problem: Problem) {
            self.combo = combo
            self.problem = problem
        }
    }

    public private(set) var accepted: [Combo] = []
    public private(set) var rejections: [Rejection] = []

    private var exact: [String: Combo] = [:]
    private var prefixes: Set<String> = []

    public init(combos: [Combo]) {
        for combo in combos where combo.enabled {
            if let problem = TriggerIndex.problem(in: combo.trigger) {
                rejections.append(Rejection(combo: combo, problem: problem))
                continue
            }
            if exact[combo.trigger] != nil {
                rejections.append(Rejection(combo: combo, problem: .duplicateTrigger))
                continue
            }

            accepted.append(combo)
            exact[combo.trigger] = combo

            var consumed: [Character] = []
            for character in combo.trigger {
                consumed.append(character)
                prefixes.insert(String(consumed))
            }
        }
    }

    /// The trigger the delimiter path expands, and nothing else: this is an exact lookup, not a
    /// longest-prefix search. Answering with a shorter trigger would expand text the user is still
    /// typing toward a longer one.
    public func combo(for buffer: String) -> Combo? {
        exact[buffer]
    }

    public func isPrefix(_ candidate: String) -> Bool {
        !candidate.isEmpty && prefixes.contains(candidate)
    }

    /// Ordered so each reason stays the specific one: whitespace is also a non-word character, and a
    /// trigger that ends on one ends on that character rather than on the one before it.
    private static func problem(in trigger: String) -> Problem? {
        if trigger.isEmpty { return .empty }
        if trigger.contains(where: { $0.isWhitespace }) { return .containsWhitespace }
        guard let last = trigger.last, isWordCharacter(last) else { return .mustEndWithWordCharacter }
        // `Matcher` can only extend its buffer on word characters, so anything else anywhere inside
        // a trigger makes it permanently unreachable: accepted, reported active, never expandable.
        // A combining mark folded into the letter it modifies is part of that letter's cluster and
        // does not count; a mark that arrives as its own keystroke does.
        if trigger.contains(where: { !isWordCharacter($0) }) { return .containsNonWordCharacter }
        return nil
    }
}
