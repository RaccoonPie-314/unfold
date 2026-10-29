import AppKit
import QuartzCore

/// The single place the shell touches Core Animation. Everything it needs to know about timing comes
/// from a `Transition`, so retuning motion is a `MotionPlan` edit.
///
/// Two rules, both learned the hard way: geometry carries the motion, and an in-flight morph must be
/// interruptible -- `morph` removes the animation for its key before adding a new one, so a fast series
/// retargets instead of queueing a backlog, which is what `liquid-glass.md` means by letting people
/// cancel motion. Interrupting is only safe because the *completion* is matched to the animation it
/// was installed with (Ruling AC #2, see `morph`), and the spring has one clock: the transition's
/// `duration` (Ruling AC #1, see `spring`). (Ruling E: there is deliberately no `Motion.stop(_:)` --
/// that removal *is* the stop, and nothing else calls one until Plan 4's panel dismissal asks for it.)
@MainActor
enum Motion {
    static func morph(_ view: NSView, source: CGRect, transition: Transition,
                      completion: (() -> Void)? = nil) {
        guard let layer = preparedLayer(for: view) else { return }
        // Ruling D: `view.frame` *is* the rect in the superlayer's coordinates -- AppKit keeps a
        // layer-backed view's geometry in the view's own space rather than a separate drawing space, so
        // there is no conversion to do and no alias to name it. Ruling AC #3 settled which view answers
        // the y direction: `view.frame` is expressed in the space of the **immediate superview**, so that
        // view's `isFlipped` is the only correct thing to ask (the old `enclosingScrollView?.documentView`
        // branch read a different space entirely, and was dead code for every host the shell has ever
        // morphed -- the diagnostics cluster sits in a glass view inside a plain split item, with no
        // scroll view in sight). The flipped container this round added to `MotionDriverTests` then
        // measured what the flag is worth: the layer's space tracks the view's exactly, so the offset
        // needs no correction in either orientation, and `MotionGeometry`'s negation was the bug. The
        // read stays because Ruling AC #3 rules which view is the right one to ask and Task 9 pins the
        // parameter; `MotionGeometry`'s comment records that it changes no result today, and Task 11 --
        // where a source rect may be written in a *different* view's space -- is where that is settled.
        let flipped = view.superview?.isFlipped ?? false
        let start = MotionGeometry.morph(source: source, final: view.frame, flipped: flipped)

        // Interrupt first, then animate: adding under the same key would replace the in-flight
        // animation anyway, but removing it explicitly is the sentence that says so.
        layer.removeAnimation(forKey: Self.morphKey)
        let animation = animation(for: transition, start: start)
        // The `CAAnimation` completion-handler property is iOS-only -- it is not on the macOS SDK at
        // all, verified by the compiler rejecting it. On macOS the completion is carried by the
        // transaction that wraps the add.
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak layer] in
            // Identity, not key (Ruling AC #2). Removing an animation does *not* retire the transaction
            // that installed it: measured here, when the second morph replaced the first at 0.10 s the
            // first transaction's completion ran at 0.101 s -- at the instant of the interrupt, while the
            // replacement was mid-ramp -- and a blind `removeAnimation(forKey:)` there deletes the
            // animation that interrupted it and fires a completion for a morph that never happened.
            //
            // The predicate is "the key still holds the same animation, or holds nothing at all", and the
            // second half is measured too: Core Animation retires a finished animation from the layer
            // *before* the transaction's completion block runs (measured: keys empty at 0.383 s, the
            // block due at 0.38 s), so identity alone would also throw away every morph's real
            // completion -- and Task
            // 11's work hangs off it. A stale block can never observe "nothing": its replacement is
            // installed at the moment it runs, which is what makes the pair sound.
            guard let layer else { completion?(); return }   // host gone: nothing left to protect
            let current = layer.animation(forKey: Self.morphKey)
            guard current === animation || current == nil else { return }
            // The transform is never left applied: the view's real frame is the truth at the end.
            layer.removeAnimation(forKey: Self.morphKey)
            completion?()
        }
        layer.add(animation, forKey: Self.morphKey)
        rampOpacity(layer, transition: transition)
        CATransaction.commit()
    }

    static let morphKey = "unfold.morph"

    /// Scale and translate together, in one keyframe-free transform animation so the two cannot drift.
    private static func animation(for transition: Transition, start: MorphTransform) -> CAAnimation {
        switch transition.curve {
        case .spring(let damping):
            return spring(for: transition, start: start, dampingRatio: damping)
        case .easeOut(let x1, let y1, let x2, let y2):
            let basic = CABasicAnimation(keyPath: "transform")
            basic.fromValue = NSValue(caTransform3D: transform(scale: start.scale,
                                                               translation: start.translation))
            basic.toValue = NSValue(caTransform3D: CATransform3DIdentity)
            basic.timingFunction = CAMediaTimingFunction(controlPoints: Float(x1), Float(y1),
                                                         Float(x2), Float(y2))
            basic.duration = transition.duration
            return basic
        }
    }

    /// One clock: the transition's `duration` is the settle time, and the stiffness is derived to fit it.
    ///
    /// Two moves, because the textbook constant and Core Animation's are not the same number.
    /// - Seed from the 2% settling time of a unit-mass second-order system: settling ≈ `4/(ζ·ω₀)` with
    ///   `ω₀ = √k`, so `k = (4/(ζ·duration))²` and the damping coefficient is `c = 2ζ√(k·m)`.
    /// - Then correct against the settle time Core Animation actually reports, since that is what the
    ///   clip is compared to. Measured here at mass 1 across ζ = 0.4...0.95:
    ///   `settlingDuration = C(ζ)/σ` with `C(0.85) = 7.8685` -- **1.967× the textbook 4**, not 4, because
    ///   CA's threshold is ~1/2600 of the step rather than 2%. Left as the seed alone, the spring is
    ///   still truncated (`settlingDuration` 0.51 s against a 0.26 s duration) and stops at 99.63% of its
    ///   target, a 0.15 pt jump on a 40 pt row. At a fixed ζ the reported settle time scales as
    ///   `1/√stiffness`, so one multiplication of the seed by `(settle/duration)²` lands on the duration:
    ///   measured residual is under 1e-5 s for all three springs in the plan.
    ///
    /// The `min` is the safety net, not the mechanism. Note what it cannot fix: for ζ ≥ 1 the reported
    /// settle time stops scaling with σ (measured: a flat 0.6 s at ζ = 1.0 and 1.2), which is why the
    /// plan keeps damping strictly under critical, and why this derivation is only meaningful there.
    static func spring(for transition: Transition, start: MorphTransform,
                       dampingRatio zeta: Double) -> CASpringAnimation {
        let duration = transition.duration
        let spring = CASpringAnimation(keyPath: "transform")
        spring.fromValue = NSValue(caTransform3D: transform(scale: start.scale,
                                                            translation: start.translation))
        spring.toValue = NSValue(caTransform3D: CATransform3DIdentity)
        spring.initialVelocity = 0
        let seed = pow(4 / (zeta * duration), 2)
        setPhysical(spring, dampingRatio: zeta, stiffness: seed)
        let seedSettling = spring.settlingDuration
        if seedSettling > duration {
            setPhysical(spring, dampingRatio: zeta, stiffness: seed * pow(seedSettling / duration, 2))
        }
        spring.duration = min(duration, spring.settlingDuration)
        return spring
    }

    /// The damping coefficient is not independent of the stiffness -- it is `2ζ√(k·m)` -- so the two are
    /// always written together. `stiffness`, `damping` and `mass` are `CGFloat` on the animation while
    /// `zeta` and `duration` are the plan's `Double`s; the driver owns that conversion (seam note in
    /// `MotionPlan`).
    private static func setPhysical(_ spring: CASpringAnimation, dampingRatio zeta: Double,
                                    stiffness: Double) {
        spring.mass = 1
        spring.stiffness = CGFloat(stiffness)
        spring.damping = CGFloat(2.0 * zeta * stiffness.squareRoot())
    }

    private static func transform(scale: CGSize, translation: CGSize) -> CATransform3D {
        var t = CATransform3DIdentity
        t = CATransform3DTranslate(t, translation.width, translation.height, 0)
        return CATransform3DScale(t, scale.width, scale.height, 1)
    }

    /// A short anti-flash ramp only, inside the first `opacityRamp` of the timeline. It starts slightly
    /// transparent (0.8 with the plan's 0.2 ramp) and reaches opaque; it never starts at 0 and it never
    /// carries the motion alone -- the transform above is what moves.
    private static func rampOpacity(_ layer: CALayer, transition: Transition) {
        let ramp = CABasicAnimation(keyPath: "opacity")
        ramp.fromValue = 1 - transition.opacityRamp
        ramp.toValue = 1
        ramp.duration = transition.duration * transition.opacityRamp
        // Same-key add replaces the previous ramp, so an interrupted morph retargets opacity too.
        layer.add(ramp, forKey: "unfold.opacity")
    }

    private static func preparedLayer(for view: NSView) -> CALayer? {
        view.wantsLayer = true
        return view.layer
    }
}
