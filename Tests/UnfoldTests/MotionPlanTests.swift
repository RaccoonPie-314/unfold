import XCTest
@testable import Unfold

/// A cubic timing function maps time-progress to value-progress through a parameter, so the value at a
/// given time is found by solving `x(t) = time` for `t`. Bisection is enough: the x curve is monotonic for
/// control points inside [0, 1], which is the bound asserted below. `CAMediaTimingFunction` would evaluate
/// this in one call but it is AppKit/QuartzCore, and this file stays Foundation-only on purpose.
private func progress(of curve: (Double, Double, Double, Double), atTime time: Double) -> Double {
    let (x1, y1, x2, y2) = curve
    func axis(_ a: Double, _ b: Double, _ t: Double) -> Double {
        3 * (1 - t) * (1 - t) * t * a + 3 * (1 - t) * t * t * b + t * t * t
    }
    var low = 0.0, high = 1.0, mid = 0.5
    for _ in 0..<40 {
        mid = (low + high) / 2
        if axis(x1, x2, mid) < time { low = mid } else { high = mid }
    }
    return axis(y1, y2, mid)
}

/// The motion contract as data. Every rule corrected in review is an assertion here, so a
/// regression is a failing test rather than "i cant tell if anything animated".
final class MotionPlanTests: XCTestCase {
    private let required: [TransitionID] = [.selectionSlide, .promptPresent, .promptDismiss]

    func testEveryNamedTransitionExists() {
        for id in required { XCTAssertNotNil(MotionPlan.lookup(id), "\(id) is missing") }
        XCTAssertEqual(MotionPlan.all.count, required.count, "an undeclared transition slipped in")
    }

    /// The contract as an exact table, because a band this wide passes any plausible transposition of the
    /// real numbers and the id-to-curve-kind mapping is otherwise unpinned.
    func testEachTransitionIsExactlyAsSpecified() {
        let expected: [TransitionID: (duration: Double, curve: Curve, ramp: Double)] = [
            .selectionSlide: (0.24, .spring(damping: 0.85), 0.2),
            .promptPresent: (0.22, .spring(damping: 0.85), 0.2),
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
    /// runtime by `CAMediaTimingFunction`, so an out-of-range value is a crash waiting for Task 10. The
    /// [0, 1] bound is also what makes the x curve monotonic, and therefore what makes the bisection in
    /// `testNoCurveSpendsMostOfItsChangeEarlyInTheTimeline` legal.
    func testEaseOutControlPointsStayInsideTheUnitSquare() {
        for t in MotionPlan.all {
            guard case .easeOut(let x1, let y1, let x2, let y2) = t.curve else { continue }
            for (label, value) in [("x1", x1), ("y1", y1), ("x2", x2), ("y2", y2)] {
                XCTAssertGreaterThanOrEqual(value, 0, "\(t.id) \(label) below 0")
                XCTAssertLessThanOrEqual(value, 1, "\(t.id) \(label) above 1")
            }
        }
    }

    /// "It looked like nothing" is a statement about how much of the change is spent early, so this
    /// samples the property itself: at 20% of each transition's own duration, no more than 60% of the
    /// change may be gone. Sampling a fraction of the timeline rather than an absolute 45 ms is Ruling
    /// AB, and the separation is now duration-independent: at 20% the approved curve
    /// `(0.33, 1, 0.68, 1)` sits at ~48.8% and the curve this project was actually burned by,
    /// `(0.22, 1, 0.36, 1)`, at ~67.4% -- nineteen points apart at *every* duration, because the sample
    /// point travels with the transition. The contract is expressed in durations, so this is the
    /// dimensionally correct axis; the old absolute sample meant different things at 0.18 s and 0.28 s
    /// (approved reached 57.7% by 45 ms at 0.18 s, and the burned curve slipped under the ceiling
    /// entirely at 0.32 s, at 52.8%).
    ///
    /// The hierarchy, honestly: `testEachTransitionIsExactlyAsSpecified` is the primary guard. It pins
    /// each of the declared ids to an exact `Curve`, so a *known* transition cannot be changed without
    /// failing there. This test is the net for a **new** transition: its duration is unknowable, and only
    /// a duration-independent sample can say whether an in-band set of control points still spends the
    /// change too early. It is not claimed to catch anything, for today's four ids, that the exactness
    /// table does not already catch.
    func testNoCurveSpendsMostOfItsChangeEarlyInTheTimeline() {
        for t in MotionPlan.all {
            guard case .easeOut(let x1, let y1, let x2, let y2) = t.curve else { continue }
            let spent = progress(of: (x1, y1, x2, y2), atTime: 0.2)
            XCTAssertLessThanOrEqual(spent, 0.6,
                "\(t.id) is \(String(format: "%.0f%%", spent * 100)) done at 20% of its "
                + "\(t.duration)s timeline")
        }
    }

    /// Opacity-only transitions are what got reported as "there is no animation". The enum cannot
    /// express an opacity-only geometry, so this guards the enum itself from a future `.fade`. The
    /// exhaustive switch is the compile-time half; the two assertions are the runtime teeth, so the test
    /// still has value if anyone adds a `default:`. The name check is `==` rather than `contains`, because
    /// `.positionCrossfade` ends in the substring "fade" and a membership set is what actually refuses it.
    func testEveryTransitionMovesGeometry() {
        let allowed: Set<String> = ["positionCrossfade", "slideAndGrow"]
        for t in MotionPlan.all {
            switch t.geometry {
            case .positionCrossfade, .slideAndGrow:
                break
            }
            XCTAssertFalse(String(describing: t.geometry) == "fade", "\(t.id)")
            XCTAssertTrue(allowed.contains(String(describing: t.geometry)), "\(t.id) \(t.geometry)")
        }
    }

    /// The spring has exactly one knob now (Ruling AC #1): `damping`, the damping ratio ζ. There is no
    /// settle-time parameter to pin any more because the transition's own `duration` is the settle time --
    /// the driver derives the stiffness that makes `CASpringAnimation.settlingDuration` land on it, and
    /// `MotionDriverTests.testEverySpringSettlesInsideItsOwnDuration` is the proof, because
    /// `settlingDuration` is QuartzCore and this file stays Foundation-only.
    ///
    /// What the band still means: a second-order system only overshoots for ζ < 1, and the overshoot
    /// ratio is `exp(-πζ/√(1-ζ²))` of the step -- 0.63% at ζ = 0.85, 3.5% at ζ = 0.7. Under 0.7 the morph
    /// reads as a bounce rather than an arrival; above 1 there is no spring left to time, and Core
    /// Animation stops reporting a settle time that scales with the parameters (measured: a flat 0.6 s at
    /// ζ ≥ 1), so the derivation the driver relies on no longer holds.
    func testSpringsAreDampedEnoughToSettleWithoutBouncing() {
        var springs = 0
        for t in MotionPlan.all {
            if case .spring(let damping) = t.curve {
                springs += 1
                XCTAssertGreaterThan(damping, 0.7, "\(t.id) overshoots")
                XCTAssertLessThan(damping, 1.0, "\(t.id) is not underdamped, so it has no settle time")
            }
        }
        XCTAssertGreaterThan(springs, 0, "no spring left for this test to constrain")
    }

    /// The Diagnostics divider's clock is data too (the 2026-10-29 four-change pass deleted the pane
    /// content transform and kept the divider move), so it lives in the plan and is bound by the same
    /// rules: the perceived band, and **no spring** -- `NSAnimationContext` expresses control points,
    /// not a damped settle, and pretending otherwise would be a plan value the divider path cannot
    /// honour.
    func testTheDividerClockIsInTheBandAndExpressibleOnNSAnimationContext() {
        XCTAssertGreaterThanOrEqual(MotionPlan.dividerDuration, 0.15, "the divider move is too fast to perceive")
        XCTAssertLessThanOrEqual(MotionPlan.dividerDuration, 0.32, "the divider move makes people wait")
        guard case .easeOut(let x1, let y1, let x2, let y2) = MotionPlan.dividerCurve else {
            return XCTFail("the divider cannot spring; NSAnimationContext takes control points, "
                            + "and only the approved ease-out shape may be written here")
        }
        XCTAssertEqual([x1, y1, x2, y2], [0.33, 1.0, 0.68, 1.0],
                       "the divider moved off the approved curve")
    }
}
