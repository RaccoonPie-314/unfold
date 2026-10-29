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

    /// The contract as an exact table, because a band this wide passes any plausible transposition of the
    /// real numbers and the id-to-curve-kind mapping is otherwise unpinned.
    func testEachTransitionIsExactlyAsSpecified() {
        let expected: [TransitionID: (duration: Double, curve: Curve, ramp: Double)] = [
            .rowInsert: (0.26, .spring(damping: 0.85, response: 0.28), 0.2),
            .rowRemove: (0.22, .easeOut(0.33, 1, 0.68, 1), 0.2),
            .selectionMorph: (0.20, .easeOut(0.33, 1, 0.68, 1), 0.2),
            .paneReveal: (0.28, .spring(damping: 0.85, response: 0.30), 0.2),
            .statusMorph: (0.24, .easeOut(0.33, 1, 0.68, 1), 0.2),
            .promptPresent: (0.22, .spring(damping: 0.85, response: 0.26), 0.2),
            .promptDismiss: (0.18, .easeOut(0.33, 1, 0.68, 1), 0.2),
        ]
        XCTAssertEqual(Set(MotionPlan.all.map(\.id)), Set(TransitionID.allCases),
                       "the table and the enum have drifted apart")
        for t in MotionPlan.all {
            guard let e = expected[t.id] else {
                XCTFail("\(t.id) has no row in the expected table"); continue
            }
            XCTAssertEqual(t.duration, e.duration, accuracy: 0.0001, "\(t.id) duration")
            XCTAssertEqual(t.curve, e.curve, "\(t.id) curve")
            XCTAssertEqual(t.opacityRamp, e.ramp, accuracy: 0.0001, "\(t.id) ramp")
            XCTAssert(t.opacityRamp > 0 && t.opacityRamp <= 0.25,
                      "\(t.id) ramp \(t.opacityRamp) lets opacity carry the motion")
        }
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

    /// The band test above reads the x control points and discards the y pair as `_`, yet `y1` and `y2`
    /// are what set how much of the change is spent early. All four are also required to lie in [0, 1] at
    /// runtime by `CAMediaTimingFunction`, so an out-of-range value is a crash waiting for Task 10.
    /// Ruling Z's other half -- sampling the solved progress at 45 ms -- is held out: see the fix-round
    /// note. Its threshold fails on the approved durations, and neither the data nor the threshold may
    /// be bent here.
    func testEaseOutControlPointsStayInsideTheUnitSquare() {
        for t in MotionPlan.all {
            guard case .easeOut(let x1, let y1, let x2, let y2) = t.curve else { continue }
            for (label, value) in [("x1", x1), ("y1", y1), ("x2", x2), ("y2", y2)] {
                XCTAssertGreaterThanOrEqual(value, 0, "\(t.id) \(label) below 0")
                XCTAssertLessThanOrEqual(value, 1, "\(t.id) \(label) above 1")
            }
        }
    }

    /// Opacity-only transitions are what got reported as "there is no animation". The enum cannot
    /// express an opacity-only geometry, so this guards the enum itself from a future `.fade`. The
    /// exhaustive switch is the compile-time half; the two assertions are the runtime teeth, so the test
    /// still has value if anyone adds a `default:`. The name check is `==` rather than `contains`, because
    /// `.positionCrossfade` ends in the substring "fade" and a membership set is what actually refuses it.
    func testEveryTransitionMovesGeometry() {
        let allowed: Set<String> = ["scaleFromGap", "collapseToGap", "growFromEdge",
                                    "positionCrossfade", "symbolMorph"]
        for t in MotionPlan.all {
            switch t.geometry {
            case .scaleFromGap, .collapseToGap, .growFromEdge, .positionCrossfade, .symbolMorph:
                break
            }
            XCTAssertFalse(String(describing: t.geometry) == "fade", "\(t.id)")
            XCTAssertTrue(allowed.contains(String(describing: t.geometry)), "\(t.id) \(t.geometry)")
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
