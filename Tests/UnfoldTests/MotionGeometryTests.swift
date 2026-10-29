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

    func testScaleIsSourceOverTargetInBothAxes() {
        let halfHeight = CGRect(x: 100, y: 220, width: 300, height: 20)
        XCTAssertEqual(MotionGeometry.morph(source: halfHeight, final: final, flipped: true).scale,
                       CGSize(width: 1, height: 0.5))
    }

    /// A zero-height gap is what `scaleFromGap` starts from. A literal 0 scale collapses the layer to
    /// nothing and the transform degenerates, so it is clamped and the caller fades in across the ramp.
    func testZeroSourcedDimensionsAreClampedNotZero() {
        let gap = CGRect(x: 100, y: 220, width: 300, height: 0)
        let morph = MotionGeometry.morph(source: gap, final: final, flipped: true)
        XCTAssertGreaterThan(morph.scale.height, 0)
        XCTAssertLessThan(morph.scale.height, 0.05)
        XCTAssertEqual(morph.scale.width, 1)
    }

    func testEmptyTargetIsRefusedWithIdentity() {
        let morph = MotionGeometry.morph(source: final, final: .zero, flipped: false)
        XCTAssertEqual(morph.scale, CGSize(width: 1, height: 1), "no scale can be derived from zero")
    }
}
