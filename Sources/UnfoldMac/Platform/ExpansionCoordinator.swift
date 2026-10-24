import CoreGraphics
import Foundation
import UnfoldEngine

/// Owns the matcher (through `EventRouter`), the swallow ledger's event half, the tap, pause, and
/// teardown -- the single type Task 7's menu bar item sits on top of.
///
/// Three obligations shape this file, all from Plan 1's residuals:
///  - **R4** -- every drain hands what it released back to its caller *and* posts it, because a
///    drain that fires outside the tap callback has no one else to post it. Nothing discards a
///    keystroke except the one arm that replaces it with expansion text (see `.expandThenPass`).
///  - **R3** -- a focus change releases and re-posts the buffered prefix before the matcher state
///    goes away. Honest consequence, stated where it happens: after the reset the first trigger
///    typed into the newly focused field needs one more character before it fires. Accepted and
///    fail-safe, not hidden.
///  - **F3** -- the positional invariant (leading actions are re-posts of eaten events in the order
///    they were eaten; the last action concerns the event in hand) is kept visible in comments at
///    each hop: router, this file, tap.
///
/// Threading decision (from Task 5's review of `KeystrokeSource.restart()`): **thread confinement,
/// not a lock.** The tap is attached to the main thread's run loop -- enforced by `precondition` in
/// `attachTap` -- and CoreGraphics delivers the callback on the thread whose run loop hosts the
/// source, so the callback, Task 7's menu actions, `pause`/`resume`, the drains, and `restartTap`
/// all serialize on the main run loop instead of racing. `restart()` mutates the re-enable budget
/// and is reached only through `restartTap()`, which demands the same thread. What this does *not*
/// solve: there is no lock anywhere in this file, so calling any of these methods from another
/// thread is still a data race -- misuse the attach-time precondition catches at attach, not
/// mid-session; and re-entrant delivery of a re-posted event runs `handle` on the main thread while
/// the outer `handle` is still on the stack, which is safe only because the `repostMark` guard in
/// `KeystrokeSource` answers it before any coordinator state is touched.

public final class ExpansionCoordinator {
    /// The tap's state as the menu should render it. `isActive` alone can read true on a tap that
    /// has stopped retrying and false on one a person can bring back, so this pairs it with the
    /// budget's answer, exactly as `KeystrokeSource`'s contract requires.
    public enum TapState: Equatable {
        /// No tap is attached; only `attachTap()` changes this.
        case detached
        case live
        /// Off, but the budget will ride out the next timeout. `start()`/`restartTap()` bring it back.
        case disabled
        /// Off, and the budget gave up: only `restartTap()` brings it back.
        case givenUp
    }

    public let combos: [Combo]
    public let active: [Combo]
    public let inactivePlaceholderCount: Int

    private var router: EventRouter
    private let injector: TextInjecting
    private let repost: (CGEvent) -> Void

    /// The exact events behind the router's ledger, in the same order. The two are popped in
    /// lockstep; every transition below keeps `heldEvents.count == router.bufferedCount` or
    /// restores it, and a divergence is a bug in this file rather than a condition to tolerate.
    private var heldEvents: [CGEvent] = []

    private var source: KeystrokeSource?
    public private(set) var isPaused = true

    public init(combos: [Combo], injector: TextInjecting = Injector(),
                repost: @escaping (CGEvent) -> Void = { $0.post(tap: .cgSessionEventTap) }) {
        let live = combos.filter(\.enabled)
        // Only text-only combos are registered: a placeholder combo needs a prompt the keyboard
        // layer cannot show, so it counts as inactive instead of expanding into half a template.
        let promptable = live.filter { combo in
            combo.parts.allSatisfy { if case .text = $0 { return true }; return false }
        }
        self.combos = combos
        self.active = promptable
        self.inactivePlaceholderCount = live.count - promptable.count
        self.injector = injector
        self.repost = repost
        self.router = EventRouter(matcher: Matcher(index: TriggerIndex(combos: promptable)))
    }

    public var activeCount: Int { active.count }
    public var registeredTriggers: Set<String> { Set(active.map(\.trigger)) }
    public var bufferedCount: Int { heldEvents.count }

    public var tapState: TapState {
        guard let source else { return .detached }
        if source.isActive { return .live }
        return source.reEnableBudget.hasGivenUp ? .givenUp : .disabled
    }

    /// The tap's decision function. Everything here runs on the thread that attached the tap,
    /// re-entrantly at most once per re-posted event (see the class doc and `KeystrokeSource.repostMark`).
    public func handle(_ event: RoutedEvent, flags: CGEventFlags, original: CGEvent) -> TapOutcome {
        guard !isPaused else { return .pass(original) }

        switch router.route(event, flags: flags) {
        case .passThrough:
            return .pass(original)

        case .swallowAndRecord:
            // Only the keydown is held. A keyup is swallowed to keep the target app from seeing a
            // press it never saw the start of, and it must not be re-posted on its own.
            if case .keyDown = event { heldEvents.append(original) }
            return .swallow

        case .releaseThenPass(let codes):
            // F3 at the coordinator hop: `codes` names events eaten earlier, so they lead the
            // outcome in the order they were eaten, and `original` -- the event in hand -- trails
            // them. We deliberately do NOT post the released events here: an outcome produced
            // inside the tap callback is posted by the callback's `.repost` arm, and posting in
            // both places would type the released characters twice. The drains are the opposite
            // case -- they run outside the callback with no one else to post -- so `drainRouter`
            // does post.
            let events = take(count: codes.count)
            return .repost(events, thenPass: original)

        case .expandThenPass(let combo, let codes):
            precondition(codes.isEmpty,
                         "the matcher never emits a release before an expansion; see Plan 1 rule 3")
            _ = take(count: codes.count)
            // Everything still buffered belongs to the trigger being replaced, so it is dropped,
            // not reposted. This is the one place the buffer is discarded rather than returned --
            // R4 is not violated because the keystrokes were not lost: they were *answered*, by
            // the expansion text the injector is about to place.
            heldEvents.removeAll()
            injector.insert(composedText(for: combo), mode: combo.insertion)
            return .repost([], thenPass: original)
        }
    }

    /// Stop matching, and release what was being held.
    ///
    /// `repostingBuffered` defaults to true, which keeps R4 whole for every caller that ignores the
    /// return value: the events are back in the session either way. Pass false only when the caller
    /// takes ownership of posting what it gets back -- posting both there and here would type the
    /// prefix twice.
    @discardableResult
    public func pause(repostingBuffered: Bool = true) -> [CGEvent] {
        isPaused = true
        return drainRouter(repostingBuffered: repostingBuffered)
    }

    public func resume() {
        isPaused = false
    }

    @discardableResult
    public func handleIdle() -> [CGEvent] { drainRouter() }

    /// Plan 1 residual R3: a focus change must release the buffer, never discard it, and R4 keeps
    /// the released events visible to the caller even after the drain has posted them. The release
    /// happens first -- `drainForFocusChange()` empties the ledger before resetting the matcher --
    /// so the prefix is back in the document while the matcher state is torn down.
    ///
    /// Honest consequence: the reset closes the word boundary, so the first trigger typed into the
    /// newly focused field needs one more character before it expands. Accepted, fail-safe,
    /// deliberately not hidden. No `router.reset()` follows the drain: both drains already reset
    /// the matcher internally, and a second clear only invites a later lazy call that would discard
    /// a legitimately buffered new prefix.
    @discardableResult
    public func handleFocusChange() -> [CGEvent] {
        drainRouter(forFocusChange: true)
    }

    public func composedText(for combo: Combo) -> String {
        combo.parts.reduce(into: "") { result, part in
            if case .text(let value) = part { result += value }
        }
    }

    // MARK: - The tap

    /// Attach the system-wide tap and switch it on. Production call sites use this no-bridge form;
    /// `CGEvent.tapCreate`, `tapEnable` and `tapIsEnabled` stay confined to
    /// `KeystrokeSource.coreGraphicsTapBridge`. Starting a real tap is Task 7's gated decision --
    /// nothing in tests takes this path.
    @discardableResult
    public func attachTap() -> Bool {
        attachTap(bridge: KeystrokeSource.coreGraphicsTapBridge)
    }

    /// The seam Task 5's retry tests use, restated here for the wiring: a test injects a stand-in
    /// `TapBridge` whose ports are plain mach ports, so attach/detach/restart are exercised on this
    /// type without ever reaching the tap API. Only tests pass a bridge.
    @discardableResult
    internal func attachTap(bridge: KeystrokeSource.TapBridge) -> Bool {
        // Threading decision, enforced where it is made: the tap is hosted on the main run loop, so
        // the callback and every state mutation below serialize there instead of racing. Attaching
        // from another thread would put the callback on that thread's loop while the menu's
        // pause/restart calls arrive on main -- the exact race Task 5's review refused to hand back.
        precondition(Thread.isMainThread,
                     "the tap must be attached on the main thread; see ExpansionCoordinator's threading decision")
        if source == nil {
            source = KeystrokeSource(handler: { [weak self] event, flags, original in
                self?.handle(event, flags: flags, original: original) ?? .pass(original)
            }, bridge: bridge)
        }
        return source?.start() ?? false
    }

    public func detachTap() {
        source?.stop()
        source = nil
    }

    /// The documented way back from a latched re-enable budget -- `KeystrokeSource.restart()`, never
    /// `start()`, which cannot reach a latched tap whose port is still registered. Same thread as
    /// the attach, therefore same thread as the callback: the budget mutation and a mid-flight
    /// timeout-recovery cannot interleave (see the class doc for what this does not solve).
    @discardableResult
    public func restartTap() -> Bool {
        precondition(Thread.isMainThread,
                     "restart must run on the thread that hosts the tap")
        return source?.restart() ?? false
    }

    // MARK: - Buffer plumbing

    /// Drain the router, post what it released unless told not to, and return it (R4).
    ///
    /// Both router drains reset the matcher internally, which is why no caller here follows up
    /// with `router.reset()`; the focus half is named so the two paths stay distinguishable even
    /// while their bodies match.
    @discardableResult
    private func drainRouter(repostingBuffered: Bool = true,
                             forFocusChange: Bool = false) -> [CGEvent] {
        // Take against the ledger's own count before draining it: the events and the codes are
        // lockstep twins, and this is the one place that reads `router.bufferedCount`.
        let events = take(count: router.bufferedCount)
        if forFocusChange { _ = router.drainForFocusChange() } else { _ = router.drainForIdle() }
        // Drains that are not happening inside the tap callback have no one else to post them, so
        // this does. The `.releaseThenPass` path out of `handle` does NOT post -- the tap owner does,
        // and doing both would type the released characters twice.
        if repostingBuffered { events.forEach(repost) }
        return events
    }

    private func take(count: Int) -> [CGEvent] {
        guard count > 0, !heldEvents.isEmpty else { return [] }
        let take = min(count, heldEvents.count)
        let events = Array(heldEvents[0..<take])
        heldEvents.removeFirst(take)
        return events
    }
}
