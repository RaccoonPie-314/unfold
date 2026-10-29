import AppKit
import QuartzCore

/// The single place the shell touches Core Animation. Everything it needs to know about timing comes
/// from a `Transition`, so retuning motion is a `MotionPlan` edit.
///
/// Two rules, both learned the hard way: geometry carries the motion, and an in-flight morph must be
/// interruptible -- `morph` removes the animation for its key before adding a new one, so a fast series
/// retargets instead of queueing a backlog, which is what `liquid-glass.md` means by letting people
/// cancel motion. (Ruling E: there is deliberately no `Motion.stop(_:)` -- that removal *is* the stop,
/// and nothing else calls one until Plan 4's panel dismissal asks for it.)
@MainActor
enum Motion {
    static func morph(_ view: NSView, source: CGRect, transition: Transition,
                      completion: (() -> Void)? = nil) {
        guard let layer = preparedLayer(for: view) else { return }
        // Ruling D: `view.frame` *is* the rect in the superlayer's coordinates -- AppKit keeps a
        // layer-backed view's geometry in the view's own space rather than a separate drawing space,
        // so there is no conversion to do and no alias to name it. The coordinate question that does
        // bite is the y sign, and it is decided here, by which space's `isFlipped` governs the frame:
        // the enclosing scroll view's document view if the morph lives in one, else the superview.
        // The probe (Task 10) is what proves the sign on a real layer.
        let flipped = view.enclosingScrollView?.documentView?.isFlipped
            ?? (view.superview?.isFlipped ?? false)
        let start = MotionGeometry.morph(source: source, final: view.frame, flipped: flipped)

        // Interrupt first, then animate: adding under the same key would replace the in-flight
        // animation anyway, but removing it explicitly is the sentence that says so.
        layer.removeAnimation(forKey: Self.morphKey)
        let animation = animation(for: transition, start: start)
        // The `CAAnimation` completion-handler property is iOS-only -- it is not on the macOS SDK at
        // all, verified by the compiler rejecting it. On macOS the completion is carried by the
        // transaction that wraps the add.
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak view] in
            // The transform is never left applied: the view's real frame is the truth at the end.
            view?.layer?.removeAnimation(forKey: Self.morphKey)
            completion?()
        }
        layer.add(animation, forKey: Self.morphKey)
        rampOpacity(layer, transition: transition)
        CATransaction.commit()
    }

    private static let morphKey = "unfold.morph"

    /// Scale and translate together, in one keyframe-free transform animation so the two cannot drift.
    private static func animation(for transition: Transition, start: MorphTransform) -> CAAnimation {
        let from = transform(scale: start.scale, translation: start.translation)
        let to = CATransform3DIdentity
        switch transition.curve {
        case .spring(let damping, let response):
            let spring = CASpringAnimation(keyPath: "transform")
            spring.fromValue = NSValue(caTransform3D: from)
            spring.toValue = NSValue(caTransform3D: to)
            // `response` is the settle time; stiffness follows from it at unit mass, and damping ratio
            // maps onto `damping` the way `CASpringAnimation` expects (ratio × 2 × sqrt(stiffness × mass)).
            // All three are CGFloat, and `response` is a Double from the plan -- the conversion is
            // explicit because Swift will not do it for you.
            spring.mass = 1
            spring.stiffness = CGFloat(4 / (response * response))
            spring.damping = CGFloat(2.0 * damping * spring.stiffness.squareRoot())
            spring.duration = transition.duration
            spring.initialVelocity = 0
            return spring
        case .easeOut(let x1, let y1, let x2, let y2):
            let basic = CABasicAnimation(keyPath: "transform")
            basic.fromValue = NSValue(caTransform3D: from)
            basic.toValue = NSValue(caTransform3D: to)
            basic.timingFunction = CAMediaTimingFunction(controlPoints: Float(x1), Float(y1),
                                                         Float(x2), Float(y2))
            basic.duration = transition.duration
            return basic
        }
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
