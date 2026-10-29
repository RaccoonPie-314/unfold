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
        let transition = try XCTUnwrap(MotionPlan.lookup(.selectionSlide))
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
        // Every reading well past the spring's clip is after the completion that removes it: the tree has
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
    /// Numbers measured on this machine (mass 1, `initialVelocity` 0, the driver's own animation
    /// object; re-printed by the test itself and updated when the plan changes):
    /// ```
    /// selectionSlide duration 0.240  stiffness 1484.0  damping 73.33  settlingDuration 0.2400
    /// promptPresent  duration 0.220  stiffness 1770.5  damping 71.53  settlingDuration 0.2200
    /// ```
    /// The textbook seed `k = (4/(ζ·duration))²` -- the ruling's arithmetic -- alone reports
    /// 0.5508 / 0.4328 s, **1.967× its own duration**, because `CASpringAnimation.settlingDuration` is
    /// `≈7.87/σ` (about 1/2600 of the step) rather than the `4/σ` 2% criterion. Measured at mass 1:
    /// σ·settlingDuration = 7.27 at ζ = 0.4, 7.87 at ζ = 0.85, 8.30 at ζ = 0.95, and it stops scaling
    /// with σ at all for ζ ≥ 1 (a flat 0.6 s). `Motion.spring` seeds with the ruling's formula and then
    /// closes the gap against the number Core Animation actually reports, so this assertion runs against
    /// the driver's own object rather than against a copy of the arithmetic. Mutation-proven both ways:
    /// dropping the correction leaves 0.5508 s (fails here), and the old `4/response²` leaves 1.296 s.
    ///
    /// What that spring does at the shipped ζ = 0.85: it overshoots by `exp(-πζ/√(1-ζ²))` = **0.63% of
    /// the step** -- 0.25 pt on a 40 pt row -- crossing its target at ~138 ms for a 0.26 s clip (the row
    /// transition's, before its removal on 2026-10-29), peaking at ~167 ms and inside CA's settle threshold
    /// at the clip's end. Second-order systems only overshoot for ζ < 1, so 0.63%
    /// is the whole of it: the old "look for a 2-5% overshoot" described the truncation, not the spring.
    @MainActor
    func testEverySpringSettlesInsideItsOwnDuration() throws {
        var lines: [String] = []
        var springs = 0

        for transition in MotionPlan.all {
            guard case .spring(let damping) = transition.curve else { continue }
            springs += 1
            // The geometry a zero-gap morph is handed: a 200×40 row unfolding out of a
            // zero-height gap 20 pt above its baseline.
            let start = MotionGeometry.morph(source: CGRect(x: 40, y: 100, width: 200, height: 0),
                                             final: CGRect(x: 40, y: 60, width: 200, height: 40))
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
        XCTAssertEqual(springs, 2, "the plan's two springs are what this test measures")
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
    /// Timeline: A = `selectionSlide` (0.24 s) at t=0, interrupted at t=0.10 by B = another `selectionSlide`
    /// (so B is in flight until ~0.34 while A's completion was due at ~0.24). The layer is polled every ~5 ms
    /// rather than sampled at one fixed instant, because when the stale completion runs is Core
    /// Animation's to choose. The invariant: from the interrupt until B's own end, whatever holds
    /// `unfold.morph` **is B's animation object** -- compared by identity, the same relation the driver's
    /// guard uses. B's completion firing is asserted too, because that is what proves this process
    /// retired a transaction at all; without it the guard would have gone untested.
    @MainActor
    func testAnInterruptedMorphLeavesTheInterruptingOneAlone() throws {
        let (window, _, host) = makeFixture(flipped: false)
        let layer = try XCTUnwrap(host.layer)
        // Both halves of the pair run the same surviving spring: A is the morph being interrupted,
        // B the one installed 100 ms into A's ramp.
        let slide = try XCTUnwrap(MotionPlan.lookup(.selectionSlide))
        let source = CGRect(x: host.frame.minX, y: host.frame.maxY, width: host.frame.width, height: 0)

        var firstCompletedAt: TimeInterval?
        var secondCompletedAt: TimeInterval?
        var installedBySecond: CAAnimation?
        var alienHolders: [String] = []
        var pollsWhileInFlight = 0

        let started = Date()
        Motion.morph(host, source: source, transition: slide) {
            firstCompletedAt = Date().timeIntervalSince(started)
        }
        drain(from: started, until: started.addingTimeInterval(0.10))
        Motion.morph(host, source: source, transition: slide) {
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
            guard elapsed < 0.10 + slide.duration - 0.01 else { return }
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

    /// Every fixture written before Task 10 sat in a non-flipped container, so `MotionGeometry`'s
    /// then-`flipped ? -dy : dy` was a model of what a layer does, never a measurement of it. This builds
    /// the flipped one -- a container whose `isFlipped` is true, the space a row inside a scroll view's
    /// document view or an `NSTableView` lives in -- morphs out of a gap that is *visually* above the row
    /// (and 40 pt clear of it, so the start pose carries a displacement in both containers even after
    /// the anchor compensation), and reads the sign off the presentation tree.
    ///
    /// How to read the numbers: in each container the layer's own coordinates run exactly the way its
    /// view's do -- the morphing layer's resting `frame` equals the view's `frame` in both orientations,
    /// and a control that converted the animated layer's rect into window coordinates measured
    /// `ty = +20` moving the unflipped layer 20 pt *up* and the flipped layer 20 pt *down* (Task 10). So
    /// a positive displacement is toward larger `y` in whichever space the rects are written on, and the
    /// translation that lands the layer on its source carries the same sign as `dy` in **both**. That is
    /// why the ternary went: it handed the flipped layer `ty = +19.62` against a `dy` of −20, starting
    /// the morph 20 pt on the far side of the resting frame and sliding it into place from below the row
    /// instead of from the gap above it -- re-inverting it still fails this test twice, and Ruling AE
    /// deleted the parameter rather than keeping an input the math does not read.
    ///
    /// Under the compensation the reading is *bigger* than the raw midpoint gap, by `(1 − k) · size / 2`
    /// with the default anchor `(0, 0)` -- the pose starts on `source`, and here `source` sits 40 pt
    /// beyond the gap edge the rects measure from. The displacement is read off `frame.origin`, which
    /// carries the translation in full (measured: a `ty` of 18.7 moved the origin by 18.7), rather than
    /// off `frame.midY`, because a rect scaled to 2% has a midY that barely budges (measured: 0.4 pt of
    /// a 20 pt translation).
    @MainActor
    func testAFlippedContainerMovesTheSameWayItsOwnCoordinatesSay() throws {
        let unflipped = try measureUpwardMorph(flipped: false)
        let flipped = try measureUpwardMorph(flipped: true)

        let report = "unflipped: \(unflipped.report)\nflipped:   \(flipped.report)"
        print("flipped-sign measurement:\n\(report)")
        NSLog("motion flipped measurement: \(report)")

        for reading in [unflipped, flipped] {
            // Part of Task 10's explanation of why no flip correction is needed: for a flipped *content
            // view* the container's layer mirrors its flippedness. It is a mechanism of this fixture,
            // not the contract the morph rests on -- the real scroll host measures the document layer's
            // flag as false (see `testTheCompensationHoldsInsideARealFlippedScrollHost`) and the pose
            // still lands, which is why the load-bearing assertion below is the frame-equality one.
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
            // taken early: the morph starts at scale 0.02, so a translation still above half of `dy`
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
    /// sitting **visually above** it and clear of it by 40 pt, read back off the presentation tree at the
    /// earliest moment this process produces one. No expectation about the sign is folded in here -- the
    /// point is to find out.
    @MainActor
    private func measureUpwardMorph(flipped: Bool) throws -> UpwardMorphReading {
        let (window, content, host) = makeFixture(flipped: flipped)
        let layer = try XCTUnwrap(host.layer)
        let transition = try XCTUnwrap(MotionPlan.lookup(.selectionSlide))

        // In a non-flipped superview +y runs up, so the gap above the row sits beyond its maxY edge; in
        // a flipped superview +y runs down, so the same-looking gap sits beyond its minY edge.
        let gapY = flipped ? host.frame.minY - 40 : host.frame.maxY + 40
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

    // MARK: - Ruling AE: the start pose lands on its source

    /// The centre displacement `MotionGeometry` returns is anchor-agnostic, and that is exactly its
    /// limitation: a layer paints its transform about its own `anchorPoint`, so with AppKit's default
    /// `(0, 0)` the bare midpoint **under-translates by `(1 − k) · size / 2` per axis** -- the 19.6 pt a
    /// 40 pt row scaled to 0.02 was measured landing short of its own source rect. `Motion` adds the
    /// signed correction `(1 − k) · size · (0.5 − anchor)` from the layer's actual anchor (Ruling AE),
    /// and this measures the result: the presentation layer's rendered rect -- the resting frame carried
    /// through the presentation's own transform about the anchor, expressed in the container's space --
    /// sits within 1 pt of the intended source at an early sample, in **both** container orientations.
    ///
    /// Geometry: the gap sits on the edge the anchor pins (`minY`, the side `anchorPoint` measures from)
    /// and is 8 pt inset in x, so the start pose carries translations of −0.4 pt in y and −8 pt in x
    /// against bare-midpoint errors of −19.6 pt and −8 pt. Position and time behave differently here on
    /// purpose: with anchor `(0, 0)` the rendered origin is `rest origin + translation`, and the
    /// translation decays toward identity as the ramp runs, so the *position* error a late sample adds is
    /// only `u · |t₀|` (measured: earliest sample ≈ 2-3% in, so well under 1 pt) while the *size*
    /// interpolates at `u · (1 − k) · size` and would drift past any honest fixed tolerance. The
    /// assertions are therefore about the pose's position -- which is what the compensation controls -- and
    /// the sampled scale is asserted low in return, which is what proves the reading is the start and not
    /// the tail.
    @MainActor
    func testAShrinkingMorphsStartPoseLandsOnItsSourceRectInEitherOrientation() throws {
        var reports: [String] = []
        for flipped in [false, true] {
            let (window, _, host) = makeFixture(flipped: flipped)
            let layer = try XCTUnwrap(host.layer)
            let transition = try XCTUnwrap(MotionPlan.lookup(.selectionSlide))
            let source = CGRect(x: host.frame.minX - 8, y: host.frame.minY,
                                width: host.frame.width - 16, height: 0)
            Motion.morph(host, source: source, transition: transition)
            XCTAssertTrue(layer.animationKeys()?.contains(morphKey) == true,
                          "no animation installed under \(morphKey) with flipped=\(flipped): the driver "
                              + "attached nothing, which is not a render-cycle question")
            let reading = try readStartPose(of: layer, within: 0.20)
            window.orderOut(nil)
            reports.append("flipped=\(flipped) source=\(source) \(reading.report)")
            try skipUnlessPresentationWasLive(reading)

            // The reading is the start of the morph, not its tail: k is clamped to 0.02 on y, and 0.5 is
            // nowhere near the ramp's end.
            XCTAssertLessThan(reading.scale.height, 0.5,
                              "sampled scale \(reading.scale.height) is too far along to read a start "
                                  + "pose (\(reports.last!))")
            XCTAssertEqual(reading.rendered.minX, source.minX, accuracy: 1.0,
                           "with isFlipped=\(flipped) the shrinking morph's start pose sat "
                               + "\(String(format: "%.2f", reading.rendered.minX - source.minX)) pt off "
                               + "its source in x — the horizontal anchor term is wrong (\(reports.last!))")
            XCTAssertEqual(reading.rendered.minY, source.minY, accuracy: 1.0,
                           "with isFlipped=\(flipped) the shrinking morph's start pose sat "
                               + "\(String(format: "%.2f", reading.rendered.minY - source.minY)) pt off "
                               + "its source in y — the bare midpoint is \(String(format: "%.1f", (1 - reading.scale.height) * host.frame.height / 2)) pt short here (\(reports.last!))")
        }
        let report = reports.joined(separator: "\n")
        print("anchor-compensation start-pose measurement (k < 1):\n\(report)")
        NSLog("motion anchor compensation shrink: \(report)")
    }

    /// The compensation matters in the **other** direction: a source *larger* than its target (a pane
    /// closing onto a pill) scales up, `k > 1`, and `(1 − k)` flips sign. The term is derived from the
    /// anchor, not hard-coded for shrinking, so the same code must land this pose too -- with the source
    /// sharing the resting origin the pose needs **zero** translation, while the bare midpoint flings it
    /// `(k − 1) · size / 2` = 100 pt in x and 20 pt in y *past* the frame, the opposite way from the
    /// shrinking case. A test that only ever checked `k < 1` would pass on a compensation hard-coded as
    /// `+(1 − k) · size / 2` ... which is the same expression, but a future edit that special-cases the
    /// shrink would not be caught; this pins the sign in both.
    @MainActor
    func testAGrowingStartPoseIsCompensatedInTheOtherDirection() throws {
        var reports: [String] = []
        for flipped in [false, true] {
            let (window, _, host) = makeFixture(flipped: flipped)
            let layer = try XCTUnwrap(host.layer)
            let transition = try XCTUnwrap(MotionPlan.lookup(.selectionSlide))
            // Same origin as the resting frame, twice the size on both axes: k = 2 on both.
            let source = CGRect(x: host.frame.minX, y: host.frame.minY,
                                width: host.frame.width * 2, height: host.frame.height * 2)
            Motion.morph(host, source: source, transition: transition)
            XCTAssertTrue(layer.animationKeys()?.contains(morphKey) == true,
                          "no animation installed under \(morphKey) with flipped=\(flipped)")
            let reading = try readStartPose(of: layer, within: 0.20)
            window.orderOut(nil)
            reports.append("flipped=\(flipped) source=\(source) \(reading.report)")
            try skipUnlessPresentationWasLive(reading)

            // k > 1 and still early: the ramp's tail reads ≈1, so >1.5 proves this is the grown pose.
            XCTAssertGreaterThan(reading.scale.width, 1.5,
                                 "sampled scale \(reading.scale.width) is not the k > 1 start pose "
                                     + "(\(reports.last!))")
            XCTAssertEqual(reading.rendered.minX, source.minX, accuracy: 1.0,
                           "with isFlipped=\(flipped) the growing morph's start pose sat "
                               + "\(String(format: "%.2f", reading.rendered.minX - source.minX)) pt off "
                               + "its source in x; the bare midpoint puts it \(String(format: "%.1f", (reading.scale.width - 1) * host.frame.width / 2)) pt the far way (\(reports.last!))")
            XCTAssertEqual(reading.rendered.minY, source.minY, accuracy: 1.0,
                           "with isFlipped=\(flipped) the growing morph's start pose sat "
                               + "\(String(format: "%.2f", reading.rendered.minY - source.minY)) pt off "
                               + "its source in y (\(reports.last!))")
        }
        let report = reports.joined(separator: "\n")
        print("anchor-compensation start-pose measurement (k > 1):\n\(report)")
        NSLog("motion anchor compensation grow: \(report)")
    }

    /// Task 10's reviewer owed one measurement: the flipped fixture is a flipped window content view,
    /// not a real scroll host. This is the scroll host -- an `NSScrollView` whose `documentView` is
    /// flipped, with the morphing view a plain subview of the document, which is where a sidebar row
    /// actually lives. The measurement answers the owed question with a wrinkle: the flipped content
    /// view's layer *mirror* (`isGeometryFlipped == isFlipped`) does **not** reappear here -- a flipped
    /// scroll document's layer reports `isGeometryFlipped == false` -- yet the frame equality does: the
    /// host layer's resting frame still equals the host view's frame, and the rendered start pose still
    /// lands on the source written in document-view coordinates. The morph rides the frame contract, not
    /// the flag, so the mechanism holds inside a real scroll host, which is what the assertions below
    /// measure rather than what they assume.
    @MainActor
    func testTheCompensationHoldsInsideARealFlippedScrollHost() throws {
        let (window, scroll, document, host) = makeScrollFixture()
        let layer = try XCTUnwrap(host.layer)
        let transition = try XCTUnwrap(MotionPlan.lookup(.selectionSlide))
        let source = CGRect(x: host.frame.minX - 8, y: host.frame.minY,
                            width: host.frame.width - 16, height: 0)

        // The fixture is the claimed one: a layer-backed chain, so the layer tree mirrors the view tree
        // and the rects below are comparable with the presentation geometry in the document's space.
        let superlayerIsDocumentLayer = layer.superlayer === document.layer
        NSLog("motion scroll fixture: document.isFlipped=\(document.isFlipped) "
              + "document.layer.isGeometryFlipped=\(String(describing: document.layer?.isGeometryFlipped)) "
              + "clip.layer.isGeometryFlipped=\(String(describing: scroll.contentView.layer?.isGeometryFlipped)) "
              + "superlayerIsDocumentLayer=\(superlayerIsDocumentLayer) "
              + "host.layer.frame=\(layer.frame) host.frame=\(host.frame) "
              + "scrollHasLayer=\(scroll.layer != nil)")
        XCTAssertTrue(superlayerIsDocumentLayer,
                      "the host's layer is not parented to the document view's layer, so this fixture "
                          + "is not measuring a scroll host")
        XCTAssertEqual(layer.frame, host.frame,
                       "inside the scroll host the layer's resting frame is no longer the view's "
                           + "frame, so the rects the morph is handed are not in the layer's space")

        Motion.morph(host, source: source, transition: transition)
        XCTAssertTrue(layer.animationKeys()?.contains(morphKey) == true,
                      "no animation installed under \(morphKey) inside the scroll host")
        let reading = try readStartPose(of: layer, within: 0.20)
        window.orderOut(nil)
        try skipUnlessPresentationWasLive(reading)

        let report = "source=\(source) \(reading.report)"
        print("anchor compensation in a real flipped scroll host:\n\(report)")
        NSLog("motion scroll host: \(report)")

        XCTAssertLessThan(reading.scale.height, 0.5, "sample is not the start pose (\(report))")
        XCTAssertEqual(reading.rendered.minX, source.minX, accuracy: 1.0,
                       "inside an NSScrollView with a flipped documentView the start pose sat "
                           + "\(String(format: "%.2f", reading.rendered.minX - source.minX)) pt off its "
                           + "source in x (\(report))")
        XCTAssertEqual(reading.rendered.minY, source.minY, accuracy: 1.0,
                       "inside an NSScrollView with a flipped documentView the start pose sat "
                           + "\(String(format: "%.2f", reading.rendered.minY - source.minY)) pt off its "
                           + "source in y — the mechanism does NOT hold in a real scroll host (\(report))")
    }

    // MARK: - start-pose reading

    /// What the presentation layer actually paints: the **rendered rect in the container's space** (the
    /// resting frame's corners carried through the presentation's transform, which is applied about the
    /// anchor), the sampled per-axis scale, and when the first readable frame landed.
    private struct StartPoseReading {
        let rendered: CGRect
        let scale: CGSize
        let elapsed: TimeInterval
        var report: String {
            let r = rendered
            let rect = String(format: "(%.2f, %.2f, %.2f x %.2f)", r.minX, r.minY, r.width, r.height)
            let k = String(format: "%.3fx%.3f", scale.width, scale.height)
            let at = String(format: "%.0fms", elapsed * 1000)
            return "rendered=\(rect) scale=\(k) readAt=\(at)"
        }
    }

    /// Polls until the presentation tree exists (the first readable frame *is* the start pose within a
    /// few percent of the ramp, as every other measurement in this file has found) and reads the
    /// rendered rect off it: the layer's own resting `frame` and `anchorPoint` -- which `Motion` must not
    /// change, and does not -- carried through `presentation().affineTransform()`, the animated
    /// transform. In the superlayer's space, which is the container's space.
    @MainActor
    private func readStartPose(of layer: CALayer, within seconds: TimeInterval) throws -> StartPoseReading {
        var reading: StartPoseReading?
        let rest = layer.frame
        let anchor = layer.anchorPoint
        let started = Date()
        drain(from: started, until: started.addingTimeInterval(seconds)) { now in
            guard reading == nil, let presentation = layer.presentation() else { return }
            let t = presentation.affineTransform()
            let anchorAbs = CGPoint(x: rest.minX + rest.width * anchor.x,
                                    y: rest.minY + rest.height * anchor.y)
            let corners = [CGPoint(x: rest.minX, y: rest.minY), CGPoint(x: rest.maxX, y: rest.minY),
                           CGPoint(x: rest.minX, y: rest.maxY), CGPoint(x: rest.maxX, y: rest.maxY)]
            let drawn = corners.map {
                CGPoint(x: anchorAbs.x + t.a * ($0.x - anchorAbs.x) + t.tx,
                        y: anchorAbs.y + t.d * ($0.y - anchorAbs.y) + t.ty)
            }
            let xs = drawn.map(\.x), ys = drawn.map(\.y)
            reading = StartPoseReading(
                rendered: CGRect(x: xs.min()!, y: ys.min()!,
                                 width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!),
                scale: CGSize(width: t.a, height: t.d),
                elapsed: now.timeIntervalSince(started))
        }
        return reading ?? StartPoseReading(rendered: .null, scale: .zero, elapsed: 0)
    }

    /// The one honest environment skip, same as the ramp test: an attached animation with no readable
    /// presentation frame means this process never entered a render cycle.
    private func skipUnlessPresentationWasLive(_ reading: StartPoseReading) throws {
        try XCTSkipUnless(reading.scale != .zero || reading.rendered != .null,
                          "presentation() never produced a frame for a morph attached under "
                              + "\(morphKey): this process entered no render cycle; the live pass owns it")
    }

    /// An `NSScrollView` whose `documentView` is flipped, with one plain layer-backed row inside it --
    /// the space a sidebar row really lives in. Every view on the chain is layer-backed so the layer
    /// tree mirrors the view tree (asserted at the call site, not assumed).
    @MainActor
    private func makeScrollFixture()
        -> (window: NSWindow, scroll: NSScrollView, document: NSView, host: NSView) {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                              styleMask: [.titled],
                              backing: .buffered,
                              defer: false)
        window.isReleasedWhenClosed = false
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 320, height: 240))
        scroll.wantsLayer = true
        scroll.hasVerticalScroller = false
        scroll.drawsBackground = false
        let document = FlippedContainer(frame: NSRect(x: 0, y: 0, width: 300, height: 1_200))
        document.wantsLayer = true
        let host = NSView(frame: NSRect(x: 40, y: 60, width: 200, height: 40))
        host.wantsLayer = true
        document.addSubview(host)
        scroll.documentView = document
        window.contentView = scroll

        window.setFrameOrigin(NSPoint(x: -3_200, y: -1_800))
        window.orderFrontRegardless()
        let attached = Date()
        drain(from: attached, until: attached.addingTimeInterval(0.06))
        return (window, scroll, document, host)
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
