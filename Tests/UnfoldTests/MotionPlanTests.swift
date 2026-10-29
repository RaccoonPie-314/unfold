import XCTest
@testable import Unfold

/// The motion contract as data. Every rule corrected in review is an assertion here, so a
/// regression is a failing test rather than "i cant tell if anything animated".
final class MotionPlanTests: XCTestCase {
    private let required: [TransitionID] = [.rowInsert, .rowRemove, .selectionMorph, .paneReveal,
                                            .statusMorph, .promptPresent, .promptDismiss]

    func testEveryNamedTransitionExists() {
        for id in required { XCTAssertNotNil(MotionPlan.lookup(id), "\(id) is missing") }
        XCTAssertEqual(MotionPlan.all.count, required.count, "an undeclared transition slipped in")
    }

    func testDurationsStayInThePerceivedBand() {
        for t in MotionPlan.all {
            XCTAssertGreaterThanOrEqual(t.duration, 0.15, "\(t.id) is too fast to perceive")
            XCTAssertLessThanOrEqual(t.duration, 0.32, "\(t.id) makes people wait")
        }
    }

    /// The curve that failed before spent 76% of its change by 45 ms and read as nothing. A control
    /// point below 0.30 on the first x is the shape of that failure.
    func testNoCurveIsFrontLoadedPastTheApprovedShape() {
        for t in MotionPlan.all {
            if case .easeOut(let x1, _, let x2, _) = t.curve {
                XCTAssertGreaterThanOrEqual(x1, 0.30, "\(t.id) starts too steeply")
                XCTAssertLessThanOrEqual(x2, 0.75, "\(t.id) ends too steeply")
            }
        }
    }

    /// Opacity-only transitions are what got reported as "there is no animation". The enum cannot
    /// express an opacity-only geometry, so this guards the enum itself from a future `.fade`.
    func testEveryTransitionMovesGeometry() {
        for t in MotionPlan.all {
            switch t.geometry {
            case .scaleFromGap, .collapseToGap, .growFromEdge, .positionCrossfade, .symbolMorph:
                break
            }
        }
    }

    func testSpringsAreDampedEnoughToSettleWithoutBouncing() {
        for t in MotionPlan.all {
            if case .spring(let damping, let response) = t.curve {
                XCTAssertGreaterThan(damping, 0.7, "\(t.id) overshoots")
                XCTAssertLessThanOrEqual(damping, 1.0, "\(t.id) overshoots")
                XCTAssertGreaterThan(response, 0.15, "\(t.id)")
                XCTAssertLessThan(response, 0.6, "\(t.id)")
            }
        }
    }
}
