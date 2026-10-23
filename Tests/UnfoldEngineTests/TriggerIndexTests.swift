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

    func testValidTriggersAreAcceptedInOrder() {
        let index = TriggerIndex(combos: [makeCombo("ad"), makeCombo("add"), makeCombo("addr")])
        XCTAssertEqual(index.accepted.count, 3)
        XCTAssertNotNil(index.combo(for: "ad"))
        XCTAssertNotNil(index.combo(for: "addr"))
    }
}
