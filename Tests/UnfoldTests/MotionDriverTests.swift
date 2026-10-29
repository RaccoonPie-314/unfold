import AppKit
import XCTest
@testable import Unfold

/// Measures the driver in-process: `Motion.morph` on a layer-backed view inside a real (ordered-front,
/// offscreen) `NSWindow`, reading `layer.presentation()` back at wall-clock checkpoints.
///
/// The known limitation, and how it was checked rather than assumed: Core Animation advances a layer's
/// presentation tree only while the render cycle runs, and a `swift test` process runs without
/// `NSApplication.run()`. On this machine it demonstrably *does* run -- the first experiment logged the y
/// scale climbing 0.020 → 0.093 → 0.283 → 0.542 and the translation sliding 20.0 → 0.0 across the morph
/// -- so the assertions below are measurements. Finding 4 (Ruling AC) closed the loose end: every test
/// proves the animation is *attached* under the literal key `unfold.morph` before it asks where the
/// render cycle got to, so the only thing left that can skip is the render cycle itself -- never "the
/// driver attached nothing", and never "the driver attached it under a key nobody asked about".
///
/// Time is driven by `drain`, not by `waitForExpectations`, and that is a measured difference rather
/// than a style choice: under XCTest's own wait loop the main *queue* clearly ran (scheduled blocks
/// fired and `presentation()` advanced) but `CATransaction` completion blocks never fired at all --
/// `firstCompletedAt=never, secondCompletedAt=never` on a morph that was visibly in flight -- while
/// `RunLoop.main.run(until:)` retired a control transaction's completion within one poll of its end
/// time. Two tests depend on completions really running, so nothing here relies on the loop XCTest puts
/// on the stack. The live pass on the installed app remains the authoritative measurement of what the
/// user sees.
final class MotionDriverTests: XCTestCase {
    /// The key the driver installs its transform animation under. A literal, not `Motion.morphKey`, so
    /// that retargeting the key in the driver is a failure rather than something the assertions quietly
    /// follow; `testPresentationSamplesMoveWhileTheMorphRuns` pins the two together.
    private let morphKey = "unfold.morph"

    // MARK: - the ramp itself

    @MainActor
    func testPresentationSamplesMoveWhileTheMorphRuns() throws {
        let (window, content, host) = makeFixture(flipped: false)
        let layer = try XCTUnwrap(host.layer)
        let transition = try XCTUnwrap(MotionPlan.lookup(.rowInsert))
        let source = CGRect(x: host.frame.minX, y: host.frame.maxY, width: host.frame.width, height: 0)
        var completedAt: TimeInterval?
        let started = Date()
        Motion.morph(host, source: source, transition: transition) {
            completedAt = Date().timeIntervalSince(started)
        }

        // Finding 4: attach first, *then* hope for a frame. Without this, every nil `presentation()`
        // reading below -- and the skip that consumes them -- would also be what a nil layer, an early
        // `guard` or a wrong key path looks like: the quiet pass this suite refuses to hand back.
        XCTAssertEqual(Motion.morphKey, morphKey,
                       "the driver's animation key moved off the literal this suite asserts against")
        let keys = layer.animationKeys() ?? []
        XCTAssertTrue(keys.contains(morphKey),
                      "no animation is installed under \(morphKey) right after the morph (keys=\(keys)), "
                          + "so this is a driver failure, not a render-cycle question")

        // Polled every ~5 ms instead of sampled at five fixed instants: with one clock the spring is
        // steep (it crosses its target at about half the duration), so a coarse sample can land entirely
        // past the motion and report a tree that "never moved".
        var readings: [(elapsed: TimeInterval, scale: CGFloat, ty: CGFloat, height: CGFloat)] = []
        drain(from: started, until: started.addingTimeInterval(transition.duration + 0.20)) { _ in
            guard let presentation = layer.presentation() else { return }
            let t = presentation.affineTransform()
            // Transformed height is the moving geometry: a transform animation leaves `bounds` alone, so
            // height = bounds.height × the interpolated y scale is what grows 0.02 → 1.
            readings.append((Date().timeIntervalSince(started), t.d, t.ty,
                             presentation.bounds.height * t.d))
        }
        window.orderOut(nil)

        let inFlight = readings.filter { $0.elapsed < transition.duration }
        let settled = readings.filter { $0.elapsed >= transition.duration + 0.10 }
        let peak = readings.map(\.height).max() ?? 0
        let log = readings.enumerated()
            .filter { $0.offset % 4 == 0 || $0.element.elapsed > transition.duration }
            .map { String(format: "t=%.0fms scale=%.3f ty=%.1f movingHeight=%.1f",
                          $0.element.elapsed * 1000, $0.element.scale, $0.element.ty, $0.element.height) }
            .joined(separator: "\n")
        print("motion samples (unflipped container, content.isFlipped=\(content.isFlipped), "
              + "view.frame=\(host.frame), resting layer.frame=\(layer.frame), \(readings.count) "
              + "readings, peak=\(String(format: "%.2f", peak)), completedAt="
              + "\(completedAt.map { String(format: "%.3f", $0) } ?? "never")):\n\(log)")
        NSLog("motion samples: %d readings, peak movingHeight=%.2f", Int32(readings.count), Double(peak))

        // The one honest environment skip: no reading at all means this process never entered a render
        // cycle, so there is no measurement to make. (Measured here: the tree exists and advances inside
        // `swift test`, so this branch is a portability valve, not a workaround -- and the assertion
        // above already refused the other reason there could be nothing to read.)
        try XCTSkipUnless(!readings.isEmpty,
                          "presentation() was nil at every poll for a morph demonstrably attached under "
                              + "\(morphKey): this test process never entered a render cycle, so the "
                              + "driver's motion cannot be measured in-process. Live pass owns it.")

        // Past that, a presentation tree that exists is a tree Core Animation is driving, so these
        // assertions are measurements, not hopes. Mutation-proven: an identity→identity transform (a
        // morph that moves nothing) reads 40.0 at every poll and fails the first assert -- a no-op driver
        // is a FAILURE here, not a skip, because "motion that looks like nothing" is exactly what
        // Task 10 was created to catch.
        XCTAssertTrue(inFlight.contains { $0.height < 40 * 0.9 },
                      "no in-flight reading caught the layer smaller than its resting 40 pt "
                          + "(\(readings.count) readings, peak \(String(format: "%.1f", peak))): the "
                          + "transform moved nothing")
        // Every reading well past the 260 ms spring is after the completion that removes it: the tree has
        // to be back at the resting height, not parked mid-morph.
        XCTAssertFalse(settled.isEmpty, "no reading was taken after the clip")
        for reading in settled {
            XCTAssertEqual(reading.height, 40, accuracy: 0.5,
                           "the morph must end on the view's real geometry, not leave the transform "
                               + "applied (t=\(String(format: "%.0f", reading.elapsed * 1000))ms)")
        }
        // The other half of the same claim, on the way in: a spring clipped before it settles ends
        // mid-ramp and jumps, which is the defect Ruling AC #1 exists to kill. With one clock the largest
        // height ever measured sits inside the overshoot the damping ratio allows -- ζ = 0.85 peaks at
        // 0.63% of the step (see `testEverySpringSettlesInsideItsOwnDuration`) -- not at the "2-5%" the
        // previous report said to look for, and not at the 44% the truncated
        // `response`-derived stiffness left (measured then: scale 0.542 at 250 ms of a 260 ms clip, i.e.
        // 22.6 pt of 40, then a jump to rest).
        XCTAssertLessThanOrEqual(peak, 40 * 1.015,
                                "the morph overshot its resting height by more than 1.5% "
                                    + "(\(String(format: "%.2f", peak)) pt of 40): the spring is not "
                                    + "settling inside its own duration")
        // ...and the jump itself, measured rather than inferred from `settlingDuration`: the last reading
        // before the clip has to already be at rest, because everything still missing at that instant is
        // what the user sees as a pop. The first version of this test stood in for it with `settled == 40`
        // at 400 ms, which a truncated spring satisfies just as happily (measured: with the old
        // `4/response²` stiffness this assertion fails at 15.4 pt of 40 while that 400 ms check passed).
        if let lastBeforeClip = inFlight.max(by: { $0.elapsed < $1.elapsed }) {
            XCTAssertLessThanOrEqual(abs(lastBeforeClip.height - 40), 1.0,
                                     "the spring was still at \(String(format: "%.1f", lastBeforeClip.height)) "
                                         + "pt of 40 at t=\(String(format: "%.0f", lastBeforeClip.elapsed * 1000))ms "
                                         + "of a \(String(format: "%.0f", transition.duration * 1000))ms "
                                         + "duration, so the clip cuts it off and the layer jumps")
        }
        // A morph that is never interrupted must report its own completion: Task 11 hangs the work that
        // follows a transition (finishing a deletion, moving selection) off this callback, and Ruling
        // AC #2's guard is only right if it still lets the *owner* through. Measured: Core Animation
        // retires the finished animation from the layer before the block runs, so a guard on identity
        // alone fires nothing at all -- see `Motion.morph`.
        XCTAssertNotNil(completedAt, "an uninterrupted morph never called its completion")
    }

    // MARK: - finding 1: a spring has one clock

    /// Ruling AC #1, proven where the data is checked: for **every** spring in the plan, the settle time
    /// Core Animation reports must fit inside the transition's own duration -- otherwise the clip lands
    /// before the motion is over and the layer jumps the rest of the way, which is exactly what
    /// `response` plus a clipped `duration` did (measured then: `settlingDuration` 1.296 s against a
    /// 0.26 s clip, and the first driver test asserted the resulting 22.6 pt snap as correct).
    ///
    /// Numbers measured on this machine (mass 1, `initialVelocity` 0, the driver's own animation object):
    /// ```
    /// rowInsert      duration 0.260  stiffness 1267.6  damping 60.53  settlingDuration 0.2600
    /// paneReveal     duration 0.280  stiffness 1093.0  damping 56.20  settlingDuration 0.2800
    /// promptPresent  duration 0.220  stiffness 1770.5  damping 71.53  settlingDuration 0.2200
    /// ```
    /// The textbook seed `k = (4/(ζ·duration))²` -- the ruling's arithmetic -- alone reports 0.5115 /
    /// 0.5508 / 0.4328 s, **1.967× its own duration**, because `CASpringAnimation.settlingDuration` is
    /// `≈7.87/σ` (about 1/2600 of the step) rather than the `4/σ` 2% criterion. Measured at mass 1:
    /// σ·settlingDuration = 7.27 at ζ = 0.4, 7.87 at ζ = 0.85, 8.30 at ζ = 0.95, and it stops scaling
    /// with σ at all for ζ ≥ 1 (a flat 0.6 s). `Motion.spring` seeds with the ruling's formula and then
    /// closes the gap against the number Core Animation actually reports, so this assertion runs against
    /// the driver's own object rather than against a copy of the arithmetic. Mutation-proven both ways:
    /// dropping the correction leaves 0.5115 s (fails here), and the old `4/response²` leaves 1.296 s.
    ///
    /// What that spring does at the shipped ζ = 0.85: it overshoots by `exp(-πζ/√(1-ζ²))` = **0.63% of
    /// the step** -- 0.25 pt on a 40 pt row -- crossing its target at ~138 ms, peaking at ~167 ms and
    /// inside CA's settle threshold at 260 ms. Second-order systems only overshoot for ζ < 1, so 0.63%
    /// is the whole of it: the old "look for a 2-5% overshoot" described the truncation, not the spring.
    @MainActor
    func testEverySpringSettlesInsideItsOwnDuration() throws {
        var lines: [String] = []
        var springs = 0

        for transition in MotionPlan.all {
            guard case .spring(let damping) = transition.curve else { continue }
            springs += 1
            // The geometry a real `scaleFromGap` morph is handed: a 200×40 row unfolding out of a
            // zero-height gap 20 pt above its baseline.
            let start = MotionGeometry.morph(source: CGRect(x: 40, y: 100, width: 200, height: 0),
                                             final: CGRect(x: 40, y: 60, width: 200, height: 40),
                                             flipped: false)
            let spring = Motion.spring(for: transition, start: start, dampingRatio: damping)
            let settling = spring.settlingDuration
            let overshoot = exp(-Double.pi * damping / (1 - damping * damping).squareRoot())
            lines.append("\(transition.id.rawValue): duration=\(String(format: "%.3f", transition.duration)) "
                         + "stiffness=\(String(format: "%.1f", Double(spring.stiffness))) "
                         + "damping=\(String(format: "%.2f", Double(spring.damping))) "
                         + "settlingDuration=\(String(format: "%.4f", settling)) "
                         + "spring.duration=\(String(format: "%.4f", spring.duration)) "
                         + "overshootRatio=\(String(format: "%.3f%%", overshoot * 100))")

            XCTAssertLessThanOrEqual(settling, transition.duration + 0.01,
                                     "\(transition.id.rawValue) settles in "
                                         + "\(String(format: "%.3f", settling)) s but is clipped at "
                                         + "\(transition.duration) s, so it ends with a jump")
            // The clip and the settle time are the same number by construction: the `min` only ever
            // agrees, it does not do the work.
            XCTAssertEqual(spring.duration, min(transition.duration, settling), accuracy: 0.0001,
                           "\(transition.id.rawValue) clipped somewhere other than the safety net")
            XCTAssertEqual(Double(spring.mass), 1, accuracy: 0.0001, "\(transition.id.rawValue) mass")
            XCTAssertEqual(Double(spring.damping),
                           2 * damping * Double(spring.stiffness).squareRoot(), accuracy: 0.01,
                           "\(transition.id.rawValue) is not the damping ratio the plan asked for")
            XCTAssertLessThan(overshoot, 0.01,
                              "\(transition.id.rawValue) at ζ=\(damping) overshoots "
                                  + "\(String(format: "%.1f%%", overshoot * 100)) of the step")
        }

        print("spring settle measurements:\n" + lines.joined(separator: "\n"))
        for line in lines { NSLog("motion spring: \(line)") }
        XCTAssertEqual(springs, 3, "the plan's three springs are what this test measures")
    }

    // MARK: - finding 2: interruption

    /// An interrupted morph must not kill its interruption. `removeAnimation(forKey:)` does not retire
    /// the transaction that installed the animation it removed, so the *first* morph's completion still
    /// runs when Core Animation finishes that animation -- and a completion that removes by key deletes
    /// the animation which replaced it, early in its ramp, then fires a completion for a morph that never
    /// happened. Measured with the guard removed (the mutation): the stale completion ran at 0.101 s, the
    /// key was empty from 0.107 s to 0.155 s, and the interrupted morph's completion fired -- the
    /// interrupting spring deleted 60 ms into its own 280 ms ramp.
    ///
    /// Timeline: A = `rowInsert` (0.26 s) at t=0, interrupted at t=0.10 by B = `paneReveal` (0.28 s, so B
    /// is in flight until ~0.38 while A's completion is due at ~0.26). The layer is polled every ~5 ms
    /// rather than sampled at one fixed instant, because when the stale completion runs is Core
    /// Animation's to choose. The invariant: from the interrupt until B's own end, whatever holds
    /// `unfold.morph` **is B's animation object** -- compared by identity, the same relation the driver's
    /// guard uses. B's completion firing is asserted too, because that is what proves this process
    /// retired a transaction at all; without it the guard would have gone untested.
    @MainActor
    func testAnInterruptedMorphLeavesTheInterruptingOneAlone() throws {
        let (window, _, host) = makeFixture(flipped: false)
        let layer = try XCTUnwrap(host.layer)
        let rowInsert = try XCTUnwrap(MotionPlan.lookup(.rowInsert))
        let paneReveal = try XCTUnwrap(MotionPlan.lookup(.paneReveal))
        let source = CGRect(x: host.frame.minX, y: host.frame.maxY, width: host.frame.width, height: 0)

        var firstCompletedAt: TimeInterval?
        var secondCompletedAt: TimeInterval?
        var installedBySecond: CAAnimation?
        var alienHolders: [String] = []
        var pollsWhileInFlight = 0

        let started = Date()
        Motion.morph(host, source: source, transition: rowInsert) {
            firstCompletedAt = Date().timeIntervalSince(started)
        }
        drain(from: started, until: started.addingTimeInterval(0.10))
        Motion.morph(host, source: source, transition: paneReveal) {
            secondCompletedAt = Date().timeIntervalSince(started)
        }
        // The handle the guard is supposed to respect: whatever B installed, read back by key. If
        // `animation(forKey:)` did not hand the same object back, identity comparison would prove
        // nothing, so that is measured here rather than assumed.
        installedBySecond = layer.animation(forKey: morphKey)
        XCTAssertNotNil(installedBySecond,
                        "the second morph left nothing under \(morphKey) (keys="
                            + "\(layer.animationKeys() ?? [])): the driver attached no animation")
        XCTAssertTrue(installedBySecond is CASpringAnimation,
                      "after the second morph the animation under the key is "
                          + "\(String(describing: installedBySecond.map { Swift.type(of: $0) })), not the "
                          + "spring B asked for")

        drain(from: started, until: started.addingTimeInterval(1.0)) { now in
            guard secondCompletedAt == nil else { return }
            let elapsed = now.timeIntervalSince(started)
            // Core Animation retires a finished animation from the layer on its own, a hair before the
            // transaction's completion block runs (measured: the key went empty at 0.383 s for an
            // animation installed at 0.10 s with a 0.28 s duration). "Nothing under the key" is only
            // evidence of a stolen interruption *inside* B's own window, so the 10 ms tail is left to CA.
            guard elapsed < 0.10 + paneReveal.duration - 0.01 else { return }
            pollsWhileInFlight += 1
            let current = layer.animation(forKey: morphKey)
            if current !== installedBySecond {
                let who = current.map { String(describing: Swift.type(of: $0)) } ?? "nothing under the key"
                alienHolders.append("t=\(String(format: "%.3f", elapsed))s: \(who)")
            }
        }
        window.orderOut(nil)

        let report = "firstCompletedAt=\(firstCompletedAt.map { String(format: "%.3f", $0) } ?? "never") "
            + "secondCompletedAt=\(secondCompletedAt.map { String(format: "%.3f", $0) } ?? "never") "
            + "pollsWhileInFlight=\(pollsWhileInFlight) alienHolders=\(alienHolders.count) "
            + "[\(alienHolders.prefix(3).joined(separator: ", "))]"
        NSLog("motion interrupt: \(report)")
        print("motion interrupt: \(report)")

        XCTAssertGreaterThan(pollsWhileInFlight, 0,
                             "the invariant was never polled, so the test measured nothing (\(report))")
        XCTAssertTrue(alienHolders.isEmpty,
                      "something other than the interrupting animation held \(morphKey) while it was "
                          + "supposed to be running — the interrupted morph's stale completion cut it "
                          + "short (\(report))")
        XCTAssertNotNil(secondCompletedAt,
                        "the interrupting morph never reported its own completion, so this process "
                            + "retired no transaction and the identity guard went untested (\(report))")
        XCTAssertNil(firstCompletedAt,
                     "the interrupted morph fired its completion for a morph that was replaced mid-ramp "
                         + "(\(report))")
    }

    // MARK: - finding 3: the flipped container, measured

    /// Every fixture written before this line sat in a non-flipped container, so `MotionGeometry`'s
    /// `flipped ? -dy : dy` was a model of what a layer does, never a measurement of it. This builds the
    /// flipped one -- a container whose `isFlipped` is true, the space a row inside a scroll view's
    /// document view or an `NSTableView` lives in -- morphs out of a gap that is *visually* above the row,
    /// and reads the sign off the presentation tree.
    ///
    /// How to read the numbers: in each container the layer's own coordinates run exactly the way its
    /// view's do -- the container's layer reports `isGeometryFlipped` equal to the view's `isFlipped`
    /// (asserted below, because it is the reason no correction is needed), the morphing layer's `frame`
    /// equals the view's `frame` in both orientations, and a control that converted the animated layer's
    /// rect into window coordinates measured `ty = +20` moving the unflipped layer 20 pt *up* and the
    /// flipped layer 20 pt *down*. So a positive displacement is toward larger `y` in whichever space the
    /// rects are written on, and the translation that lands the layer on its source carries the same sign
    /// as `dy` in **both**. Measured here: unflipped `dy = +20` → `ty = +19.53`; flipped `dy = −20` →
    /// `ty = −19.68`. The shipped ternary failed the second: it handed the layer `ty = +19.62` against a
    /// `dy` of −20, starting the morph 20 pt on the far side of the resting frame and sliding it into
    /// place from below the row instead of from the gap above it (that is mutation (c): re-inverting the
    /// ternary fails this test twice, `("1") is not equal to ("-1")`). The fix went into `MotionGeometry`,
    /// not into a driver guess.
    ///
    /// The displacement is read off `frame.origin`, which carries the translation in full (measured: a
    /// `ty` of 18.7 moved the origin by 18.7), rather than off `frame.midY`, because a rect scaled to 2%
    /// has a midY that barely budges (measured: 0.4 pt of a 20 pt translation).
    @MainActor
    func testAFlippedContainerMovesTheSameWayItsOwnCoordinatesSay() throws {
        let unflipped = try measureUpwardMorph(flipped: false)
        let flipped = try measureUpwardMorph(flipped: true)

        let report = "unflipped: \(unflipped.report)\nflipped:   \(flipped.report)"
        print("flipped-sign measurement:\n\(report)")
        NSLog("motion flipped measurement: \(report)")

        for reading in [unflipped, flipped] {
            // The mechanism the sign claim rests on: AppKit mirrors the view's flippedness into the layer,
            // so the morph's own space already runs the way the rects say it runs.
            XCTAssertEqual(reading.containerLayerIsGeometryFlipped, reading.containerIsFlipped,
                           "the container's layer disagrees with its view about the y direction "
                               + "(\(reading.report))")
            XCTAssertEqual(reading.restingLayerFrame, reading.viewFrame,
                           "the layer's resting frame is not the view's frame, so the rects handed to "
                               + "`MotionGeometry` are not in the layer's space (\(reading.report))")
            XCTAssertEqual(reading.displacement.sign, reading.dy.sign,
                           "in a container with isFlipped=\(reading.containerIsFlipped) the morph out of "
                               + "a source rect displaced by dy=\(reading.dy) pt moved the layer "
                               + "\(reading.displacement) pt: it started on the far side of its resting "
                               + "frame instead of at the gap (\(reading.report))")
            XCTAssertEqual(reading.earlyTy.sign, reading.dy.sign,
                           "the raw transform offset disagrees with the gap the geometry was handed "
                               + "(\(reading.report))")
            // An assertion about a sign read after the ramp is over is an assertion about zero, so the
            // displacement still has to be most of the gap. This is also what proves the reading was
            // taken early: `rowInsert` starts at scale 0.02, so a translation still above half of `dy`
            // is the first frames of the morph, not its tail.
            XCTAssertGreaterThanOrEqual(abs(reading.displacement), abs(reading.dy) * 0.5,
                                        "the earliest reading had already given up "
                                            + "\(String(format: "%.0f%%", 100 * (1 - abs(reading.displacement) / abs(reading.dy)))) "
                                            + "of the gap, too late to read a direction from "
                                            + "(\(reading.report))")
        }
    }

    private struct UpwardMorphReading {
        let containerIsFlipped: Bool
        let viewFrame: NSRect
        let restingLayerFrame: NSRect
        let containerLayerIsGeometryFlipped: Bool
        let dy: CGFloat
        let earlyTy: CGFloat
        let earlyScale: CGFloat
        /// Measured movement of the layer's frame origin from its resting origin, in the container's own
        /// coordinate space -- the number that says which way the layer went, and by how much.
        let displacement: CGFloat
        let elapsedAtEarlyReading: TimeInterval
        var report: String {
            "isFlipped=\(containerIsFlipped) view.frame=\(viewFrame) "
                + "resting layer.frame=\(restingLayerFrame) "
                + "containerLayer.isGeometryFlipped=\(containerLayerIsGeometryFlipped) "
                + "dy=\(dy) earliestReadingAt=\(String(format: "%.0fms", elapsedAtEarlyReading * 1000)) "
                + "presentationTy=\(String(format: "%.2f", earlyTy)) "
                + "scale=\(String(format: "%.3f", earlyScale)) "
                + "measuredDisplacement=\(String(format: "%.2f", displacement))"
        }
    }

    /// One row at a real frame in a container of the given flippedness, morphed out of a zero-height gap
    /// sitting **visually above** it, read back off the presentation tree at the earliest moment this
    /// process produces one. No expectation about the sign is folded in here -- the point is to find out.
    @MainActor
    private func measureUpwardMorph(flipped: Bool) throws -> UpwardMorphReading {
        let (window, content, host) = makeFixture(flipped: flipped)
        let layer = try XCTUnwrap(host.layer)
        let transition = try XCTUnwrap(MotionPlan.lookup(.rowInsert))

        // In a non-flipped superview +y runs up, so the gap above the row sits at its maxY edge; in a
        // flipped superview +y runs down, so the same-looking gap sits at its minY edge.
        let gapY = flipped ? host.frame.minY : host.frame.maxY
        let source = CGRect(x: host.frame.minX, y: gapY, width: host.frame.width, height: 0)
        Motion.morph(host, source: source, transition: transition)
        XCTAssertTrue(layer.animationKeys()?.contains(morphKey) == true,
                      "no animation installed under \(morphKey) with flipped=\(flipped): the driver "
                          + "attached nothing, which is not a render-cycle question")

        var earlyTy: CGFloat?
        var earlyScale: CGFloat?
        var earlyDisplacement: CGFloat?
        var earlyElapsed: TimeInterval?
        let restingOriginY = layer.frame.origin.y
        let started = Date()
        drain(from: started, until: started.addingTimeInterval(0.20)) { now in
            guard earlyTy == nil, let presentation = layer.presentation() else { return }
            let t = presentation.affineTransform()
            earlyTy = t.ty
            earlyScale = t.d
            earlyDisplacement = presentation.frame.origin.y - restingOriginY
            earlyElapsed = now.timeIntervalSince(started)
        }
        window.orderOut(nil)

        let ty = try XCTUnwrap(earlyTy,
                               "presentation() never produced a frame with flipped=\(flipped) even "
                                   + "though the animation is attached under \(morphKey): this process "
                                   + "never entered a render cycle")
        return UpwardMorphReading(
            containerIsFlipped: flipped,
            viewFrame: host.frame,
            restingLayerFrame: layer.frame,
            containerLayerIsGeometryFlipped: content.layer?.isGeometryFlipped ?? false,
            dy: source.midY - host.frame.midY,
            earlyTy: ty,
            earlyScale: earlyScale ?? 0,
            displacement: earlyDisplacement ?? 0,
            elapsedAtEarlyReading: earlyElapsed ?? 0)
    }

    // MARK: - fixtures

    /// A real window, a layer-backed content view with the requested flippedness, and one plain
    /// layer-backed subview at a real frame -- so a test can read `layer` before the first morph. Off the
    /// corner of any plausible display, but ordered front: on-screen-ness, not position, is what gates
    /// the render cycle.
    ///
    /// The last drain is not decoration: AppKit only joins a view's layer to its superview's layer
    /// during a display pass, and a morph measured on an unattached layer is measured in a space nobody
    /// renders into. Measured: with no run loop turn `layer.superlayer` is nil; after one it *is* the
    /// container's layer, whose `isGeometryFlipped` is what gives the y direction its meaning.
    @MainActor
    private func makeFixture(flipped: Bool) -> (window: NSWindow, content: NSView, host: NSView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                              styleMask: [.titled],
                              backing: .buffered,
                              defer: false)
        window.isReleasedWhenClosed = false
        let content: NSView = flipped ? FlippedContainer(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
                                      : NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        content.wantsLayer = true
        window.contentView = content

        let host = NSView(frame: NSRect(x: 40, y: 60, width: 200, height: 40))
        host.wantsLayer = true
        content.addSubview(host)

        window.setFrameOrigin(NSPoint(x: -3_200, y: -1_800))
        window.orderFrontRegardless()
        let attached = Date()
        drain(from: attached, until: attached.addingTimeInterval(0.06))
        NSLog("motion test fixture: superlayerIsContentLayer=\(host.layer?.superlayer === content.layer) "
              + "content.layer.isGeometryFlipped=\(String(describing: content.layer?.isGeometryFlipped)) "
              + "host.frame=\(host.frame) host.layer.frame=\(String(describing: host.layer?.frame))")
        NSLog("motion test: window screen=\(String(describing: window.screen)) visible=\(window.isVisible)")
        return (window, content, host)
    }

    /// Advances the main run loop to `deadline`, calling `check` on every pass (~5 ms). Used instead of
    /// `waitForExpectations` because XCTest's own wait loop does not let Core Animation retire a
    /// transaction: a completion block the driver installed would never run, and a test that appeared to
    /// pass on it would be measuring the harness rather than the driver.
    @MainActor
    private func drain(from start: Date, until deadline: Date, check: (Date) -> Void = { _ in }) {
        while Date() < deadline {
            let slice = min(deadline, Date().addingTimeInterval(0.005))
            RunLoop.main.run(until: slice)
            check(Date())
        }
    }
}

/// A container whose y axis runs downward: the space a row inside a scroll view's document view, or an
/// `NSTableView` row, actually lives in. The unflipped half of the comparison is a plain `NSView`.
private final class FlippedContainer: NSView {
    override var isFlipped: Bool { true }
}
