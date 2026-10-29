import Foundation

/// Scale and centre displacement for a morph between two rects, expressed in the layer's own space so
/// the driver needs no coordinate conversion. The translation is between the rect *centres*; the layer's
/// anchor is not a rect fact, and `Motion` compensates for it (`MotionGeometry.morph`'s comment).
struct MorphTransform: Equatable {
    static let identity = MorphTransform(scale: CGSize(width: 1, height: 1), translation: .zero)
    let scale: CGSize
    let translation: CGSize
}

enum MotionGeometry {
    /// The smallest scale a morph may start from. Zero makes the transform degenerate and the layer
    /// unpaintable, which is the difference between "grows out of the gap" and "flashes".
    static let minimumScale: CGFloat = 0.02

    /// `source` and `final` must be in the same coordinate space.
    ///
    /// The result is a relation between two rects and nothing more: the size ratios and the
    /// displacement between their centres. It is deliberately **anchor-agnostic**. A layer paints a
    /// transform about its own `anchorPoint`, so a centre displacement lands a scaled rect on `source`
    /// exactly only when that anchor is `(0.5, 0.5)`; any other anchor must add `(1 − k) · size ·
    /// (0.5 − anchor)` per axis, where `k` is the start scale. The anchor is a layer fact, not a rect
    /// fact, so that compensation is `Motion`'s job (Ruling AE), read from the real layer at the real
    /// call -- not a constant assumed here.
    ///
    /// There is no `flipped` parameter, and Task 9 had one. It was deleted here (Ruling AE) because
    /// Task 10 measured that no flip compensation exists: AppKit mirrors a view's flippedness into the
    /// layer tree -- the container's layer reports `isGeometryFlipped == true` exactly when the view
    /// reports `isFlipped == true`, and the morphing layer's frame equals the view's frame in both
    /// orientations (`MotionDriverTests.testAFlippedContainerMovesTheSameWayItsOwnCoordinatesSay`) --
    /// so a `transform` translation runs along the very axis the rects are written on, whichever way
    /// it points, and the rects handed in here already carry that direction. An unread parameter that
    /// implied a rule which does not exist was worse than no parameter.
    ///
    /// Seam note: this file is `CGFloat` throughout while `MotionPlan`'s durations and curve parameters
    /// are `Double`; the driver (Task 10) owns the conversion.
    static func morph(source: CGRect, final: CGRect) -> MorphTransform {
        guard final.width > 0, final.height > 0 else { return .identity }
        let scale = CGSize(width: clamp(source.width / final.width),
                           height: clamp(source.height / final.height))
        return MorphTransform(
            scale: scale,
            translation: CGSize(width: source.midX - final.midX, height: source.midY - final.midY)
        )
    }

    /// Both divisors are guarded positive above, so a real rect pair cannot produce a non-finite ratio.
    private static func clamp(_ value: CGFloat) -> CGFloat {
        max(minimumScale, min(value, 1 / minimumScale))
    }

    // MARK: - source poses
    //
    // The rects a call site *derives* from a final frame, as opposed to measures off another view. They live
    // here, next to the math that reads them, because the production call sites
    // (`SidebarViewController.animate(_:)`, `MainWindowController.toggleDiagnostics`) and `MotionProbe` need
    // the same one: the probe exists to log the geometry a transition actually performs, so a probe holding
    // its own copy of the rect -- or one rect for all five, which is what it used to hand (Ruling AJ4) --
    // measures its own invention instead of the plan.

    /// The gap an arriving row unfolds out of: its own baseline edge, zero height. A flipped table puts
    /// `maxY` on the line the row's text sits on, so the gap opens below the text and the row grows into it.
    static func insertionGap(for final: CGRect) -> CGRect {
        CGRect(x: final.minX, y: final.maxY, width: final.width, height: 0)
    }

    /// The line a departed row's gap closes onto: the top edge of the row that took its slot. With
    /// contiguous rows the neighbour above shares that exact line (`above.maxY == occupant.minY`), which is
    /// why `animate(_:)` can read the real neighbour when it has one, fall back to this when it does not,
    /// and hand `rowRemove` the same rect either way.
    static func collapseGap(for final: CGRect) -> CGRect {
        CGRect(x: final.minX, y: final.minY, width: final.width, height: 0)
    }

    /// A revealed pane's leading edge: zero width, full height, on the divider side, so the content unfolds
    /// away from the divider rather than out of a generic baseline.
    static func revealEdge(for final: CGRect) -> CGRect {
        CGRect(x: final.minX, y: final.minY, width: 0, height: final.height)
    }
}
