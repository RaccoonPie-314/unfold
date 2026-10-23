import Foundation

/// Tracks events the tap swallowed, so they can be handed back in the original form.
///
/// Two separate concerns, deliberately: the FIFO of swallowed keydowns awaiting re-post, and the
/// set of keycodes whose matching keyup must also be swallowed. A released prefix is only
/// re-inserted correctly if the keyups are eaten too -- otherwise the target app sees "press A,
/// release B" and typing desynchronizes.
public struct SwallowLedger<Element: Hashable> {
    private var queue: [Element] = []
    private var awaitingKeyUp: Set<Element> = []

    public init() {}

    public var pendingCount: Int { queue.count }

    public mutating func swallow(_ element: Element) {
        queue.append(element)
        awaitingKeyUp.insert(element)
    }

    /// True when this keyup belongs to a swallowed keydown and must be swallowed as well.
    /// Consumes the expectation so a stray repeat of the same key passes through.
    public mutating func expectKeyUp(for element: Element) -> Bool {
        awaitingKeyUp.remove(element) != nil
    }

    public mutating func release(_ count: Int) -> [Element] {
        guard count > 0, !queue.isEmpty else { return [] }
        let take = min(count, queue.count)
        let drained = Array(queue[0..<take])
        queue.removeFirst(take)
        // A re-posted keydown's keyup must reach the target app, or the app sees a press that never
        // ends. Releasing an element always clears its pending keyup.
        drained.forEach { awaitingKeyUp.remove($0) }
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
}
