import Foundation

/// Tracks events the tap swallowed, so they can be handed back in the original form.
///
/// Two separate concerns, deliberately: the FIFO of swallowed keydowns awaiting re-post, and the
/// pending keyups -- one expectation per swallowed keydown, counted, not a set of keycodes. A
/// released prefix is only re-inserted correctly if the keyups are eaten too -- otherwise the target
/// app sees "press A, release B" and typing desynchronizes.
///
/// The count is what keeps auto-repeat and double letters (`addr`, two `d` keydowns) honest: with
/// one expectation per keycode, the first keyup eats it and the second leaks, leaving the target app
/// believing a key is still held -- the stuck-key failure this type exists to prevent.
public struct SwallowLedger<Element: Hashable> {
    private var queue: [Element] = []
    private var awaitingKeyUp: [Element: Int] = [:]

    public init() {}

    public var pendingCount: Int { queue.count }

    public mutating func swallow(_ element: Element) {
        queue.append(element)
        awaitingKeyUp[element, default: 0] += 1
    }

    /// True when this keyup belongs to a swallowed keydown and must be swallowed as well.
    /// Consumes one expectation per call, so the keyup of every swallowed keydown is eaten and a
    /// stray repeat beyond that passes through.
    public mutating func expectKeyUp(for element: Element) -> Bool {
        consumeKeyUpExpectation(for: element)
    }

    public mutating func release(_ count: Int) -> [Element] {
        guard count > 0, !queue.isEmpty else { return [] }
        let take = min(count, queue.count)
        let drained = Array(queue[0..<take])
        queue.removeFirst(take)
        // A re-posted keydown's keyup must reach the target app, or the app sees a press that never
        // ends. Release one keyup expectation per drained keydown, leaving the still-buffered
        // duplicates' expectations intact.
        drained.forEach { consumeKeyUpExpectation(for: $0) }
        return drained
    }

    public mutating func releaseAll() -> [Element] {
        let drained = queue
        queue.removeAll()
        awaitingKeyUp.removeAll()
        return drained
    }

    /// Drops everything without returning it. Only valid when the keystrokes are known to be
    /// meaningless -- the user pressed Escape, or the app lost focus mid-trigger.
    public mutating func clear() {
        queue.removeAll()
        awaitingKeyUp.removeAll()
    }

    /// Removes exactly one pending keyup, dropping the key entirely once none are left.
    /// Returns whether an expectation existed for this call to consume -- true even when this was the
    /// last one, since consuming the last keydown's keyup is still a keyup we own. Only `expectKeyUp`
    /// reads it; `release(_:)` drains one per keydown and ignores the answer.
    @discardableResult
    private mutating func consumeKeyUpExpectation(for element: Element) -> Bool {
        guard let waiting = awaitingKeyUp[element], waiting > 0 else { return false }
        if waiting > 1 {
            awaitingKeyUp[element] = waiting - 1
        } else {
            awaitingKeyUp[element] = nil
        }
        return true
    }
}
