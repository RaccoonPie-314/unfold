import AppKit
import UnfoldEngine
import UnfoldMac
import XCTest
@testable import Unfold

/// The pane dividers stop below the unified toolbar.
///
/// The user reported this twice. First on 2026-10-29 -- *"the separator on the diagnose bar is
/// overlapping"* -- which `5576ff0` answered by making the split view controller the window's
/// `contentViewController`. Then on 2026-10-30, with the Diagnostics pane open -- *"the separator line is
/// back"* -- which is the same defect, still present: the hierarchy change moved the divider's *x* and its
/// root wrapper, never its vertical span, and the only state captured afterwards was the closed one,
/// where a collapsed divider parks off the right edge and cannot be seen to be wrong.
///
/// The span is the mechanism, and it is measured, not inferred: the window carries
/// `.fullSizeContentView`, so the split view's frame reaches the top of the window
/// (`WindowHierarchyTests`: `(0, 0, 1470, 480)` against a `contentLayoutRect` 428 pt tall) and the panes
/// inset themselves from that underlap with a 52 pt safe area. `NSSplitView` has no such inset -- it hands
/// `drawDivider(in:)` "the entire divider rectangle in the receiver's coordinates" (`NSSplitView.h:48`).
/// `BandClippedSplitView` intersects that rect with the window's own `contentLayoutRect`, so the divider
/// ends where the chrome begins without this file hard-coding a toolbar height.
///
/// What is provable in-process here, in ascending strength:
/// * the clip function itself, on the measured numbers;
/// * the window really runs the clipping subclass, with the defaults `NSSplitViewController` would have
///   applied to its own split view (vertical, thin) -- a bare `NSSplitView` is horizontal and thick, so
///   this catches a lost assignment rather than a lost line; and
/// * the override sits on AppKit's **live drawing path**: a forced display pass reaches it. Without this
///   third test the fix could be a correct function nothing calls, which is exactly the shape of the
///   previous attempt.
final class DividerChromeClipTests: XCTestCase {
    // MARK: - the clip, as data

    /// The measured launch geometry: a 480 pt split view under a 52 pt band, so the chrome-free region is
    /// `contentLayoutRect` 0...428 and a full-height divider must land at 0...428 -- trimmed at the top, not
    /// shifted, and unchanged in x and thickness.
    func testClipTrimsTheDividerToTheChromeFreeBand() {
        let divider = NSRect(x: 218, y: 0, width: 1, height: 480)
        let band = NSRect(x: 0, y: 0, width: 1470, height: 428)

        let clipped = BandClippedSplitView.clip(divider, to: band)

        XCTAssertEqual(clipped, NSRect(x: 218, y: 0, width: 1, height: 428),
                       "clipping moved the divider in x or changed its thickness; only the span along the "
                           + "divider is ours to trim — the position and hit rect stay AppKit's")
        XCTAssertEqual(clipped.maxY, band.maxY, accuracy: 0.001,
                       "the divider still reaches past the bottom edge of the titlebar band")
    }

    /// A divider entirely under the chrome draws nothing, and a band that was never measured must not
    /// silently erase every divider in the window.
    func testClipHandlesBothExtremes() {
        let divider = NSRect(x: 218, y: 440, width: 1, height: 40)
        XCTAssertTrue(BandClippedSplitView.clip(divider, to: NSRect(x: 0, y: 0, width: 1470, height: 428)).isEmpty,
                      "a divider wholly inside the band must not be drawn")
        XCTAssertEqual(BandClippedSplitView.clip(divider, to: .zero), divider,
                       "an unavailable chrome measurement must pass the divider through, not delete it")
    }

    // MARK: - the clip, on the live view

    @MainActor
    func testTheWindowRunsTheClippingSplitView() throws {
        let controller = try makeController()
        defer { controller.window?.orderOut(nil) }

        let split = try XCTUnwrap(controller.splitViewForProbe)
        XCTAssertTrue(split is BandClippedSplitView,
                      "the window's split view is \(type(of: split)) — the `splitView.splitView =` "
                          + "assignment in `assembleSplitView` runs after the controller's view loaded, "
                          + "which is the one thing `NSSplitViewController.h:31` forbids")
        XCTAssertTrue(split.isVertical, "a supplied split view must restate the controller's own defaults")
        XCTAssertEqual(split.dividerStyle, .thin)
    }

    /// The decisive one: a real display pass reaches the override, and what reaches `super` stays inside
    /// the chrome-free band. If AppKit ever moves divider painting into a sublayer this goes red rather
    /// than leaving a dead subclass shipping.
    @MainActor
    func testADisplayPassDrawsTheDividerInsideTheBand() throws {
        let controller = try makeController()
        defer { controller.window?.orderOut(nil) }
        let window = try XCTUnwrap(controller.window)
        let split = try XCTUnwrap(controller.splitViewForProbe as? BandClippedSplitView)
        controller.setDiagnosticsCollapsedForProbe(false)
        split.layoutSubtreeIfNeeded()

        guard let host = window.contentView,
              let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            return XCTFail("no bitmap to force a display pass into, so the drawing path is unmeasured")
        }
        host.cacheDisplay(in: host.bounds, to: rep)

        let drawn = try XCTUnwrap(split.lastDrawnDividerRect,
                                  "a display pass never reached `drawDivider(in:)`, so the clip is a "
                                      + "correct function nothing calls — AppKit is painting dividers "
                                      + "somewhere else and this fix is dead code")
        let band = split.convert(window.contentLayoutRect, from: host)
        XCTAssertGreaterThan(band.height, 0)
        XCTAssertLessThan(drawn.height, split.bounds.height,
                          "the divider drew its full \(drawn.height) pt span — nothing was clipped, so it "
                              + "still crosses the \(split.bounds.height - band.height) pt titlebar band")
        XCTAssertLessThanOrEqual(drawn.maxY, band.maxY + 0.5,
                                 "the divider reaches y=\(drawn.maxY) but the chrome ends at y=\(band.maxY)")
    }

    // MARK: - fixture

    /// The same fixture discipline as `WindowHierarchyTests`: a real controller over a scratch store, its
    /// window ordered front off the corner of any plausible display, drained so the toolbar chrome and the
    /// safe-area propagation exist.
    @MainActor
    private func makeController() throws -> MainWindowController {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("unfold-divider-clip-\(UUID().uuidString)", isDirectory: true)
        let store = Store(url: directory.appendingPathComponent("combos.json"))
        try store.save(CombosFile(formatVersion: CombosFile.currentFormatVersion, combos: []))

        let controller = MainWindowController(coordinator: ExpansionCoordinator(combos: []), store: store)
        let window = try XCTUnwrap(controller.window)
        window.setFrameOrigin(NSPoint(x: -3_200, y: -1_800))
        window.orderFrontRegardless()
        let deadline = Date().addingTimeInterval(0.15)
        while Date() < deadline {
            RunLoop.main.run(until: min(deadline, Date().addingTimeInterval(0.005)))
        }
        return controller
    }
}
