import CoreGraphics
import UnfoldEngine
import XCTest
@testable import UnfoldMac

private final class FakeInjector: TextInjecting {
    var insertions: [(String, InsertionMode)] = []
    func insert(_ text: String, mode: InsertionMode) { insertions.append((text, mode)) }
}

/// Shared timeline for the tests that assert *which came first* -- a re-post and a tap disable land in
/// different sinks, so neither sink alone can show their order.
private final class OrderLog {
    var entries: [String] = []
}

private final class RepostRecorder {
    var posted: [CGEvent] = []
    var log: OrderLog?
    func record(_ event: CGEvent) {
        posted.append(event)
        log?.entries.append("repost")
    }
}

private func combo(_ trigger: String, parts: [Part], enabled: Bool = true,
                   insertion: InsertionMode = .paste) -> Combo {
    Combo(id: UUID(), trigger: trigger, label: trigger, enabled: enabled,
          parts: parts, insertion: insertion)
}

private func textPart(_ value: String) -> Part { .text(value) }

private func keyEvent(_ virtualKey: Int, down: Bool) -> CGEvent {
    CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(virtualKey), keyDown: down)!
}

// CGEvent is a CF type with no Equatable conformance, so outcomes are inspected structurally and
// events are compared by identity. Do not add `==` to TapOutcome to make assertions shorter.
private func swallowed(_ outcome: TapOutcome) -> Bool {
    if case .swallow = outcome { return true }
    return false
}

private func repostedEvents(_ outcome: TapOutcome) -> [CGEvent] {
    if case .repost(let events, thenPass: _) = outcome { return events }
    return []
}

private func forwardedEvent(_ outcome: TapOutcome) -> CGEvent? {
    switch outcome {
    case .pass(let event): return event
    case .repost(_, thenPass: let event): return event
    case .swallow: return nil
    }
}

final class ExpansionCoordinatorTests: XCTestCase {
    private func subject(_ combos: [Combo])
        -> (ExpansionCoordinator, FakeInjector, RepostRecorder) {
        let injector = FakeInjector()
        let recorder = RepostRecorder()
        let coordinator = ExpansionCoordinator(
            combos: combos,
            injector: injector,
            repost: { recorder.record($0) }
        )
        coordinator.resume()
        return (coordinator, injector, recorder)
    }

    func testPlaceholderCombosAreCountedButNotRegistered() {
        let prompted = combo("citytrip", parts: [.placeholder(.init(id: "city", options: []))])
        let (coordinator, _, _) = subject([combo("addr", parts: [textPart("123 Main St")]), prompted])

        XCTAssertEqual(coordinator.activeCount, 1)
        XCTAssertEqual(coordinator.inactivePlaceholderCount, 1)
        XCTAssertEqual(coordinator.registeredTriggers, ["addr"])
    }

    func testDisabledCombosAppearInNeitherCount() {
        let off = combo("addr", parts: [textPart("123 Main St")], enabled: false)
        let (coordinator, _, _) = subject([off])

        XCTAssertEqual(coordinator.activeCount, 0)
        XCTAssertEqual(coordinator.inactivePlaceholderCount, 0)
    }

    func testATriggerPrefixIsSwallowed() {
        let (coordinator, _, _) = subject([combo("addr", parts: [textPart("123 Main St")])])

        XCTAssertTrue(swallowed(coordinator.handle(.keyDown("a", 0), flags: [],
                                                  original: keyEvent(0, down: true))))
        XCTAssertEqual(coordinator.bufferedCount, 1)
    }

    func testCompletingATriggerInjectsAndForwardsTheDelimiter() {
        let (coordinator, injector, recorder) = subject([combo("add", parts: [textPart("address")])])
        _ = coordinator.handle(.keyDown("a", 0), flags: [], original: keyEvent(0, down: true))
        _ = coordinator.handle(.keyDown("d", 2), flags: [], original: keyEvent(2, down: true))
        _ = coordinator.handle(.keyDown("d", 2), flags: [], original: keyEvent(2, down: true))

        let space = keyEvent(49, down: true)
        XCTAssertTrue(forwardedEvent(coordinator.handle(.keyDown(" ", 49), flags: [],
                                                       original: space)) === space)
        // The plan's `XCTAssertEqual(injector.insertions, [("address", .paste)])` does not compile:
        // a tuple does not conform to Equatable in a generic context. Asserted structurally, the
        // same way this file inspects outcomes.
        XCTAssertEqual(injector.insertions.count, 1)
        XCTAssertEqual(injector.insertions.first?.0, "address")
        XCTAssertEqual(injector.insertions.first?.1, .paste)
        XCTAssertEqual(recorder.posted.count, 0, "a consumed trigger re-posts nothing")
        XCTAssertEqual(coordinator.bufferedCount, 0)
    }

    func testABrokenPrefixRepostsTheOriginalEventsInOrder() {
        // The recorder is captured here, and asserted empty below, on purpose. F3's positional
        // invariant only holds if the coordinator *returns* the released events and the tap's
        // `.repost` arm alone posts them: if `handle` also posted, every broken prefix would be
        // typed twice the moment a real tap is attached. This is that assertion.
        let (coordinator, injector, recorder) = subject([combo("addr", parts: [textPart("123 Main St")])])
        let first = keyEvent(0, down: true)
        let second = keyEvent(2, down: true)
        _ = coordinator.handle(.keyDown("a", 0), flags: [], original: first)
        _ = coordinator.handle(.keyDown("d", 2), flags: [], original: second)

        let z = keyEvent(44, down: true)
        let outcome = coordinator.handle(.keyDown("z", 44), flags: [], original: z)
        let released = repostedEvents(outcome)
        XCTAssertEqual(released.count, 2)
        XCTAssertTrue(released.first === first, "the oldest swallowed event must go back first")
        XCTAssertTrue(released.last === second)
        XCTAssertTrue(forwardedEvent(outcome) === z)
        XCTAssertTrue(injector.insertions.isEmpty)
        XCTAssertTrue(recorder.posted.isEmpty,
                      "handle must return the released events, not post them — the tap owner posts")
    }

    func testABlockingModifierReleasesTheBufferAndPassesTheEvent() {
        let (coordinator, _, _) = subject([combo("addr", parts: [textPart("123 Main St")])])
        let first = keyEvent(0, down: true)
        _ = coordinator.handle(.keyDown("a", 0), flags: [], original: first)

        let commandD = keyEvent(2, down: true)
        let outcome = coordinator.handle(.keyDown("d", 2), flags: .maskCommand, original: commandD)
        XCTAssertTrue(repostedEvents(outcome).first === first)
        XCTAssertTrue(forwardedEvent(outcome) === commandD)
    }

    func testPausedSwallowsNothingAndPassesEverything() {
        let (coordinator, _, _) = subject([combo("addr", parts: [textPart("123 Main St")])])
        let held = keyEvent(0, down: true)
        _ = coordinator.handle(.keyDown("a", 0), flags: [], original: held)

        let releasedByPause = coordinator.pause()
        XCTAssertEqual(releasedByPause.count, 1, "pause must hand back what it was holding")
        XCTAssertTrue(releasedByPause.first === held)
        XCTAssertTrue(coordinator.isPaused)

        let event = keyEvent(2, down: true)
        XCTAssertTrue(forwardedEvent(coordinator.handle(.keyDown("d", 2), flags: [],
                                                       original: event)) === event)
        XCTAssertEqual(coordinator.bufferedCount, 0)
    }

    func testIdleAndFocusChangeBothRepostTheBuffer() {
        let (idleCoordinator, _, _) = subject([combo("addr", parts: [textPart("123 Main St")])])
        let held = keyEvent(0, down: true)
        _ = idleCoordinator.handle(.keyDown("a", 0), flags: [], original: held)
        let released = idleCoordinator.handleIdle()
        XCTAssertTrue(released.first === held)
        XCTAssertEqual(idleCoordinator.bufferedCount, 0)

        let (focusCoordinator, _, _) = subject([combo("addr", parts: [textPart("123 Main St")])])
        let heldToo = keyEvent(0, down: true)
        _ = focusCoordinator.handle(.keyDown("a", 0), flags: [], original: heldToo)
        XCTAssertTrue(focusCoordinator.handleFocusChange().first === heldToo)
    }

    // MARK: - Fix round 1, finding A: the duplication the coordinator sees end to end

    /// The reviewer's sequence driven through the real `handle`: `a`, `d`, a Shift press (which the
    /// tap routes as `.other`), then `d`, `r`, space. The release puts "ad" in the document, so
    /// completing the trigger must NOT also inject the replacement -- together they read
    /// `ad123 Main St`.
    func testAReleasedPrefixIsNotExpandedAgainWhenTheTriggerIsCompletedAfterIt() {
        let (coordinator, injector, _) = subject([combo("addr", parts: [textPart("123 Main St")])])
        _ = coordinator.handle(.keyDown("a", 0), flags: [], original: keyEvent(0, down: true))
        _ = coordinator.handle(.keyDown("d", 2), flags: [], original: keyEvent(2, down: true))
        _ = coordinator.handle(.other, flags: [], original: keyEvent(56, down: true))
        _ = coordinator.handle(.keyDown("d", 2), flags: [], original: keyEvent(2, down: true))
        _ = coordinator.handle(.keyDown("r", 15), flags: [], original: keyEvent(15, down: true))
        let space = keyEvent(49, down: true)
        XCTAssertTrue(forwardedEvent(coordinator.handle(.keyDown(" ", 49), flags: [],
                                                       original: space)) === space)

        XCTAssertTrue(injector.insertions.isEmpty,
                      "the app already holds the released \"ad\"; an expansion now duplicates it")
        XCTAssertEqual(coordinator.bufferedCount, 0)
    }

    // MARK: - Fix round 1, finding C: drains must repost through the marked + paired path

    /// A drain posts outside the tap callback, straight to `post(tap:)`. Posting the bare keydown
    /// means the re-entrant pass sees an unmarked event and can swallow it again, and the target app
    /// believes the key is still held -- both are what `KeystrokeSource.eventsToPost` exists to fix,
    /// so the drains have to go through it rather than around it.
    func testTheIdleDrainRepostsMarkedEventsEachPairedWithItsRelease() {
        let (coordinator, _, recorder) = subject([combo("addr", parts: [textPart("123 Main St")])])
        let held = keyEvent(0, down: true)
        _ = coordinator.handle(.keyDown("a", 0), flags: [], original: held)

        _ = coordinator.handleIdle()

        XCTAssertEqual(recorder.posted.count, 2, "a re-posted keydown must come with its keyup")
        XCTAssertTrue(recorder.posted.first === held)
        XCTAssertTrue(KeystrokeSource.isReposted(held),
                      "an unmarked re-post sails back into the tap and gets swallowed again")
        XCTAssertEqual(recorder.posted.map { $0.type }, [.keyDown, .keyUp], "the key must come up again")
    }

    func testTheFocusChangeDrainRepostsMarkedEventsEachPairedWithItsRelease() {
        let (coordinator, _, recorder) = subject([combo("addr", parts: [textPart("123 Main St")])])
        let first = keyEvent(0, down: true)
        let second = keyEvent(2, down: true)
        _ = coordinator.handle(.keyDown("a", 0), flags: [], original: first)
        _ = coordinator.handle(.keyDown("d", 2), flags: [], original: second)

        _ = coordinator.handleFocusChange()

        XCTAssertEqual(recorder.posted.count, 4, "two released keydowns, each with its synthesized keyup")
        XCTAssertEqual(recorder.posted.map(\.type), [.keyDown, .keyUp, .keyDown, .keyUp],
                       "press and release must alternate, in the order the keys were eaten")
        XCTAssertTrue(recorder.posted.first === first)
        XCTAssertTrue(KeystrokeSource.isReposted(second))
    }

    /// The third drain path, pinned for the half of the contract the original suite never checked: it
    /// asserted what a drain *returned* and never that it *posted*. Every recorder assertion in the
    /// first round said "must be empty", so deleting the drain's post left the whole suite green -- a
    /// drain that only hands events back is a drain a caller that ignores `@discardableResult` turns
    /// into lost keystrokes.
    func testThePauseDrainPostsWhatItReleasedInsteadOfOnlyReturningIt() {
        let (coordinator, _, recorder) = subject([combo("addr", parts: [textPart("123 Main St")])])
        let held = keyEvent(0, down: true)
        _ = coordinator.handle(.keyDown("a", 0), flags: [], original: held)

        _ = coordinator.pause()

        XCTAssertEqual(recorder.posted.count, 2,
                       "a drain outside the tap callback has no one else to post what it released")
        XCTAssertTrue(recorder.posted.first === held)
        XCTAssertTrue(KeystrokeSource.isReposted(held))
        XCTAssertEqual(recorder.posted.map(\.type), [.keyDown, .keyUp])
    }

    // MARK: - Fix round 1, finding D: the ledger and the event FIFO stay in lockstep

    /// `heldEvents` and the router's ledger are twins, and the drain asks the ledger how many events to
    /// hand back. A swallowed keyup is the transition most likely to desync them -- the ledger consumes
    /// a keyup expectation while the FIFO deliberately holds only presses -- so every press eaten here
    /// must still come back on the drain, and nothing may be quietly clamped away.
    func testInterleavedReleasesLeaveEverySwallowedPressToComeBackOnTheDrain() {
        let (coordinator, _, recorder) = subject([combo("addr", parts: [textPart("123 Main St")])])
        let aDown = keyEvent(0, down: true)
        let dDown = keyEvent(2, down: true)
        let secondDDown = keyEvent(2, down: true)
        _ = coordinator.handle(.keyDown("a", 0), flags: [], original: aDown)
        _ = coordinator.handle(.keyUp(0), flags: [], original: keyEvent(0, down: false))
        _ = coordinator.handle(.keyDown("d", 2), flags: [], original: dDown)
        _ = coordinator.handle(.keyUp(2), flags: [], original: keyEvent(2, down: false))
        _ = coordinator.handle(.keyDown("d", 2), flags: [], original: secondDDown)

        XCTAssertEqual(coordinator.bufferedCount, 3,
                       "a swallowed keyup must not cost the FIFO a press the ledger is holding")

        let released = coordinator.pause()
        XCTAssertEqual(released.count, 3, "the drain hands back every press, not the ones it could find")
        XCTAssertTrue(released[0] === aDown)
        XCTAssertTrue(released[1] === dDown)
        XCTAssertTrue(released[2] === secondDDown)
        XCTAssertEqual(coordinator.bufferedCount, 0)
        XCTAssertEqual(recorder.posted.count, 6, "three presses, each paired with its release")
    }

    func testComposedTextJoinsLiteralParts() {
        let signature = combo("sig", parts: [textPart("Best, "), textPart("Robin")])
        let (coordinator, _, _) = subject([signature])
        XCTAssertEqual(coordinator.composedText(for: signature), "Best, Robin")
    }

    // MARK: - Supplemental pins beyond the plan's list

    func testPauseHandingTheBufferOverWithoutRepostingLeavesTheCallerToPost() {
        // `pause(repostingBuffered: false)` exists for a caller that will place the events itself.
        // The pair of assertions is the contract: the events are returned and *not* posted, so the
        // caller owns the repost -- posting both here and there would type the prefix twice.
        let (coordinator, _, recorder) = subject([combo("addr", parts: [textPart("123 Main St")])])
        let held = keyEvent(0, down: true)
        _ = coordinator.handle(.keyDown("a", 0), flags: [], original: held)

        let released = coordinator.pause(repostingBuffered: false)
        XCTAssertEqual(released.count, 1)
        XCTAssertTrue(released.first === held)
        XCTAssertTrue(recorder.posted.isEmpty,
                      "with repostingBuffered false the caller alone posts what pause returns")
        XCTAssertTrue(coordinator.isPaused)
    }

    func testResumeReopensSwallowingAfterAPause() {
        let (coordinator, _, _) = subject([combo("addr", parts: [textPart("123 Main St")])])
        _ = coordinator.pause()
        _ = coordinator.handle(.keyDown("a", 0), flags: [], original: keyEvent(0, down: true))
        XCTAssertEqual(coordinator.bufferedCount, 0, "a paused coordinator holds nothing")

        coordinator.resume()
        XCTAssertTrue(swallowed(coordinator.handle(.keyDown("a", 0), flags: [],
                                                  original: keyEvent(0, down: true))))
        XCTAssertEqual(coordinator.bufferedCount, 1)
    }

    // MARK: - Tap wiring, through the stand-in bridge only
    //
    // attachTap/restartTap are exercised with a `TapBridge` stand-in, exactly as Task 5's retry
    // tests do, so nothing here reaches `CGEvent.tapCreate`/`tapEnable`/`tapIsEnabled`: the ports
    // these tests register are plain mach ports, never taps, and the callbacks never fire.

    /// A stand-in `TapBridge`: its ports are plain mach ports, so attach/detach/restart are exercised
    /// without ever reaching `CGEvent.tapCreate`/`tapEnable`/`tapIsEnabled`.
    private final class BridgeProbe {
        /// How many times `create` was called, whether or not it handed back a port.
        private(set) var creations = 0
        private(set) var enablements = 0
        private(set) var disablements = 0
        private var successes = 0
        /// How many of those calls may hand back a port. Counted per *success*, not per call, because
        /// a test that wants a failed attach followed by a working one must be able to deny the first
        /// attempt without spending the allowance it will need for the second.
        var portCreations = 0
        /// When true, `create` answers nil regardless of the allowance -- a process with no
        /// Accessibility permission.
        var deniesCreate = false
        var log: OrderLog?

        func bridge() -> KeystrokeSource.TapBridge {
            KeystrokeSource.TapBridge(
                create: { [weak self] _, _ in
                    guard let self else { return nil }
                    self.creations += 1
                    guard !self.deniesCreate, self.successes < self.portCreations else { return nil }
                    self.successes += 1
                    var shouldFreeInfo = DarwinBoolean(false)
                    return CFMachPortCreate(kCFAllocatorDefault, nil, nil, &shouldFreeInfo)
                },
                enable: { [weak self] _ in
                    guard let self else { return false }
                    self.enablements += 1
                    return true
                },
                disable: { [weak self] _ in
                    self?.disablements += 1
                    self?.log?.entries.append("disable")
                }
            )
        }
    }

    func testAttachAndDetachDriveTheTapState() {
        let probe = BridgeProbe()
        probe.portCreations = 1
        let (coordinator, _, _) = subject([combo("addr", parts: [textPart("123 Main St")])])

        XCTAssertEqual(coordinator.tapState, .detached)
        XCTAssertTrue(coordinator.attachTap(bridge: probe.bridge()))
        XCTAssertEqual(coordinator.tapState, .live)

        coordinator.detachTap()
        XCTAssertEqual(coordinator.tapState, .detached)
        XCTAssertEqual(probe.disablements, 1, "detach switches the port off before dropping it")
    }

    func testRestartTapReusesTheRegisteredPortInsteadOfCreatingASecondOne() {
        let probe = BridgeProbe()
        probe.portCreations = 1
        let (coordinator, _, _) = subject([combo("addr", parts: [textPart("123 Main St")])])
        XCTAssertTrue(coordinator.attachTap(bridge: probe.bridge()))

        XCTAssertTrue(coordinator.restartTap())
        XCTAssertEqual(probe.creations, 1,
                       "restart() re-enables the registered port; a second tapCreate would strand the first")
        // `creations == 1` alone does not tell `restart()` from a `start()` that answered from its
        // `guard tap == nil` and never touched the port: both leave exactly one creation on the log.
        // The enable count is what separates them -- only the restart path re-enables.
        XCTAssertEqual(probe.enablements, 2, "attach enabled the port once; restart must enable it again")
        XCTAssertEqual(coordinator.tapState, .live)

        coordinator.detachTap()
        XCTAssertFalse(coordinator.restartTap(),
                       "a detached coordinator has no port to restart — and it must not create one behind your back")
        XCTAssertEqual(probe.creations, 1, "the detached restart above created nothing")
    }

    // MARK: - Fix round 1, finding B: detach may not destroy a buffered prefix

    /// `source?.stop()` alone tore the tap down with the prefix still in the ledger, and after that
    /// there is no callback left to post it: the probe's answer was a buffer of one, `detachTap()`,
    /// and the key never returns. Plan 1 residual R4 in its plainest form.
    func testDetachRepostsTheBufferedPrefixBeforeItTearsTheTapDown() {
        let log = OrderLog()
        let probe = BridgeProbe()
        probe.portCreations = 1
        probe.log = log
        let (coordinator, _, recorder) = subject([combo("addr", parts: [textPart("123 Main St")])])
        recorder.log = log
        XCTAssertTrue(coordinator.attachTap(bridge: probe.bridge()))

        let held = keyEvent(0, down: true)
        _ = coordinator.handle(.keyDown("a", 0), flags: [], original: held)
        XCTAssertEqual(coordinator.bufferedCount, 1)

        coordinator.detachTap()

        XCTAssertEqual(coordinator.tapState, .detached)
        XCTAssertEqual(coordinator.bufferedCount, 0, "a detach must leave nothing stranded")
        XCTAssertEqual(recorder.posted.count, 2, "the released keydown goes back with its keyup")
        XCTAssertTrue(recorder.posted.first === held)
        XCTAssertEqual(log.entries, ["repost", "repost", "disable"],
                       "the buffer must be handed back while the tap can still deliver it")
        XCTAssertEqual(probe.disablements, 1)
    }

    // MARK: - Fix round 1, finding F: a failed attach publishes nothing

    /// The reviewer's point is that `start()` returning false is not a state the coordinator may keep
    /// an object for: a dead source in the slot makes `tapState` answer `.disabled` -- "off, and
    /// `start()`/`restartTap()` bring it back" -- for a tap that was never created.
    func testAFailedAttachLeavesNoSourceBehind() {
        let probe = BridgeProbe()
        probe.portCreations = 1
        probe.deniesCreate = true // `create` answers nil: no Accessibility permission, no port.
        let (coordinator, _, _) = subject([combo("addr", parts: [textPart("123 Main St")])])

        XCTAssertFalse(coordinator.attachTap(bridge: probe.bridge()))
        XCTAssertEqual(coordinator.tapState, .detached,
                       "a start that failed must not leave a dead object claiming the slot")

        probe.deniesCreate = false
        XCTAssertTrue(coordinator.attachTap(bridge: probe.bridge()),
                      "a failed attach must not make the next one unable to try again")
        XCTAssertEqual(coordinator.tapState, .live)
        coordinator.detachTap()
    }
}
