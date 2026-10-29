import AppKit

/// Runs each transition on a real view and logs the measured presentation geometry, because "the
/// animation is real" has to be a number at three timestamps rather than a screenshot opinion.
@MainActor
enum MotionProbe {
    /// The transitions the probe runs: every id Plan 3 wires. `promptPresent` and `promptDismiss` are Plan
    /// 4's -- the panel they need does not exist yet -- and they are the only two in the plan this list omits,
    /// so `MotionProbeTests` can assert that each of the five reaches the probe with its own geometry.
    static let wiredTransitionIDs: [TransitionID] = [.rowInsert, .rowRemove, .selectionMorph,
                                                     .paneReveal, .statusMorph]

    /// Runs the five wired transitions against `host`, staggered past the previous one's duration plus a
    /// settle gap. `Motion.morph` deliberately removes the in-flight animation when a new target arrives, so
    /// firing all five at once would leave the later samples measuring the wrong transition.
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
    /// `Geometry` the plan declares for it (Ruling AJ4). Until now the probe handed all five the same
    /// zero-height full-width gap, so `paneReveal`'s and `statusMorph`'s logged numbers described a vertical
    /// grow neither of them performs and Ruling AC's promised "each transition gets its own real source rect"
    /// had arrived only at the production call sites.
    ///
    /// Three of the five reuse the helpers the production call sites call -- `MotionGeometry.insertionGap`,
    /// `collapseGap`, `revealEdge` -- so a probe and a pane cannot drift apart. The other two are transitions
    /// whose production source is *measured off another view* rather than derived, and one host view cannot
    /// be that other view; they get the same **shape**, and where a half of the real geometry is out of a
    /// single-host probe's reach that is said rather than papered over:
    ///
    /// - `.symbolMorph` (`statusMorph`) -- the pill's *width* change: same origin, same height, a different
    ///   width. Production's source is the pill's previous frame as the toolbar laid it out
    ///   (`MainWindowController.morphStatusPill(from:)`); the probe only has the host, so it synthesizes the
    ///   width change the call site expresses, at half the resting width.
    /// - `.positionCrossfade` (`selectionMorph`) -- the row-to-field travel: a rect the size of the host's,
    ///   displaced a full host-width toward the sidebar, i.e. the other pane. The pose therefore exercises
    ///   the x axis, which the old shared gap never touched. The pair's *scale* half (a ~40 pt row landing
    ///   on a 1 pt line) is not reproducible on a host whose resting frame is the landing, and it is
    ///   measured end-to-end where it really happens: `SelectionOverlayTests` asserts the installed start
    ///   pose is the sidebar row's rect and that the 1 pt line reads row-sized mid-flight.
    static func sourceRect(for transition: Transition, final: CGRect) -> CGRect {
        switch transition.geometry {
        case .scaleFromGap:      return MotionGeometry.insertionGap(for: final)
        case .collapseToGap:     return MotionGeometry.collapseGap(for: final)
        case .growFromEdge:      return MotionGeometry.revealEdge(for: final)
        case .symbolMorph:       return CGRect(x: final.minX, y: final.minY,
                                               width: final.width / 2, height: final.height)
        case .positionCrossfade: return final.offsetBy(dx: -final.width, dy: 0)
        }
    }

    /// Nothing is resized here: the probe reads the view's real frame, morphs it out of the source rect
    /// `sourceRect(for:final:)` picks for that transition, and samples what the layer paints. The animation
    /// is a transform, so the layout never changes and the caret in a neighbouring field cannot move.
    ///
    /// What "moving" means in the log: a transform animation does *not* change `bounds` -- the resting
    /// size stays the resting size, which is the point of morphing by transform. The evidence that the
    /// motion is geometric is `scale` (0.02 → 1 for a `scaleFromGap`, 0.5 → 1 for the pill's width change,
    /// 1.000 × 1.000 with a sliding `tx` for the crossfade) and `tx`/`ty` sliding to zero. `bounds` is
    /// logged alongside them precisely so a mistake that *did* resize the layer would show up here rather
    /// than being mistaken for the transform.
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
