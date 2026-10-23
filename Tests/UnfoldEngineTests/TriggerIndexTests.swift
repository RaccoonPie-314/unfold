import XCTest
@testable import UnfoldEngine

final class TriggerIndexTests: XCTestCase {
    func testRegistersEveryPrefixIncludingTheWholeTrigger() {
        let index = TriggerIndex(combos: [makeCombo("addr")])
        for candidate in ["a", "ad", "add", "addr"] {
            XCTAssertTrue(index.isPrefix(candidate), "`\(candidate)` should be a live prefix")
        }
        XCTAssertFalse(index.isPrefix("addrs"))
        XCTAssertFalse(index.isPrefix(""))
    }

    func testEmptyTriggerIsRejected() {
        let index = TriggerIndex(combos: [makeCombo("")])
        XCTAssertEqual(index.rejections.map(\.problem), [.empty])
        XCTAssertTrue(index.accepted.isEmpty)
    }

    func testWhitespaceTriggerIsRejected() {
        let index = TriggerIndex(combos: [makeCombo("my trigger")])
        XCTAssertEqual(index.rejections.map(\.problem), [.containsWhitespace])
    }

    func testTriggerMustEndWithAWordCharacter() {
        let index = TriggerIndex(combos: [makeCombo("add.")])
        XCTAssertEqual(index.rejections.map(\.problem), [.mustEndWithWordCharacter])
    }

    // `Matcher` can only extend its buffer on word characters, so a trigger with any other
    // character inside it can never be completed by keystrokes: it is accepted, unreachable and
    // reported as active. Shapes like these used to sail through `unfoldctl check` with `0 rejected`.
    func testTriggerContainingANonWordCharacterIsRejected() {
        let unreachable = ["e-mail", "a.b", "@at", "-dash", "x\u{1F600}y", "\u{0591}aleph"]
        for trigger in unreachable {
            let index = TriggerIndex(combos: [makeCombo(trigger)])
            XCTAssertEqual(
                index.rejections.map(\.problem), [.containsNonWordCharacter],
                "`\(trigger)` holds a non-word character the matcher cannot type"
            )
            XCTAssertTrue(index.accepted.isEmpty, "`\(trigger)` must not be accepted")
            XCTAssertNil(index.combo(for: trigger), "`\(trigger)` must not be reachable")
            XCTAssertFalse(index.isPrefix(trigger), "`\(trigger)` must not register as a prefix")
        }
    }

    // A combining mark that arrives as its own keystroke is non-word; one folded into the letter it
    // modifies is part of that letter's grapheme cluster and stays word -- so an NFD-written trigger
    // is legal and an accent-first trigger is not. See `NonLatinScriptTests`.
    func testTriggerMadeOfAStandaloneCombiningMarkIsRejectedWhileAComposedOneIsAccepted() {
        XCTAssertEqual(
            TriggerIndex(combos: [makeCombo("\u{0301}x")]).rejections.map(\.problem),
            [.containsNonWordCharacter]
        )
        let composed = TriggerIndex(combos: [makeCombo("cafe\u{0301}")])
        XCTAssertEqual(composed.rejections, [], "an NFC/NFD `café` trigger is all word characters")
        XCTAssertEqual(composed.accepted.count, 1)
    }

    // `combo(for:)` is an exact lookup, not a longest-prefix search: the matcher asks it only about
    // a buffer it already holds, and answering with a shorter trigger would expand text the user is
    // still typing toward a longer one.
    func testComboForBufferIsAnExactTriggerLookupNotALongestPrefixMatch() {
        let ad = makeCombo("ad", replacement: "one")
        let addr = makeCombo("addr", replacement: "two")
        let index = TriggerIndex(combos: [ad, addr])

        XCTAssertEqual(index.combo(for: "ad"), ad)
        XCTAssertEqual(index.combo(for: "addr"), addr)
        for notATrigger in ["a", "add", "adr", "ddr", "address", ""] {
            XCTAssertNil(index.combo(for: notATrigger), "`\(notATrigger)` is not a trigger")
        }
    }

    func testDuplicateTriggerKeepsFirstOccurrence() {
        let first = makeCombo("add", replacement: "one")
        let second = makeCombo("add", replacement: "two")
        let index = TriggerIndex(combos: [first, second])

        XCTAssertEqual(index.accepted, [first])
        XCTAssertEqual(index.rejections.map(\.problem), [.duplicateTrigger])
        XCTAssertEqual(index.combo(for: "add"), first)
    }

    func testDisabledComboIsUnreachableAndCannotStartAMatch() {
        let off = makeCombo("add", enabled: false)
        let index = TriggerIndex(combos: [off])

        XCTAssertTrue(index.accepted.isEmpty)
        XCTAssertNil(index.combo(for: "add"))
        XCTAssertFalse(index.isPrefix("add"))
    }

    func testDisabledComboDoesNotBlockALaterEnabledComboWithTheSameTrigger() {
        let off = makeCombo("add", replacement: "one", enabled: false)
        let on = makeCombo("add", replacement: "two")
        let index = TriggerIndex(combos: [off, on])

        XCTAssertEqual(index.combo(for: "add"), on)
        XCTAssertEqual(index.accepted, [on])
    }

    func testValidTriggersAreAcceptedInOrder() {
        let index = TriggerIndex(combos: [makeCombo("ad"), makeCombo("add"), makeCombo("addr")])
        XCTAssertEqual(index.accepted.count, 3)
        XCTAssertNotNil(index.combo(for: "ad"))
        XCTAssertNotNil(index.combo(for: "addr"))
    }
}
