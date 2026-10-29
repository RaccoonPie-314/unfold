import XCTest
@testable import Unfold

/// AppKit hands a layer-backed view a coordinate space whose y direction depends on the enclosing
/// view's flippedness. NSTableRowView is flipped; a plain container is not. One sign error and every
/// morph moves the wrong way, which reads as bad easing rather than bad math.
final class MotionGeometryTests: XCTestCase {
    private let final = CGRect(x: 100, y: 200, width: 300, height: 40)

    func testIdenticalRectsGiveIdentity() {
        let morph = MotionGeometry.morph(source: final, final: final, flipped: false)
        XCTAssertEqual(morph.scale, CGSize(width: 1, height: 1))
        XCTAssertEqual(morph.translation, .zero)
    }

    func testASourceAboveTheTargetPushesOppositeWaysInEachSpace() {
        let above = CGRect(x: 100, y: 260, width: 300, height: 40)
        XCTAssertEqual(MotionGeometry.morph(source: above, final: final, flipped: false).translation.height,
                       60, "unflipped: +y is up, so a source above is a positive offset")
        XCTAssertEqual(MotionGeometry.morph(source: above, final: final, flipped: true).translation.height,
                       -60, "flipped: +y is down, so the same source needs the opposite sign")
    }

    func testHeightRatioFollowsSourceOverTarget() {
        let halfHeight = CGRect(x: 100, y: 220, width: 300, height: 20)
        XCTAssertEqual(MotionGeometry.morph(source: halfHeight, final: final, flipped: true).scale,
                       CGSize(width: 1, height: 0.5))
    }

    /// Every other case in this file shares x and width between source and target, so the horizontal axis
    /// reads as identity no matter what the implementation does. `paneReveal` and `statusMorph` are
    /// horizontal transitions, so an implementation that hard-coded `scale.width = 1` and
    /// `translation.width = 0` would ship a pane that grows out of the wrong edge.
    func testHorizontalAxisIsNotAssumedIdentity() {
        let wide = CGRect(x: 100, y: 200, width: 300, height: 40)
        let narrowLeft = CGRect(x: 60, y: 200, width: 150, height: 40)
        for flipped in [false, true] {
            let morph = MotionGeometry.morph(source: narrowLeft, final: wide, flipped: flipped)
            XCTAssertEqual(morph.scale.width, 0.5, "flipped=\(flipped)")
            // midX 135 - midX 250: the narrow rect sits left of the wide one.
            XCTAssertEqual(morph.translation.width, -115, "flipped=\(flipped)")
            XCTAssertEqual(morph.translation.height, 0, "flipped=\(flipped)")
        }
    }

    /// A zero-height gap is what `scaleFromGap` starts from. A literal 0 scale collapses the layer to
    /// nothing and the transform degenerates, so it is clamped and the caller fades in across the ramp.
    func testZeroSourcedDimensionsAreClampedNotZero() {
        let gap = CGRect(x: 100, y: 220, width: 300, height: 0)
        let morph = MotionGeometry.morph(source: gap, final: final, flipped: true)
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
        let morph = MotionGeometry.morph(source: huge, final: final, flipped: false)
        let ceiling = 1 / MotionGeometry.minimumScale
        XCTAssertEqual(ceiling, 50)
        XCTAssertEqual(morph.scale.width, ceiling,
                       "a 100× ratio must stop exactly on 1/minimumScale, not run away from it")
        XCTAssertEqual(morph.scale.height, ceiling)
        // Just inside the ceiling, no clamping happens: the bound is a bound, not a magnet.
        let exact = CGRect(x: 100, y: 200, width: 15_000, height: 2_000)
        XCTAssertEqual(MotionGeometry.morph(source: exact, final: final, flipped: false).scale.width,
                       50, "a ratio landing exactly on the ceiling reads the same either way")
        let inside = CGRect(x: 100, y: 200, width: 12_000, height: 40)
        XCTAssertEqual(MotionGeometry.morph(source: inside, final: final, flipped: false).scale.width,
                       40, "40× is under 50× and must pass through untouched")
    }

    func testEmptyTargetIsRefusedWithIdentity() {
        let morph = MotionGeometry.morph(source: final, final: .zero, flipped: false)
        XCTAssertEqual(morph, .identity, "no scale or offset can be derived from a zero target")
    }
}
