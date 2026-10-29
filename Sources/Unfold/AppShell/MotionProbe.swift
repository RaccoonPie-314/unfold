import AppKit

/// Runs each transition on a real view and logs the measured presentation geometry, because "the
/// animation is real" has to be a number at three timestamps rather than a screenshot opinion.
@MainActor
enum MotionProbe {
    /// `promptPresent` and `promptDismiss` are Plan 4's -- the panel they need does not exist yet.
    ///
    /// Each run is staggered past the previous one's duration plus a settle gap. `Motion.morph`
    /// deliberately removes the in-flight animation when a new target arrives, so firing all five at
    /// once would leave the later samples measuring the wrong transition.
    static func runAll(on host: NSView, log: @escaping (String) -> Void) {
        let ids: [TransitionID] = [.rowInsert, .rowRemove, .selectionMorph, .paneReveal, .statusMorph]
        var start = 0.0
        for id in ids {
            guard let transition = MotionPlan.lookup(id) else { continue }
            let at = start
            DispatchQueue.main.asyncAfter(deadline: .now() + at) { run(transition, on: host, log: log) }
            start += transition.duration + 0.15
        }
    }

    /// Nothing is resized here: the probe reads the view's real frame and morphs it out of a zero-height
    /// gap at its own baseline. The animation is a transform, so the layout never changes and the caret
    /// in a neighbouring field cannot move.
    ///
    /// What "moving" means in the log: a transform animation does *not* change `bounds` -- the resting
    /// size stays the resting size, which is the point of morphing by transform. The evidence that the
    /// motion is geometric is `scale` (0.02 → 1 for a `scaleFromGap`) and `tx`/`ty` sliding to zero.
    /// `bounds` is logged alongside them precisely so a mistake that *did* resize the layer would show
    /// up here rather than being mistaken for the transform.
    private static func run(_ transition: Transition, on host: NSView, log: @escaping (String) -> Void) {
        let final = host.frame
        let source = CGRect(x: final.minX, y: final.maxY, width: final.width, height: 0)
        Motion.morph(host, source: source, transition: transition)

        let samples = 8
        for step in 0..<samples {
            let when = transition.duration * Double(step) / Double(samples - 1)
            DispatchQueue.main.asyncAfter(deadline: .now() + when) {
                guard let presentation = host.layer?.presentation() else { return }
                let size = presentation.bounds.size
                let t = presentation.affineTransform()
                log("\(transition.id.rawValue) t=\(String(format: "%.0f", when * 1000))ms "
                    + "bounds=\(Int(size.width))x\(Int(size.height)) "
                    + "scale=\(String(format: "%.3f", t.a))x\(String(format: "%.3f", t.d)) "
                    + "tx=\(String(format: "%.1f", t.tx)) ty=\(String(format: "%.1f", t.ty))")
            }
        }
    }
}
