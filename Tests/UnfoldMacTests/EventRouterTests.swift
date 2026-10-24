import CoreGraphics
import UnfoldEngine
import XCTest
@testable import UnfoldMac

private func combo(_ trigger: String, _ replacement: String) -> Combo {
    Combo(id: UUID(), trigger: trigger, label: trigger, enabled: true,
          parts: [.text(replacement)], insertion: .paste)
}

final class EventRouterTests: XCTestCase {
    private func router(_ combos: [Combo]) -> EventRouter {
        EventRouter(matcher: Matcher(index: TriggerIndex(combos: combos)))
    }

    func testAnUnrelatedKeyPassesThrough() {
        var subject = router([combo("addr", "123 Main St")])
        XCTAssertEqual(subject.route(.keyDown("z", 44), flags: []), .passThrough)
        XCTAssertEqual(subject.bufferedCount, 0)
    }

    func testATriggerPrefixIsSwallowedAndRecorded() {
        var subject = router([combo("addr", "123 Main St")])
        XCTAssertEqual(subject.route(.keyDown("a", 0), flags: []), .swallowAndRecord)
        XCTAssertEqual(subject.bufferedCount, 1)
    }

    func testACompleteTriggerStillWaitsForADelimiter() {
        var subject = router([combo("add", "address")])
        _ = subject.route(.keyDown("a", 0), flags: [])
        _ = subject.route(.keyDown("d", 2), flags: [])
        XCTAssertEqual(subject.route(.keyDown("d", 2), flags: []), .swallowAndRecord)
    }

    func testADelimiterExpandsAndPassesItselfThrough() {
        let add = combo("add", "address")
        var subject = router([add])
        _ = subject.route(.keyDown("a", 0), flags: [])
        _ = subject.route(.keyDown("d", 2), flags: [])
        _ = subject.route(.keyDown("d", 2), flags: [])

        XCTAssertEqual(subject.route(.keyDown(" ", 49), flags: []), .expandThenPass(add, []))
        XCTAssertEqual(subject.bufferedCount, 0)
    }

    func testABrokenPrefixReleasesWhatItAteBeforePassingTheCurrentKey() {
        var subject = router([combo("addr", "123 Main St")])
        _ = subject.route(.keyDown("a", 0), flags: [])
        _ = subject.route(.keyDown("d", 2), flags: [])

        XCTAssertEqual(subject.route(.keyDown("z", 44), flags: []), .releaseThenPass([0, 2]))
        XCTAssertEqual(subject.bufferedCount, 0)
    }

    func testABlockingModifierReleasesTheBufferAndPassesTheEvent() {
        var subject = router([combo("addr", "123 Main St")])
        _ = subject.route(.keyDown("a", 0), flags: [])

        XCTAssertEqual(subject.route(.keyDown("d", 2), flags: .maskCommand), .releaseThenPass([0]))
    }

    func testKeyUpForASwallowedKeyIsSwallowedTooButUnrelatedKeyUpPasses() {
        var subject = router([combo("addr", "123 Main St")])
        _ = subject.route(.keyDown("a", 0), flags: [])

        XCTAssertEqual(subject.route(.keyUp(0), flags: []), .swallowAndRecord)
        XCTAssertEqual(subject.route(.keyUp(6), flags: []), .passThrough)
    }

    func testIdleDrainReturnsTheBufferInOrderAndClearsIt() {
        var subject = router([combo("addr", "123 Main St")])
        _ = subject.route(.keyDown("a", 0), flags: [])
        _ = subject.route(.keyDown("d", 2), flags: [])

        XCTAssertEqual(subject.drainForIdle(), [0, 2])
        XCTAssertEqual(subject.bufferedCount, 0)
        XCTAssertEqual(subject.drainForIdle(), [])
    }

    func testFocusChangeDrainBehavesLikeIdleDrain() {
        var subject = router([combo("addr", "123 Main St")])
        _ = subject.route(.keyDown("a", 0), flags: [])

        XCTAssertEqual(subject.drainForFocusChange(), [0])
        XCTAssertEqual(subject.bufferedCount, 0)
    }

    func testADrainForIdleLeavesTheMatcherUnableToReExpandTheReleasedPrefix() {
        let addr = combo("addr", "123 Main St")
        var subject = router([addr])
        _ = subject.route(.keyDown("a", 0), flags: [])
        _ = subject.route(.keyDown("d", 2), flags: [])

        XCTAssertEqual(subject.drainForIdle(), [0, 2])

        // The app has already received "ad" from the drain. Finishing the trigger must not
        // now expand it -- the replacement would duplicate the prefix the ledger gave back.
        XCTAssertEqual(subject.route(.keyDown("d", 2), flags: []), .passThrough)
        XCTAssertEqual(subject.route(.keyDown("r", 15), flags: []), .passThrough)
        XCTAssertEqual(subject.route(.keyDown(" ", 49), flags: []), .passThrough,
                       "a drain must discard the matcher's prefix, not keep it live")
    }

    func testADrainForFocusChangeLeavesTheMatcherUnableToReExpandTheReleasedPrefix() {
        var subject = router([combo("add", "address")])
        _ = subject.route(.keyDown("a", 0), flags: [])
        _ = subject.route(.keyDown("d", 2), flags: [])

        XCTAssertEqual(subject.drainForFocusChange(), [0, 2])

        // Same duplication bug via the focus-change drain: "d, space" after the drained
        // "ad" would expand "add" a second time.
        XCTAssertEqual(subject.route(.keyDown("d", 2), flags: []), .passThrough)
        XCTAssertEqual(subject.route(.keyDown(" ", 49), flags: []), .passThrough,
                       "a drain must discard the matcher's prefix, not keep it live")
    }

    // MARK: - Fix round 1, finding A: the two release paths inside `route` had the same bug

    /// The reviewer's repro, verbatim. A real Shift press reaches the router as `.other`, which
    /// released "ad" back to the app while `matcher.buffer` still held it; finishing the trigger then
    /// expanded it, so the document read `ad123 Main St` -- duplicated text, not a missed expansion.
    /// Task 4's drains already clear the matcher; `route`'s own release paths must too.
    func testAnUninterpretableReleaseLeavesTheMatcherUnableToReExpandTheReleasedPrefix() {
        let addr = combo("addr", "123 Main St")
        var subject = router([addr])
        _ = subject.route(.keyDown("a", 0), flags: [])
        _ = subject.route(.keyDown("d", 2), flags: [])

        XCTAssertEqual(subject.route(.other, flags: []), .releaseThenPass([0, 2]))

        // The app has "ad" now. Completing the trigger must not answer it with a second copy.
        XCTAssertEqual(subject.route(.keyDown("d", 2), flags: []), .passThrough)
        XCTAssertEqual(subject.route(.keyDown("r", 15), flags: []), .passThrough)
        XCTAssertEqual(subject.route(.keyDown(" ", 49), flags: []), .passThrough,
                       "a release that hands the prefix back must make the matcher forget it too")
    }

    /// The same duplication through the blocking-modifier release: the guard returns before `feed`,
    /// so the buffer survives the release and the next three keys still spell `addr`.
    func testABlockingModifierReleaseLeavesTheMatcherUnableToReExpandTheReleasedPrefix() {
        let addr = combo("addr", "123 Main St")
        var subject = router([addr])
        _ = subject.route(.keyDown("a", 0), flags: [])
        _ = subject.route(.keyDown("d", 2), flags: [])

        XCTAssertEqual(subject.route(.keyDown("d", 2), flags: .maskCommand), .releaseThenPass([0, 2]))

        XCTAssertEqual(subject.route(.keyDown("d", 2), flags: []), .passThrough)
        XCTAssertEqual(subject.route(.keyDown("r", 15), flags: []), .passThrough)
        XCTAssertEqual(subject.route(.keyDown(" ", 49), flags: []), .passThrough,
                       "a release that hands the prefix back must make the matcher forget it too")
    }

    func testABreakReleasesThreeBufferedKeysInOldestFirstOrder() {
        var subject = router([combo("addr", "123 Main St")])
        _ = subject.route(.keyDown("a", 0), flags: [])
        _ = subject.route(.keyDown("d", 2), flags: [])
        _ = subject.route(.keyDown("d", 2), flags: [])

        // Three leading emits -- the shape of a buffered prefix whose successor also needs
        // releasing. The duplicated keycode 2 pins true FIFO position order, not a set.
        XCTAssertEqual(subject.route(.keyDown("z", 44), flags: []), .releaseThenPass([0, 2, 2]))
        XCTAssertEqual(subject.bufferedCount, 0)
    }

    func testExpansionCarriesNoReleaseBecauseTheTriggerWasConsumed() {
        let add = combo("add", "address")
        var subject = router([add])
        _ = subject.route(.keyDown("a", 0), flags: [])
        _ = subject.route(.keyDown("d", 2), flags: [])
        _ = subject.route(.keyDown("d", 2), flags: [])
        XCTAssertEqual(subject.route(.keyDown(" ", 49), flags: []), .expandThenPass(add, []))
    }

    func testNonKeyEventsPassThrough() {
        var subject = router([combo("addr", "123 Main St")])
        XCTAssertEqual(subject.route(.other, flags: []), .passThrough)
    }

    func testAnUninterpretableKeyReleasesTheBufferRatherThanStrandingIt() {
        var subject = router([combo("addr", "123 Main St")])
        _ = subject.route(.keyDown("a", 0), flags: [])
        _ = subject.route(.keyDown("d", 2), flags: [])

        XCTAssertEqual(subject.route(.other, flags: []), .releaseThenPass([0, 2]))
        XCTAssertEqual(subject.bufferedCount, 0)
    }

    func testAnExpandedTriggerLeavesNothingAwaitingKeyUp() {
        var subject = router([combo("add", "address")])
        _ = subject.route(.keyDown("a", 0), flags: [])
        _ = subject.route(.keyDown("d", 2), flags: [])
        _ = subject.route(.keyDown("d", 2), flags: [])
        _ = subject.route(.keyDown(" ", 49), flags: [])

        XCTAssertEqual(subject.route(.keyUp(2), flags: []), .passThrough,
                       "the keyup of an expanded trigger must not be swallowed")
    }

    func testResetForgetsTheBufferAndThePendingKeyups() {
        var subject = router([combo("addr", "123 Main St")])
        _ = subject.route(.keyDown("a", 0), flags: [])
        subject.reset()

        XCTAssertEqual(subject.bufferedCount, 0)
        XCTAssertEqual(subject.route(.keyUp(0), flags: []), .passThrough,
                       "a keyup for an event the new field never started must not be eaten")
    }
}
