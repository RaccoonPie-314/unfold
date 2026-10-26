import CoreGraphics
import UnfoldEngine
import XCTest
@testable import UnfoldMac

private func combo(_ trigger: String, _ replacement: String) -> Combo {
    Combo(id: UUID(), trigger: trigger, label: trigger, enabled: true,
          parts: [.text(replacement)], insertion: .paste)
}

private func router(_ combos: [Combo]) -> EventRouter {
    EventRouter(matcher: Matcher(index: TriggerIndex(combos: combos)))
}

/// The router no longer holds or swallows anything. It reports whether the matcher has a live
/// candidate and whether a combo completed; the adapter renders every keystroke either way. These
/// tests pin that contract -- the earlier `swallowAndRecord` / `releaseThenPass` model is gone.
final class EventRouterTests: XCTestCase {
    /// The scenario a hand-correction creates: the user deletes what they typed and starts the word
    /// again. Without the reset the matcher still believes the last thing on screen was a letter, so the
    /// retyped word is treated as the middle of one and never matches.
    func testAnEditClearsTheCandidateAndReopensTheBoundary() {
        var subject = router([combo("addr", "123 Main St")])
        _ = subject.route(.keyDown("a", 0), flags: [])
        _ = subject.route(.keyDown("d", 2), flags: [])
        _ = subject.route(.keyDown("r", 15), flags: [])
        XCTAssertTrue(subject.hasLivePrefix == false, "'adr' stopped matching on its own")

        XCTAssertEqual(subject.route(.edit(51), flags: []), .passThrough)
        XCTAssertFalse(subject.hasLivePrefix)
        XCTAssertEqual(subject.route(.keyDown("a", 0), flags: []), .buffered,
                       "the next keystroke starts a fresh word")
    }

    func testAnUnrelatedKeyPassesThroughWithoutACandidate() {
        var subject = router([combo("addr", "123 Main St")])
        XCTAssertEqual(subject.route(.keyDown("z", 44), flags: []), .passThrough)
        XCTAssertFalse(subject.hasLivePrefix)
    }

    func testATriggerLetterStartsACandidateButStillRenders() {
        var subject = router([combo("addr", "123 Main St")])
        XCTAssertEqual(subject.route(.keyDown("a", 0), flags: []), .buffered)
        XCTAssertEqual(subject.typedCount, 1)
    }

    func testTheDelimiterCompletesTheTrigger() {
        let addr = combo("addr", "123 Main St")
        var subject = router([addr])
        _ = subject.route(.keyDown("a", 0), flags: [])
        _ = subject.route(.keyDown("d", 2), flags: [])
        _ = subject.route(.keyDown("d", 2), flags: [])
        _ = subject.route(.keyDown("r", 15), flags: [])
        XCTAssertEqual(subject.typedCount, 4)

        XCTAssertEqual(subject.route(.keyDown(" ", 49), flags: []), .expandThenPass(addr, []))
        XCTAssertEqual(subject.typedCount, 0, "the candidate is consumed by the expansion")
    }

    func testABrokenCandidatePassesThroughAndKeepsTypingTextual() {
        var subject = router([combo("addr", "123 Main St")])
        _ = subject.route(.keyDown("a", 0), flags: [])
        _ = subject.route(.keyDown("z", 44), flags: [])

        XCTAssertEqual(subject.route(.keyDown("d", 2), flags: []), .passThrough)
        XCTAssertFalse(subject.hasLivePrefix)
    }

    func testABlockingModifierNeverFeedsTheMatcher() {
        var subject = router([combo("addr", "123 Main St")])
        XCTAssertEqual(subject.route(.keyDown("a", 0), flags: .maskCommand), .passThrough)
        XCTAssertFalse(subject.hasLivePrefix)
        XCTAssertEqual(subject.typedCount, 0)
    }

    func testKeyUpsAndOtherEventsPassThrough() {
        var subject = router([combo("addr", "123 Main St")])
        XCTAssertEqual(subject.route(.keyUp(0), flags: []), .passThrough)
        XCTAssertEqual(subject.route(.other, flags: []), .passThrough)
    }

    func testForgetClearsTheCandidateAndTheBoundary() {
        var subject = router([combo("addr", "123 Main St")])
        _ = subject.route(.keyDown("a", 0), flags: [])
        XCTAssertTrue(subject.hasLivePrefix)

        subject.forget()
        XCTAssertFalse(subject.hasLivePrefix)

        // After a focus change the next word must be able to start a candidate from scratch.
        XCTAssertEqual(subject.route(.keyDown("a", 0), flags: []), .buffered)
    }

    func testABoundaryClosedByAWordCharacterBlocksACandidate() {
        var subject = router([combo("addr", "123 Main St")])
        subject.noteRendered("p")           // typing inside a word
        XCTAssertEqual(subject.route(.keyDown("a", 0), flags: []), .passThrough)

        subject.noteRendered(" ")           // a delimiter opens the boundary
        XCTAssertEqual(subject.route(.keyDown("a", 0), flags: []), .buffered)
    }
}
