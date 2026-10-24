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
/// solve: the tap is attached on the main thread, and `pause`, `handleIdle`, `handleFocusChange` (all
/// three funnel through `drainRouter`, which asserts it) plus `attachTap`/`restartTap` refuse any other
/// thread -- what is left unguarded is `handle` and `resume`, so calling *those* from another thread is
/// still a data race the preconditions do not see; and re-entrant delivery of a re-posted event runs
/// `handle` on the main thread while the outer `handle` is still on the stack, which is safe only
/// because the `repostMark` guard in `KeystrokeSource` answers it before any coordinator state is
/// touched.

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

    /// Why `attachTap()` refused to create a tap. Published rather than returned as a bare `false`
    /// so a menu can say *why* expansion did not start, not only that it did not.
    public enum TapRefusalReason: Equatable {
        case accessibilityNotTrusted

        public var message: String {
            switch self {
            case .accessibilityNotTrusted:
                return "Accessibility permission is not granted"
            }
        }
    }

    public let combos: [Combo]
    public let active: [Combo]
    public let inactivePlaceholderCount: Int

    private var router: EventRouter
    private let injector: TextInjecting
    private let repost: (CGEvent) -> Void
    /// Where the deferred expansion work runs. Production defers to the next run-loop turn so the
    /// tap callback returns before anything is posted; tests pass an inline closure to stay
    /// deterministic without spinning the run loop.
    private let perform: (@escaping () -> Void) -> Void

    /// The one permission question `UnfoldMac` can ask without importing `ApplicationServices`.
    /// The default is `false` on purpose: a composition root that forgets to inject a predicate
    /// fails closed, so the forgotten call site cannot create a system-wide tap. Task 7's shell
    /// injects `PermissionFlow.isTrusted`; the gate itself now lives in `attachTap()`.
    private let isTrusted: () -> Bool

    /// Set when `attachTap()` refuses, cleared when it succeeds. Read by the menu/host so a refusal
    /// carries a reason; `tapState` alone cannot distinguish "untrusted" from "not asked yet".
    public private(set) var tapRefusalReason: TapRefusalReason?


    private var source: KeystrokeSource?
    public private(set) var isPaused = true

    public init(combos: [Combo], injector: TextInjecting = Injector(),
                repost: @escaping (CGEvent) -> Void = { $0.post(tap: .cgSessionEventTap) },
                isTrusted: @escaping () -> Bool = { false },
                perform: @escaping (@escaping () -> Void) -> Void = { DispatchQueue.main.async(execute: $0) }) {
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
        self.isTrusted = isTrusted
        self.perform = perform
        self.router = EventRouter(matcher: Matcher(index: TriggerIndex(combos: promptable)))
    }

    public var activeCount: Int { active.count }
    public var registeredTriggers: Set<String> { Set(active.map(\.trigger)) }

    /// Diagnostics for the status window. Without these the app is unfalsifiable from the outside:
    /// "no expansion" looks identical whether permission is missing, the tap is dead, or the tap is
    /// fine and nothing matched. These three counts separate those cases.
    public private(set) var keystrokesSeen = 0
    public private(set) var lastEventAt: Date?
    public private(set) var lastRouting: String?
    public private(set) var lastExpansion: String?
    public private(set) var lastExpansionAt: Date?

    public var tapState: TapState {
        guard let source else { return .detached }
        if source.isActive { return .live }
        return source.reEnableBudget.hasGivenUp ? .givenUp : .disabled
    }

    /// The live counterpart to `tapState`, for the status line that must not rest on a cache.
    ///
    /// `tapState` reports what the last attach/re-enable attempt observed. This asks the source's held
    /// port whether the tap is enabled *now*, so a silently invalidated tap is visible while
    /// `tapState` still says `.live`. With no source there is no port, so the answer is false -- and
    /// reading never creates one.
    public var isTapEnabled: Bool { source?.isTapEnabled ?? false }

    /// The tap's decision function. Everything here runs on the thread that attached the tap,
    /// re-entrantly at most once per re-posted event (see the class doc and `KeystrokeSource.repostMark`).
    public func handle(_ event: RoutedEvent, flags: CGEventFlags, original: CGEvent) -> TapOutcome {
        // Counted before the pause check so the status window can prove the tap is alive even while
        // expansion is paused -- that is exactly the moment the distinction matters.
        keystrokesSeen += 1
        lastEventAt = Date()
        let outcome = decide(event, flags: flags, original: original)
        trace(event, flags, outcome)
        return outcome
    }

    /// One line per event, so a failed first run can be diagnosed from a file instead of a guessing
    /// game. Bounded by truncation rather than rotation: this is bring-up instrumentation.
    private func trace(_ event: RoutedEvent, _ flags: CGEventFlags, _ outcome: TapOutcome) {
        let summary: String
        switch event {
        case .keyDown(let character, let code):
            summary = "down '\(character)' u+\(character.unicodeScalars.first.map { String($0.value, radix: 16) } ?? "?") code=\(code)"
        case .keyUp(let code):
            summary = "up code=\(code)"
        case .other:
            summary = "other"
        }
        let decision: String
        switch outcome {
        case .pass: decision = "pass"
        case .swallow: decision = "SWALLOW"
        case .repost(let events, thenPass: _): decision = "repost(\(events.count))"
        }
        lastRouting = "\(summary) → \(decision) candidate=\(router.typedCount)"
        appendTrace("\(lastRouting) flags=\(flags.rawValue)\n")
    }

    private func appendTrace(_ line: String) {
        let path = "/tmp/unfold-events.log"
        guard let data = line.data(using: .utf8) else { return }
        if let handle = FileHandle(forWritingAtPath: path) {
            if handle.seekToEndOfFile() > 400_000 {
                try? handle.truncate(atOffset: 0)
                handle.seek(toFileOffset: 0)
            }
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }

    private func decide(_ event: RoutedEvent, flags: CGEventFlags, original: CGEvent) -> TapOutcome {
        guard !isPaused else { return .pass(original) }

        // Measured before routing: on an expansion the router clears the buffer, and this is how many
        // characters are already sitting on screen waiting to be replaced.
        let renderedCount = router.typedCount

        switch router.route(event, flags: flags) {
        case .passThrough, .buffered:
            // Only a keystroke that actually produced text counts as rendered. A shortcut does not:
            // ⌘A arrives as `.keyDown("a")` with Command held, and recording that as the last
            // character made the boundary think a word was in progress -- so select-all (or undo,
            // copy, paste) made the next `addr` silently unmatchable.
            if case .keyDown(let character, _) = event,
               ModifierGate.mayConsiderExpansion(flags) {
                router.noteRendered(character)
            }
            return .pass(original)

        case .expandThenPass(let combo, _):
            // The delimiter is swallowed: it is re-typed after the replacement so the space or
            // punctuation the user pressed still lands, in the right order.
            let closing = delimiter(in: event)
            // Tell the matcher what the document ends with once the expansion has run. Without this
            // it believes the last character typed was the trigger's final letter -- a word character
            // -- so the *next* word starts mid-word and never matches. That is why expansion worked
            // exactly once: the first trigger poisoned the boundary for every one after it.
            if let closing {
                router.noteRendered(closing)
            }
            scheduleExpansion(combo, deleting: renderedCount, delimiter: closing)
            return .swallow
        }
    }

    private func delimiter(in event: RoutedEvent) -> Character? {
        if case .keyDown(let character, _) = event { return character }
        return nil
    }

    /// Erase the typed trigger, insert the replacement, then re-type the delimiter.
    ///
    /// Deferred to the next run-loop turn so the tap callback returns before anything is posted --
    /// posting from inside the callback would re-enter it. The posted events are marked, so the tap
    /// short-circuits them instead of matching its own output.
    private func scheduleExpansion(_ combo: Combo, deleting count: Int, delimiter: Character?) {
        let text = composedText(for: combo)
        lastExpansion = text
        lastExpansionAt = Date()

        perform { [injector] in
            injector.deleteBackward(count)
            injector.insert(text, mode: combo.insertion)
            if let delimiter {
                injector.typeLiteral(String(delimiter))
            }
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
    ///
    /// The gate is the injected `isTrusted` predicate, checked inside the bridge-taking overload so
    /// every caller passes through it. A refusal returns false, publishes `tapRefusalReason`, and
    /// creates no port, no source, and no run-loop source.
    ///
    /// `@discardableResult` was dropped during Task 6's review (finding F): whether the tap came up is
    /// the answer Task 7 has to render, and a call site that ignores it is the bug.
    public func attachTap() -> Bool {
        attachTap(bridge: KeystrokeSource.coreGraphicsTapBridge)
    }

    /// The seam Task 5's retry tests use, restated here for the wiring: a test injects a stand-in
    /// `TapBridge` whose ports are plain mach ports, so attach/detach/restart are exercised on this
    /// type without ever reaching the tap API. Only tests pass a bridge -- which is why this stays
    /// `internal`: widening it would hand production a way to install a stand-in tap.
    internal func attachTap(bridge: KeystrokeSource.TapBridge) -> Bool {
        // Threading decision, enforced where it is made: the tap is hosted on the main run loop, so
        // the callback and every state mutation below serialize there instead of racing. Attaching
        // from another thread would put the callback on that thread's loop while the menu's
        // pause/restart calls arrive on main -- the exact race Task 5's review refused to hand back.
        precondition(Thread.isMainThread,
                     "the tap must be attached on the main thread; see ExpansionCoordinator's threading decision")
        // Finding 1: the trust gate belongs here, not in the menu. Before this line the only refusal
        // lived one layer up, so any other caller could create a system-wide tap in an untrusted
        // process. Refusing before the source slot is touched also means an untrusted call cannot
        // revive a source this coordinator is already holding.
        guard isTrusted() else {
            tapRefusalReason = .accessibilityNotTrusted
            return false
        }
        tapRefusalReason = nil
        if let source {
            // A source this coordinator already published keeps its slot: its `start()` answers from
            // the port it registered, and discarding it here would strand a live tap.
            return source.start()
        }
        // Finding F: publish only a source that observably started. A failed `start()` used to leave
        // the dead object in the slot, and `tapState` then answered `.disabled` -- "off, and
        // `start()`/`restartTap()` bring it back" -- for a tap that was never created at all. Local
        // here, it is released on the failure path and the next attach tries again from clean.
        let candidate = KeystrokeSource(handler: { [weak self] event, flags, original in
            self?.handle(event, flags: flags, original: original) ?? .pass(original)
        }, bridge: bridge)
        guard candidate.start() else { return false }
        source = candidate
        return true
    }

    /// The documented way back from a latched re-enable budget -- `KeystrokeSource.restart()`, never
    /// `start()`, which cannot reach a latched tap whose port is still registered. Same thread as
    /// the attach, therefore same thread as the callback: the budget mutation and a mid-flight
    /// timeout-recovery cannot interleave (see the class doc for what this does not solve).
    public func restartTap() -> Bool {
        precondition(Thread.isMainThread,
                     "restart must run on the thread that hosts the tap")
        return source?.restart() ?? false
    }

    /// Tear the tap down without losing a keystroke.
    ///
    /// Finding B (Task 6 review), and Plan 1 residual R4 in its plainest form: `source?.stop()` on its
    /// own destroyed whatever the ledger still held. With no callback left, nothing could re-post it --
    /// the reviewer's probe was a buffer of one, `detachTap()`, and the key never came back. The drain
    /// runs first, while the tap is still up to deliver what it posts, and `pause()` is the drain that
    /// already owns that contract: release, mark, pair with the synthesized keyup, post, hand back.
    ///
    /// Detach leaves the coordinator paused, which is how it was built: without a tap there is nothing
    /// to feed, and `attachTap()` deliberately does not resume -- Task 7 decides when expansion is on.
    public func detachTap() {
        // R4 in its plainest form (finding B): stop last. `pause()` is the drain that already owns
        // this contract -- release the ledger, mark each event, pair it with its synthesized keyup,
        // post -- and it runs while the tap is still enabled, so the re-posts go through a live
        // callback and out to the target app instead of into a source this method is about to drop.
        // Reading `source?.stop()` as the whole of detach is what lost the reviewer's buffered key.
        _ = pause()
        source?.stop()
        source = nil
    }

    // MARK: - Buffer plumbing

    /// Forgets the candidate. Nothing is held any more -- every keystroke rendered the moment it was
    /// typed -- so a drain has no events to hand back; its only job is to make the next word start
    /// clean after a focus change, a pause, or a long idle gap.
    @discardableResult
    private func drainRouter(repostingBuffered: Bool = true,
                             forFocusChange: Bool = false) -> [CGEvent] {
        precondition(Thread.isMainThread,
                     "a drain must run on the thread that hosts the tap: pause(), handleIdle() and "
                     + "handleFocusChange() all reach this line, and none of them is guarded elsewhere")
        router.forget()
        return []
    }
}
