import AppKit

/// Runs each transition on a real view and logs the measured presentation geometry, because "the
/// animation is real" has to be a number at three timestamps rather than a screenshot opinion.
@MainActor
enum MotionProbe {
    /// The transitions the probe runs: every id the shell actually wires. `promptPresent` and
    /// `promptDismiss` are Plan 4's -- the panel they need does not exist yet -- and the selection-line
    /// and row-flash transitions were removed by user decision on 2026-10-29, so this is the wired set
    /// and `MotionProbeTests` asserts it.
    static let wiredTransitionIDs: [TransitionID] = [.selectionSlide, .paneReveal]

    /// Runs the two wired transitions against `host`, staggered past the previous one's duration plus a
    /// settle gap. `Motion.morph` deliberately removes the in-flight animation when a new target arrives, so
    /// firing both at once would leave the later samples measuring the wrong transition.
    static func runAll(on host: NSView, log: @escaping (String) -> Void) {
        var start = 0.0
        for id in wiredTransitionIDs {
            guard let transition = MotionPlan.lookup(id) else { continue }
            let at = start
            DispatchQueue.main.asyncAfter(deadline: .now() + at) { run(transition, on: host, log: log) }
            start += transition.duration + 0.15
        }
    }

    /// The source rect each transition is given: **the shape its own call site uses**, chosen by the
    /// `Geometry` the plan declares for it (Ruling AJ4). Handing every transition one shared rect would make
    /// the log describe the probe's invention instead of the plan, and the switch being exhaustive over
    /// `Geometry` is what keeps that a compile-time property rather than a copy-paste.
    ///
    /// - `.growFromEdge` (`paneReveal`) reuses the very helper the production call site calls --
    ///   `MotionGeometry.revealEdge` -- so a probe and a pane cannot drift apart.
    /// - `.slideAndGrow` (`selectionSlide`) -- the selection pill's travel: production's source is the
    ///   pill's previous row rect shrunk about its centre (`MotionGeometry.slideAndGrowSource`), so the
    ///   probe synthesizes the same shape from a "previous row" one row-width to the left of the host.
    ///   Same helper as the pane, one spelling (Ruling AJ4).
    /// - `.positionCrossfade` is no production call site's shape today -- it belongs to the
    ///   `promptPresent` / `promptDismiss` pair Plan 4 will wire onto its prompt panel -- and the
    ///   sidebar-row-to-field line that used it was removed by user decision on 2026-10-29. The arm keeps
    ///   the switch exhaustive and gives Plan 4 the probe for free.
    static func sourceRect(for transition: Transition, final: CGRect) -> CGRect {
        switch transition.geometry {
        case .growFromEdge:      return MotionGeometry.revealEdge(for: final)
        case .slideAndGrow:      return MotionGeometry.slideAndGrowSource(
                                        previous: final.offsetBy(dx: -final.width, dy: 0))
        case .positionCrossfade: return final.offsetBy(dx: -final.width, dy: 0)
        }
    }

    /// Nothing is resized here: the probe reads the view's real frame, morphs it out of the source rect
    /// `sourceRect(for:final:)` picks for that transition, and samples what the layer paints. The animation
    /// is a transform, so the layout never changes and the caret in a neighbouring field cannot move.
    ///
    /// What "moving" means in the log: a transform animation does *not* change `bounds` -- the resting
    /// size stays the resting size, which is the point of morphing by transform. The evidence that the
    /// motion is geometric is `scale` (0.02 → 1 for the pane's zero-width grow after its clamp, 0.9 → 1
    /// for the selection pill's grow-in as it slides, 1.000 × 1.000 with a sliding `tx` for a
    /// crossfade) and `tx`/`ty` sliding to zero. `bounds` is logged alongside them precisely so a
    /// mistake that *did* resize the layer would show up here rather than being mistaken for the
    /// transform.
    private static func run(_ transition: Transition, on host: NSView, log: @escaping (String) -> Void) {
        let final = host.frame
        let source = sourceRect(for: transition, final: final)
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
