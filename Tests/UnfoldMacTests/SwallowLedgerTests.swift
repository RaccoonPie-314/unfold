import XCTest
@testable import UnfoldMac

final class SwallowLedgerTests: XCTestCase {
    func testReleaseReturnsElementsOldestFirst() {
        var ledger = SwallowLedger<Int>()
        ledger.swallow(11)
        ledger.swallow(12)
        ledger.swallow(13)

        XCTAssertEqual(ledger.release(2), [11, 12])
        XCTAssertEqual(ledger.pendingCount, 1)
        XCTAssertEqual(ledger.release(1), [13])
        XCTAssertEqual(ledger.pendingCount, 0)
    }

    func testReleaseAsksForMoreThanExistAndReturnsWhatItCan() {
        var ledger = SwallowLedger<Int>()
        ledger.swallow(7)

        XCTAssertEqual(ledger.release(3), [7])
        XCTAssertEqual(ledger.pendingCount, 0)
    }

    func testReleaseFromEmptyLedgerIsEmpty() {
        var ledger = SwallowLedger<Int>()
        XCTAssertEqual(ledger.release(4), [])
        XCTAssertEqual(ledger.releaseAll(), [])
    }

    func testKeyUpIsExpectedOnlyOncePerSwallowedElement() {
        var ledger = SwallowLedger<Int>()
        ledger.swallow(5)

        XCTAssertTrue(ledger.expectKeyUp(for: 5))
        XCTAssertFalse(ledger.expectKeyUp(for: 5), "a second keyup for the same element must pass through")
    }

    func testKeyUpForSomethingNeverSwallowedPassesThrough() {
        var ledger = SwallowLedger<Int>()
        XCTAssertFalse(ledger.expectKeyUp(for: 99))
    }

    func testReleaseAllDrainsEverythingAndLeavesItEmpty() {
        var ledger = SwallowLedger<String>()
        ledger.swallow("a")
        ledger.swallow("b")

        XCTAssertEqual(ledger.releaseAll(), ["a", "b"])
        XCTAssertEqual(ledger.pendingCount, 0)
        XCTAssertFalse(ledger.expectKeyUp(for: "a"))
    }

    func testReleaseZeroClaimsNothing() {
        var ledger = SwallowLedger<Int>()
        ledger.swallow(1)

        XCTAssertEqual(ledger.release(0), [])
        XCTAssertEqual(ledger.pendingCount, 1)
    }

    func testClearDiscardsWithoutReturning() {
        var ledger = SwallowLedger<Int>()
        ledger.swallow(1)
        ledger.swallow(2)
        ledger.clear()

        XCTAssertEqual(ledger.pendingCount, 0)
        XCTAssertEqual(ledger.release(2), [])
    }

    func testReleasingAnElementClearsItsPendingKeyUp() {
        var ledger = SwallowLedger<Int>()
        ledger.swallow(1)
        ledger.swallow(2)

        XCTAssertEqual(ledger.release(1), [1])
        XCTAssertFalse(ledger.expectKeyUp(for: 1), "its keydown went back, so its keyup must too")
        XCTAssertTrue(ledger.expectKeyUp(for: 2), "still buffered, still swallowed")
    }

    func testTwoSwallowsOfTheSameElementExpectTwoKeyups() {
        var ledger = SwallowLedger<Int>()
        ledger.swallow(2)
        ledger.swallow(2)

        XCTAssertTrue(ledger.expectKeyUp(for: 2))
        XCTAssertTrue(ledger.expectKeyUp(for: 2), "the second swallow's keyup must also be swallowed")
        XCTAssertFalse(ledger.expectKeyUp(for: 2), "a third keyup must pass through")
    }

    func testPartialReleaseKeepsTheRemainingElementsKeyUpExpectation() {
        var ledger = SwallowLedger<Int>()
        ledger.swallow(2)
        ledger.swallow(2)

        XCTAssertEqual(ledger.release(1), [2])
        XCTAssertTrue(ledger.expectKeyUp(for: 2), "one is still buffered, so its keyup is still ours")
        XCTAssertFalse(ledger.expectKeyUp(for: 2))
    }

    func testClearAlsoDropsKeyUpExpectations() {
        var ledger = SwallowLedger<Int>()
        ledger.swallow(1)
        ledger.clear()

        XCTAssertFalse(ledger.expectKeyUp(for: 1))
    }
}
