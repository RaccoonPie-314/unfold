import AppKit
import XCTest
@testable import Unfold

/// Ruling AJ4: the probe may not measure a geometry no transition uses.
///
/// Before that ruling `MotionProbe` handed every wired transition the same zero-height full-width gap
/// under the host, so `paneReveal`'s logged numbers described a vertical grow the probe had invented.
/// These assertions are pure (no render cycle, no window): they pin the *shape* each wired transition is
/// given, and that it comes from the same helper the production call site calls -- which is what makes the
/// probe's log evidence about the app rather than about the probe. The row-motion and selection-line
/// transitions were removed by user decision on 2026-10-29; what is asserted here is the surviving set.
///
/// Mutation-proven: reverting `sourceRect(for:final:)` to a single shared rect fails
/// `testTheProbeNoLongerHandsEveryTransitionTheSameRect` and every shape assertion below that is not the
/// gap shape, because the gap sits under `maxY` and the rest are not.
final class MotionProbeTests: XCTestCase {
    /// A 200×120 stack at a non-trivial origin, so a rect that ignores `minX`/`minY` cannot pass by luck.
    private let final = CGRect(x: 40, y: 100, width: 200, height: 120)

    @MainActor
    func testTheProbeNoLongerHandsEveryTransitionTheSameRect() {
        let sources = Set(MotionProbe.wiredTransitionIDs.map {
            MotionProbe.sourceRect(for: MotionPlan.lookup($0)!, final: final)
        })
        XCTAssertEqual(sources.count, MotionProbe.wiredTransitionIDs.count,
                       "\(MotionProbe.wiredTransitionIDs.count) wired transitions, \(sources.count) "
                           + "distinct source rects: the probe is back "
                           + "to measuring one geometry for all of them")
    }

    // MARK: - one shape per call site

    @MainActor
    func testPaneRevealIsGivenAZeroWidthRectOnTheLeadingEdge() {
        let source = MotionProbe.sourceRect(for: plan(.paneReveal), final: final)
        XCTAssertEqual(source, MotionGeometry.revealEdge(for: final),
                       "the probe must use the helper `toggleDiagnostics` calls")
        XCTAssertEqual(source.width, 0,
                       "paneReveal is a horizontal grow: a full-width source is how it came to be logged "
                           + "as a vertical one")
        XCTAssertEqual(source.height, final.height)
        XCTAssertEqual(source.minX, final.minX, "it unfolds away from the divider, its own leading edge")
        XCTAssertEqual(source.minY, final.minY)
    }

    /// `selectionSlide` moves a **whole box**: the probe's source is the helper's previous-row rect shrunk
    /// about its centre, so it must sit left of the host (the travel) and inside it (the grow) -- a source
    /// that equals the final rect would morph identity onto identity and log a slide that is not there.
    @MainActor
    func testSelectionSlideIsGivenAGrownPreviousRowRect() {
        let source = MotionProbe.sourceRect(for: plan(.selectionSlide), final: final)
        XCTAssertEqual(source, MotionGeometry.slideAndGrowSource(
                                   previous: final.offsetBy(dx: -final.width, dy: 0)),
                       "the probe must use the helper the sidebar pill's call site calls")
        XCTAssertLessThan(source.midX, final.midX, "the pill travels from where it was, not from where it lands")
        XCTAssertLessThan(source.width, final.width)
        XCTAssertLessThan(source.height, final.height)
        XCTAssertEqual(source.width, final.width * MotionGeometry.slideGrowRatio, accuracy: 0.001,
                       "the grow is the helper's ratio, not a number the probe invented")
        XCTAssertEqual(source.height, final.height * MotionGeometry.slideGrowRatio, accuracy: 0.001)
        XCTAssertTrue(source.width > 0 && source.height > 0,
                      "a slide moves a box; a closed axis here is the deleted row-flash shape: \(source)")
    }

    // MARK: - the geometry enum is what drives the choice

    @MainActor
    func testEveryGeometryCaseIsCoveredAndNoTwoCasesShareARect() {
        // `Geometry` was declared and unread for the whole pass; the probe reading it is what makes the
        // per-transition shapes a compile-time-exhaustive property rather than a copy-paste.
        let cases: [Geometry] = [.growFromEdge, .positionCrossfade, .slideAndGrow]
        var byGeometry: [Geometry: CGRect] = [:]
        for geometry in cases {
            let transition = Transition(id: .paneReveal, duration: 0.2, curve: .spring(damping: 0.85),
                                        geometry: geometry, opacityRamp: 0.2)
            byGeometry[geometry] = MotionProbe.sourceRect(for: transition, final: final)
        }
        XCTAssertEqual(byGeometry.count, cases.count, "every `Geometry` case is exercised")
        XCTAssertEqual(Set(byGeometry.values).count, cases.count,
                       "\(cases.count) cases, \(Set(byGeometry.values).count) distinct source rects: the "
                           + "probe collapses them again (\(byGeometry))")
        for (geometry, rect) in byGeometry {
            switch geometry {
            case .growFromEdge:
                XCTAssertTrue(rect.width == 0 || rect.height == 0,
                              "\(geometry) is a gap or an edge, so one axis has to start closed: \(rect)")
            case .positionCrossfade, .slideAndGrow:
                XCTAssertTrue(rect.width > 0 && rect.height > 0,
                              "\(geometry) moves a whole box, not a closing gap: \(rect)")
            }
        }
    }

    private func plan(_ id: TransitionID) -> Transition {
        guard let transition = MotionPlan.lookup(id) else {
            XCTFail("\(id.rawValue) is not in the plan"); return MotionPlan.all[0]
        }
        return transition
    }
}
