import Foundation

public struct Matcher {
    private let index: TriggerIndex
    /// The swallowed prefix still held back from the document: the trailing run of
    /// characters that could still complete a trigger, or "" when nothing is pending.
    public private(set) var buffer: String = ""

    /// The last character known to have reached the target document. `nil` means
    /// nothing has been typed yet, which counts as a word boundary.
    private var lastEmitted: Character?

    public init(index: TriggerIndex) {
        self.index = index
    }

    public mutating func feed(_ character: Character) -> [MatchAction] {
        if isWordCharacter(character) {
            return feedWord(character)
        }
        return feedDelimiter(character)
    }

    public mutating func reset() {
        buffer = ""
        lastEmitted = nil
    }

    /// Emits whatever is buffered without expanding. The adapter calls this when typing
    /// goes idle, when focus changes, and when the user pauses expansion, so a swallowed
    /// prefix can never be lost.
    public mutating func releasePending() -> [MatchAction] {
        let pending = buffer
        buffer = ""
        if let last = pending.last { lastEmitted = last }
        return pending.map { MatchAction.emit($0) }
    }

    private var atBoundary: Bool {
        guard let lastEmitted else { return true }
        return !isWordCharacter(lastEmitted)
    }

    private mutating func feedWord(_ character: Character) -> [MatchAction] {
        let candidate = buffer + String(character)

        if buffer.isEmpty {
            guard atBoundary, index.isPrefix(candidate) else {
                lastEmitted = character
                return [.emit(character)]
            }
            buffer = candidate
            return [.swallow]
        }

        if index.isPrefix(candidate) {
            buffer = candidate
            return [.swallow]
        }

        return releaseBufferThenReconsider(character)
    }

    private mutating func feedDelimiter(_ character: Character) -> [MatchAction] {
        if let combo = index.combo(for: buffer) {
            buffer = ""
            lastEmitted = character
            return [.expand(combo), .emit(character)]
        }

        if buffer.isEmpty {
            lastEmitted = character
            return [.emit(character)]
        }

        return releaseBufferThenReconsider(character)
    }

    /// Emits the swallowed characters verbatim so nothing is lost, then decides the
    /// current character from an empty buffer. Because the released buffer ended in a
    /// word character, the boundary check makes `added` emit rather than expand.
    private mutating func releaseBufferThenReconsider(_ character: Character) -> [MatchAction] {
        let pending = buffer
        buffer = ""
        var actions = pending.map { MatchAction.emit($0) }
        if let last = pending.last { lastEmitted = last }
        actions.append(contentsOf: feed(character))
        return actions
    }
}
