import Foundation

/// Scale and offset for a morph between two rects, expressed in the layer's own space so the driver
/// needs no coordinate conversion.
struct MorphTransform: Equatable {
    static let identity = MorphTransform(scale: CGSize(width: 1, height: 1), translation: .zero)
    let scale: CGSize
    let translation: CGSize
}

enum MotionGeometry {
    /// The smallest scale a morph may start from. Zero makes the transform degenerate and the layer
    /// unpaintable, which is the difference between "grows out of the gap" and "flashes".
    static let minimumScale: CGFloat = 0.02

    /// `source` and `final` must be in the same coordinate space. `flipped` names that space's
    /// `isFlipped`, so a caller states which way its y axis runs.
    ///
    /// It does **not** set the sign of the y offset, and that is a measurement rather than a reading of
    /// the documentation (`MotionDriverTests.testAFlippedContainerMovesTheSameWayItsOwnCoordinatesSay`,
    /// plus a control that converted the animated layer's rect into window coordinates): AppKit mirrors a
    /// view's flippedness into its layer tree -- the container's layer reports `isGeometryFlipped == true`
    /// exactly when the view reports `isFlipped == true`, and the morphing layer's `frame` equals the
    /// view's `frame` in both orientations -- so a `transform` translation runs along the very axis the
    /// rects are written on. Measured: `ty = +20` moved the unflipped layer 20 pt *up* in window
    /// coordinates and the flipped layer 20 pt *down*, i.e. toward larger `y` in each of their own spaces,
    /// which is what the rects already say. Negating `dy` for a flipped container therefore sent the
    /// morph's start 20 pt to the *far* side of the resting frame -- away from the gap it unfolds out of --
    /// and that was the defect Ruling AC #3 sent this back for. The offset is the rect gap as given, in
    /// either orientation.
    ///
    /// Consequence, stated rather than hidden: `flipped` is not an input this math reads. It stays in the
    /// signature because Ruling AC #3 rules which view the driver must ask, and retiring Task 9's produced
    /// API is Task 11's decision (where each transition gets its own real source rect), not a silent
    /// side effect of this round.
    ///
    /// Seam note: this file is `CGFloat` throughout while `MotionPlan`'s durations and curve parameters
    /// are `Double`; the driver (Task 10) owns the conversion.
    static func morph(source: CGRect, final: CGRect, flipped: Bool) -> MorphTransform {
        guard final.width > 0, final.height > 0 else { return .identity }
        let scale = CGSize(width: clamp(source.width / final.width),
                           height: clamp(source.height / final.height))
        // Not `flipped ? -dy : dy`, and not a typo: the layer's space *is* the rects' space. See above.
        let dy = source.midY - final.midY
        return MorphTransform(
            scale: scale,
            translation: CGSize(width: source.midX - final.midX, height: dy)
        )
    }

    /// Both divisors are guarded positive above, so a real rect pair cannot produce a non-finite ratio.
    private static func clamp(_ value: CGFloat) -> CGFloat {
        max(minimumScale, min(value, 1 / minimumScale))
    }
}
