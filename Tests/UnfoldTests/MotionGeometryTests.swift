import XCTest
@testable import Unfold

/// AppKit gives a layer-backed view's layer the **same** frame as the view, and the container's layer
/// the same y direction as the view's own space (`isGeometryFlipped` mirrors `isFlipped` -- measured in
/// `MotionDriverTests.testAFlippedContainerMovesTheSameWayItsOwnCoordinatesSay`). A `transform`
/// translation therefore runs along the axis the rects are written on, whichever way that axis points,
/// so the offset is the rect gap as given and there is nothing to negate. That is the opposite of what
/// this file asserted until Task 10 measured it: the old test pinned `flipped: true` to the negated
/// offset, and the layer it drove moved away from its source instead of toward it.
///
/// There is consequently no `flipped` parameter here (Ruling AE deleted it): orientation is not an
/// input this math reads, and an unread parameter implying a rule that does not exist is worse than no
/// parameter. What the rects' space does not carry is the layer's anchor -- that compensation lives in
/// `Motion` and is measured in `MotionDriverTests`, not asserted here.
final class MotionGeometryTests: XCTestCase {
    private let final = CGRect(x: 100, y: 200, width: 300, height: 40)

    func testIdenticalRectsGiveIdentity() {
        let morph = MotionGeometry.morph(source: final, final: final)
        XCTAssertEqual(morph.scale, CGSize(width: 1, height: 1))
        XCTAssertEqual(morph.translation, .zero)
    }

    /// The gap in y is exactly `source.midY - final.midY`, because the layer's space is the container's
    /// space: `+y` means up in an unflipped view and down in a flipped one, and the rects handed to this
    /// function are written the same way. Negating that for a flipped container put the morph's start on
    /// the far side of the resting frame; Task 10's driver test measures that, and Ruling AE retired the
    /// parameter that pretended the choice existed.
    func testTheYOffsetIsTheRectGapAsGiven() {
        let numericallyAbove = CGRect(x: 100, y: 260, width: 300, height: 40)
        XCTAssertEqual(MotionGeometry.morph(source: numericallyAbove, final: final).translation.height,
                       60, "the offset is the gap the rects state, not its negation")
        // And the mirror: a numerically smaller y is 60 the other way in either space.
        let numericallyBelow = CGRect(x: 100, y: 140, width: 300, height: 40)
        XCTAssertEqual(MotionGeometry.morph(source: numericallyBelow, final: final).translation.height,
                       -60)
    }

    func testHeightRatioFollowsSourceOverTarget() {
        let halfHeight = CGRect(x: 100, y: 220, width: 300, height: 20)
        XCTAssertEqual(MotionGeometry.morph(source: halfHeight, final: final).scale,
                       CGSize(width: 1, height: 0.5))
    }

    /// Every other case in this file shares x and width between source and target, so the horizontal axis
    /// reads as identity no matter what the implementation does. `paneReveal` and `statusMorph` are
    /// horizontal transitions, so an implementation that hard-coded `scale.width = 1` and
    /// `translation.width = 0` would ship a pane that grows out of the wrong edge.
    func testHorizontalAxisIsNotAssumedIdentity() {
        let wide = CGRect(x: 100, y: 200, width: 300, height: 40)
        let narrowLeft = CGRect(x: 60, y: 200, width: 150, height: 40)
        let morph = MotionGeometry.morph(source: narrowLeft, final: wide)
        XCTAssertEqual(morph.scale.width, 0.5)
        // midX 135 - midX 250: the narrow rect sits left of the wide one.
        XCTAssertEqual(morph.translation.width, -115)
        XCTAssertEqual(morph.translation.height, 0)
    }

    /// A zero-height gap is what `scaleFromGap` starts from. A literal 0 scale collapses the layer to
    /// nothing and the transform degenerates, so it is clamped and the caller fades in across the ramp.
    func testZeroSourcedDimensionsAreClampedNotZero() {
        let gap = CGRect(x: 100, y: 220, width: 300, height: 0)
        let morph = MotionGeometry.morph(source: gap, final: final)
        XCTAssertEqual(MotionGeometry.minimumScale, 0.02)
        XCTAssertEqual(morph.scale.height, MotionGeometry.minimumScale,
                       "a clamped zero must land exactly on the floor, not merely under 0.05")
        XCTAssertEqual(morph.scale.width, 1)
    }

    /// The same clamp has a ceiling at the reciprocal, 50×, and Task 10 relies on it: `Motion.morph`
    /// may be handed a source rect *larger* than its target (a pane closing onto a small pill), where
    /// an unclamped ratio would fling the layer's scale tens or hundreds of times past the frame. The
    /// floor was asserted above; without this the ceiling was the one bound nothing touched.
    func testSourceLargerThanTargetIsClampedAtTheReciprocalCeiling() {
        // 100× the target on both axes -- comfortably past the 50× ceiling, so the clamp must bite.
        let huge = CGRect(x: 100, y: 200, width: 30_000, height: 4_000)
        let morph = MotionGeometry.morph(source: huge, final: final)
        let ceiling = 1 / MotionGeometry.minimumScale
        XCTAssertEqual(ceiling, 50)
        XCTAssertEqual(morph.scale.width, ceiling,
                       "a 100× ratio must stop exactly on 1/minimumScale, not run away from it")
        XCTAssertEqual(morph.scale.height, ceiling)
        // Just inside the ceiling, no clamping happens: the bound is a bound, not a magnet.
        let exact = CGRect(x: 100, y: 200, width: 15_000, height: 2_000)
        XCTAssertEqual(MotionGeometry.morph(source: exact, final: final).scale.width,
                       50, "a ratio landing exactly on the ceiling reads the same either way")
        let inside = CGRect(x: 100, y: 200, width: 12_000, height: 40)
        XCTAssertEqual(MotionGeometry.morph(source: inside, final: final).scale.width,
                       40, "40× is under 50× and must pass through untouched")
    }

    func testEmptyTargetIsRefusedWithIdentity() {
        let morph = MotionGeometry.morph(source: final, final: .zero)
        XCTAssertEqual(morph, .identity, "no scale or offset can be derived from a zero target")
    }
}
