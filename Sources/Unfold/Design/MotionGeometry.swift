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

    /// `source` and `final` must be in the same coordinate space. `flipped` is the enclosing view's
    /// `isFlipped`, which decides the sign of the y offset.
    static func morph(source: CGRect, final: CGRect, flipped: Bool) -> MorphTransform {
        guard final.width > 0, final.height > 0 else { return .identity }
        let scale = CGSize(width: clamp(source.width / final.width),
                           height: clamp(source.height / final.height))
        let dy = source.midY - final.midY
        return MorphTransform(
            scale: scale,
            translation: CGSize(width: source.midX - final.midX, height: flipped ? -dy : dy)
        )
    }

    private static func clamp(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 1 }
        return max(minimumScale, min(value, 1 / minimumScale))
    }
}
