import Foundation

public struct TriggerIndex {
    public enum Problem: String, Equatable, CustomStringConvertible {
        case empty
        case containsWhitespace
        case mustEndWithWordCharacter
        case duplicateTrigger

        public var description: String {
            switch self {
            case .empty: return "trigger is empty"
            case .containsWhitespace: return "trigger contains whitespace"
            case .mustEndWithWordCharacter: return "trigger must end with a letter or digit"
            case .duplicateTrigger: return "another enabled combo already uses this trigger"
            }
        }
    }

    public struct Rejection: Equatable {
        public let combo: Combo
        public let problem: Problem
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

    public func combo(for buffer: String) -> Combo? {
        exact[buffer]
    }

    public func isPrefix(_ candidate: String) -> Bool {
        !candidate.isEmpty && prefixes.contains(candidate)
    }

    private static func problem(in trigger: String) -> Problem? {
        if trigger.isEmpty { return .empty }
        if trigger.contains(where: { $0.isWhitespace }) { return .containsWhitespace }
        guard let last = trigger.last, isWordCharacter(last) else { return .mustEndWithWordCharacter }
        return nil
    }
}
