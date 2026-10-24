import CoreGraphics
import UnfoldEngine
import XCTest
@testable import UnfoldMac

private final class FakeInjector: TextInjecting {
    var insertions: [(String, InsertionMode)] = []
    func insert(_ text: String, mode: InsertionMode) { insertions.append((text, mode)) }
}

private final class RepostRecorder {
    var posted: [CGEvent] = []
    func record(_ event: CGEvent) { posted.append(event) }
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
            repost: { recorder.posted.append($0) }
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

    private final class BridgeProbe {
        private(set) var creations = 0
        private(set) var enablements = 0
        private(set) var disablements = 0
        var portCreations = 0

        func bridge() -> KeystrokeSource.TapBridge {
            KeystrokeSource.TapBridge(
                create: { [weak self] _, _ in
                    guard let self else { return nil }
                    self.creations += 1
                    guard self.creations <= self.portCreations else { return nil }
                    var shouldFreeInfo = DarwinBoolean(false)
                    return CFMachPortCreate(kCFAllocatorDefault, nil, nil, &shouldFreeInfo)
                },
                enable: { [weak self] _ in
                    guard let self else { return false }
                    self.enablements += 1
                    return true
                },
                disable: { [weak self] _ in self?.disablements += 1 }
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
        XCTAssertEqual(coordinator.tapState, .live)

        coordinator.detachTap()
        XCTAssertFalse(coordinator.restartTap(),
                       "a detached coordinator has no port to restart — and it must not create one behind your back")
        XCTAssertEqual(probe.creations, 1, "the detached restart above created nothing")
    }
}
