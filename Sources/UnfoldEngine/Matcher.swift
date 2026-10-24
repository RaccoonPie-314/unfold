import Foundation

public struct Matcher: Sendable {
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

    /// Tears the machine down for the adapter -- a tap disable, a focus change, a cancelled prompt --
    /// without losing a keystroke. Whatever the buffer holds is handed back through the same release
    /// path `releasePending()` uses, and the word boundary is left exactly where that release puts
    /// it. Clearing `lastEmitted` here would fabricate a boundary out of nothing, and `p`, `reset()`,
    /// `a d d ␣` would expand `add` inside a word -- which rule 6 forbids.
    @discardableResult
    public mutating func reset() -> [MatchAction] {
        releasePending()
    }

    /// Emits whatever is buffered without expanding. The adapter calls this when typing
    /// goes idle, when focus changes, and when the user pauses expansion, so a swallowed
    /// prefix can never be lost. `reset()` drains through here.
    public mutating func releasePending() -> [MatchAction] {
        let pending = buffer
        buffer = ""
        if let last = pending.last { lastEmitted = last }
        return pending.map { MatchAction.emit($0) }
    }

    /// A full teardown: nothing buffered, and the next keystroke starts a new word.
    ///
    /// Distinct from `reset()` on purpose. `reset()` keeps the boundary where the released text puts
    /// it, which is right when the same field keeps being typed into. `forget()` is for a drain that
    /// follows a focus change or the app being paused -- the released characters went to the *old*
    /// field, so letting the boundary stay closed there means the next word typed in the new field
    /// can never match. That was a live bug: after any app switch, `addr ` stopped expanding until a
    /// space or punctuation was typed first.
    public mutating func forget() {
        buffer = ""
        lastEmitted = nil
    }

    /// Tell the machine a character reached the document.
    ///
    /// The adapter renders every keystroke now -- it no longer swallows a prefix -- so the boundary
    /// must follow what the user actually sees. Without this the engine's `lastEmitted` would lag at
    /// the last *emitted* character and `atBoundary` would answer questions about text that is no
    /// longer the most recent thing in the field.
    public mutating func noteRendered(_ character: Character) {
        lastEmitted = character
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
