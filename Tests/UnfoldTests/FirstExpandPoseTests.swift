import AppKit
import UnfoldEngine
import UnfoldMac
import XCTest
@testable import Unfold

/// The pose the **first** Diagnostics expansion starts from.
///
/// The user's report of 2026-10-30: *"another bug with the diagnose panel is the initial expanding, it
/// only happen once during the first time clicking on the diagnose button to see the panel. So basically
/// when clicked, it doesnt just slide out, it flew from the left side awkwardly, after that it expand
/// normal smoothly."*
///
/// Measured mechanism, on a launch-closed pane in a 900 × 580 window (numbers from the probe that was
/// run against the unfixed code, and from the same probe on the `60c5a4e` tree -- identical, which is how
/// we know the `5576ff0` material/hierarchy change did not cause it):
///
/// | | launch (unfixed) | after one open/close cycle |
/// |---|---|---|
/// | item wrapper frame | `(0, 0, 230, 0)` -- leading edge, **zero height** | `(bounds.maxX, 0, 230, 580)` |
/// | item divider frame | `(-2, 0, 5, 580)` -- off the **left** edge | `(bounds.maxX − 3, 0, 5, 580)` |
/// | pane view superview | **nil** -- not in the hierarchy | the wrapper |
/// | pane view frame | `(0, 0, 0, 0)` | `(0, 0, 230, 580)` |
/// | inner stack frame | `(0, 0, 0, 0)` | `(0, 124, 230, 404)` |
/// | safe-area top inset | `0` | `52` |
///
/// An `NSSplitViewItem` inserted already collapsed is first laid out at the *leading* edge, and AppKit
/// only replaces that stale pose during the first uncollapse. Because `60c5a4e` made the reveal a
/// divider move inside one `NSAnimationContext` with implicit animation on, that first pass interpolates
/// the wrapper -- and the material and controls riding inside it -- from `x = 0` across the whole window:
/// the fly-in. Every later expansion starts from the pose the first one established, which is why it
/// happens exactly once. `prewarmDiagnosticsCollapsePose(_:)` establishes that pose before anything can
/// animate, by running the production collapse path synchronously once.
///
/// What the harness can and cannot see: the CA-driven glide is not pumped by the command-line run loop
/// (see `DiagnosticsDividerTests`), so these tests assert the **start geometry** -- the numbers above, all
/// of which are model-frame facts -- not the in-between frames. Whether the glide now reads as a slide
/// out of the right edge is a live-pass observation.
///
/// Mutation-proven three ways, each run and read before reverting:
/// * with the `prewarmDiagnosticsCollapsePose(window)` call removed from `init`, the first test dies on its
///   very first assertion -- "the Diagnostics pane's view has no superview before the first expansion" -- and
///   the second reports the mechanism in numbers: the first expansion starts at x ratio **0.0** of the split
///   view and height ratio **0.0**, with a **0 × 0** material view, where the second starts at **1.0** /
///   **1.0** with a 230 × 480 one;
/// * with the warm-up left open (its closing step removed), so it "fixes" the fly-in by showing the pane,
///   the third test fails twice -- the item is open at launch and reports 230 pt of on-screen width. That is
///   the guard that keeps this a pre-warm rather than a pane that starts unfolded;
/// * with the warm-up's frame restoration removed, the third test's last assertion fails -- the window
///   launches 1198 pt wide against the designed 900, because AppKit grew it to fit the opened pane and never
///   shrank it back. That is the guard that keeps the fix from buying a layout defect.
final class FirstExpandPoseTests: XCTestCase {
    /// The window's frame-autosave key, shared by every `MainWindowController` in this process and
    /// persisted into the `swift test` domain (`com.apple.dt.xctest.tool`). These tests open and close the
    /// pane, which grows and shrinks the window, and AppKit writes the frame as it goes; the size the *next*
    /// controller restores decides where the sidebar's 218 pt divider lands, which is a fact other test files
    /// assert. So the value is snapshotted before each test and put back afterwards, leaving the domain as
    /// this file found it.
    private static let frameKey = "NSWindow Frame UnfoldMainWindow"
    private var savedFrame: Any?

    override func setUp() {
        super.setUp()
        savedFrame = UserDefaults.standard.object(forKey: Self.frameKey)
    }

    override func tearDown() {
        if let savedFrame {
            UserDefaults.standard.set(savedFrame, forKey: Self.frameKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.frameKey)
        }
        UserDefaults.standard.synchronize()
        super.tearDown()
    }

    /// Before the first animated expansion the pane's material view is in the hierarchy, laid out, and
    /// parked off the **trailing** edge -- the pose a collapsed trailing pane is supposed to start from.
    @MainActor
    func testTheCollapsedPaneIsLaidOutBeforeTheFirstExpansion() throws {
        let (controller, split, pane) = try fixture()
        defer { controller.window?.orderOut(nil) }

        let wrapper = try XCTUnwrap(pane.view.superview,
                                    "the Diagnostics pane's view has no superview before the first "
                                        + "expansion — AppKit has never laid the collapsed item out, so "
                                        + "the first animated divider move interpolates it from the "
                                        + "leading edge: the fly-in the user reported")
        // The structural fact this file depends on is *which* view rides the divider -- the pane's own,
        // sitting directly in AppKit's split-item wrapper. Whether that view is a material or a plain
        // container has changed twice (5576ff0 made it an `NSVisualEffectView`, the 2026-10-30
        // window-wide-backing fix made it an `NSView`) and is not this test's business.
        XCTAssertTrue(String(describing: type(of: wrapper)).contains("SplitViewItemViewWrapper"),
                      "the pane's view is inside \(type(of: wrapper)), not directly in AppKit's "
                          + "split-item wrapper — this file would be measuring the wrong view's pose")
        XCTAssertGreaterThan(wrapper.frame.width, 0,
                             "the collapsed item's wrapper is \(wrapper.frame.width) pt wide before the "
                                 + "first expansion; the launch pose is the stale (thickness × 0) one")
        XCTAssertEqual(wrapper.frame.height, split.bounds.height, accuracy: 1.0,
                       "the collapsed wrapper is \(wrapper.frame.height) pt tall in a "
                           + "\(split.bounds.height) pt split view before the first expansion, so the "
                           + "expansion also animates a resize")
        // Parked on the right, never at the leading edge. Which side of the trailing edge the hidden
        // wrapper sits on is AppKit's choice (measured: just beyond `bounds.maxX`, and after a resize
        // re-laid-out at the open position inside the bounds, `isHidden` still true) -- so the claim this
        // test needs is "not at x = 0", expressed against the bounds so it does not depend on what the
        // frame autosave restored.
        XCTAssertGreaterThanOrEqual(wrapper.frame.minX, split.bounds.midX,
                                    "the collapsed wrapper starts at x=\(wrapper.frame.minX) in a "
                                        + "\(split.bounds.maxX) pt split view: the pane is parked on the "
                                        + "left, and the first divider move drags it across the window — "
                                        + "the fly-in the user reported")
        // The material view is laid out to the geometry it is displayed in once open, not to zero.
        XCTAssertEqual(pane.view.frame.origin, .zero,
                       "the pane's material view sits at \(pane.view.frame.origin) inside its wrapper "
                           + "before the first expansion; it must already fill the wrapper")
        XCTAssertEqual(pane.view.frame.width, wrapper.frame.width, accuracy: 1.0,
                       "the pane's material view is \(pane.view.frame.width) pt wide against a "
                           + "\(wrapper.frame.width) pt wrapper before the first expansion")
        XCTAssertEqual(pane.view.frame.height, split.bounds.height, accuracy: 1.0,
                       "the pane's material view is \(pane.view.frame.height) pt tall in a "
                           + "\(split.bounds.height) pt split view before the first expansion; it "
                           + "should already carry the open geometry so nothing but the divider moves")
        XCTAssertFalse(pane.view.subviews.isEmpty,
                       "the pane's content was never placed inside the material view")
        let stack = try XCTUnwrap(pane.view.subviews.first, "the pane's inner stack")
        XCTAssertGreaterThan(stack.frame.height, 0,
                             "the diagnostics stack is \(stack.frame.height) pt tall before the first "
                                 + "expansion, so the first expansion animates its very first layout")
        XCTAssertEqual(pane.view.safeAreaInsets.top,
                       controller.window!.frame.height - controller.window!.contentLayoutRect.height,
                       accuracy: 1.0,
                       "the collapsed pane has not been placed under the toolbar's safe area "
                           + "(top inset \(pane.view.safeAreaInsets.top)); the stack pinned to it jumps "
                           + "by that inset during the first expansion")
    }

    /// The first expansion and the second one start from the same geometry -- the one-time-only half of
    /// the report. Everything is expressed relative to the split view's bounds because opening the pane
    /// grows the window (AppKit sizes a `contentViewController` window to its content), on both passes.
    @MainActor
    func testTheFirstAndSecondExpansionsStartFromTheSamePose() throws {
        let (controller, split, pane) = try fixture()
        defer { controller.window?.orderOut(nil) }

        let beforeFirst = Self.startPose(split: split, wrapperOf: pane.view)
        controller.toggleDiagnostics(nil)
        drain(0.5)
        controller.toggleDiagnostics(nil)
        drain(0.5)
        let beforeSecond = Self.startPose(split: split, wrapperOf: pane.view)

        // The three things that define the start of the motion. Which side of `bounds.maxX` the hidden
        // wrapper sits on is AppKit's business (measured: just past it after the warm-up's park, and back
        // at the open position when a resize re-lays the collapsed item out -- a drift that hits a cycled
        // pane identically, R1/R2 in the probe), so the claim is expressed as "parked on the right-hand
        // side, laid out to the full height, with the material view already carrying the geometry it will
        // be shown in". Unfixed, the first pass starts at x ratio 0 with height ratio 0 and a
        // zero-frame material view that has no superview, while the second starts at 1.0/1.0 -- two
        // different animations, which is exactly the one-time-only report.
        // What the start of the motion is asserted on, and what deliberately is NOT asserted. The three
        // claims below are the mechanism: the pane is parked on the right-hand side (unfixed: x ratio 0.0),
        // it already holds the split view's full height (unfixed: 0.0), and the material view already
        // carries the frame it will be shown with (unfixed: no superview, `CGRect.zero`).
        // Which side of `bounds.maxX` the *hidden* wrapper sits on is not claimable: measured, it rests
        // just past `maxX` in one context and at the open position `maxX − 230` in another (a wide
        // autosaved frame, or any layout pass after the park), and a pane that has been cycled drifts the
        // same way -- probe runs R1/R2 measured a cycled pane starting a later expansion from
        // `maxX − 120` after the same kind of resize. That is AppKit's collapsed-item bookkeeping, it is
        // common to first and later expansions, and the fly-in was never about it.
        XCTAssertGreaterThanOrEqual(beforeFirst.wrapperMinXRatio, 0.5,
                                    "the first expansion starts at x ratio \(beforeFirst.wrapperMinXRatio) "
                                        + "of the split view: the pane is parked on the left half, which is "
                                        + "where it flies across the window from")
        XCTAssertGreaterThanOrEqual(beforeSecond.wrapperMinXRatio, 0.5,
                                    "the second expansion starts at x ratio \(beforeSecond.wrapperMinXRatio) "
                                        + "— the reference pose itself is not on the right-hand side")
        XCTAssertEqual(beforeFirst.heightRatio, beforeSecond.heightRatio, accuracy: 0.02,
                       "the first expansion starts at height ratio \(beforeFirst.heightRatio) and the "
                           + "second at \(beforeSecond.heightRatio) — only the first pass has to lay "
                           + "the pane out vertically")
        XCTAssertEqual(beforeFirst.materialFrame.width, beforeSecond.materialFrame.width, accuracy: 1.0,
                       "the material view is \(beforeFirst.materialFrame.width) pt wide at the first "
                           + "expansion's start and \(beforeSecond.materialFrame.width) pt at the second's")
        XCTAssertEqual(beforeFirst.materialFrame.height, beforeSecond.materialFrame.height, accuracy: 1.0,
                       "the material view is \(beforeFirst.materialFrame.height) pt tall at the first "
                           + "expansion's start and \(beforeSecond.materialFrame.height) pt at the "
                           + "second's — the first pass animates the pane's very first layout")
        XCTAssertEqual(beforeFirst.materialOrigin, beforeSecond.materialOrigin,
                       "the material view starts at \(beforeFirst.materialOrigin) on the first expansion "
                           + "and \(beforeSecond.materialOrigin) on the second")
    }

    /// Pre-warming is not "start the app with the pane open", and it is not "start the app with a wider
    /// window": after the warm-up the item is still collapsed, still shows nothing on screen, and the
    /// window is still the size `restoreFrame` settled. The last claim is the one the warm-up threatens,
    /// because AppKit sizes a `contentViewController` window to its content's fitting size while the pane
    /// is open (measured: 900 × 580 → 1131 × 580) and does not undo that on close.
    @MainActor
    func testThePrewarmStillLeavesThePaneClosedAtLaunch() throws {
        let (controller, _, _) = try fixture()
        defer { controller.window?.orderOut(nil) }
        let window = try XCTUnwrap(controller.window)

        XCTAssertTrue(controller.diagnosticsPaneCollapsed,
                      "the Diagnostics item is open at launch — the pose warm-up has to end collapsed")
        XCTAssertEqual(controller.diagnosticsPaneWidth, 0, accuracy: 1.0,
                       "the launch-closed pane shows \(controller.diagnosticsPaneWidth) pt of width "
                           + "inside the split view; the warm-up must leave it off screen, not unfold it "
                           + "over the editor")
        XCTAssertLessThanOrEqual(window.frame.width,
                                 MainWindowController.designedContentSize.width
                                     + MainWindowController.diagnosticsExpandedWidth - 30,
                                 "the window launches \(window.frame.width) pt wide against the designed "
                                     + "\(MainWindowController.designedContentSize.width) pt: the warm-up "
                                     + "grew it to fit the opened pane (measured 1131 pt) and never shrank "
                                     + "it back, so the fix bought a new layout defect")
    }

    // MARK: - fixture

    private struct StartPose {
        /// `wrapper.minX / split.bounds.maxX`: ~0.85-1.0 for a pane parked at the trailing edge, 0 for one
        /// left at the leading edge -- the stale launch pose, and the distance the fly-in travels.
        let wrapperMinXRatio: CGFloat
        /// `wrapper.height / split.bounds.height`: 1 for a laid-out pane, 0 for the stale launch pose.
        let heightRatio: CGFloat
        /// The material view's frame **inside** its wrapper -- the geometry it is shown with once open.
        let materialFrame: NSRect
        let materialOrigin: NSPoint
    }

    private static func startPose(split: NSSplitView, wrapperOf paneView: NSView) -> StartPose {
        let wrapper = paneView.superview ?? paneView
        return StartPose(wrapperMinXRatio: split.bounds.maxX > 0
                                ? wrapper.frame.minX / split.bounds.maxX : 0,
                         heightRatio: split.bounds.height > 0
                             ? wrapper.frame.height / split.bounds.height : 0,
                         materialFrame: paneView.frame,
                         materialOrigin: paneView.frame.origin)
    }

    /// The same fixture discipline as `DiagnosticsDividerTests`: a real controller over a scratch store,
    /// its window ordered front off the corner of any plausible display, drained so the toolbar chrome and
    /// the safe-area propagation exist. The frame-autosave key is cleared first (and put back in
    /// `tearDown`) so the launch geometry is the designed one for every run of this file, instead of
    /// whatever width the previous test process happened to leave in the shared `swift test` domain -- the
    /// pose and the window-size claims below are both stated against that designed size.
    @MainActor
    private func fixture() throws -> (MainWindowController, NSSplitView, DiagnosticsViewController) {
        _ = NSApplication.shared
        UserDefaults.standard.removeObject(forKey: Self.frameKey)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("unfold-first-expand-pose-\(UUID().uuidString)", isDirectory: true)
        let store = Store(url: directory.appendingPathComponent("combos.json"))
        try store.save(CombosFile(formatVersion: CombosFile.currentFormatVersion, combos: []))

        let controller = MainWindowController(coordinator: ExpansionCoordinator(combos: []), store: store)
        let window = try XCTUnwrap(controller.window)
        window.setFrameOrigin(NSPoint(x: -3_200, y: -1_800))
        window.orderFrontRegardless()
        drain(0.15)

        let split = try XCTUnwrap(controller.splitViewForProbe)
        split.layoutSubtreeIfNeeded()
        return (controller, split, controller.diagnosticsPaneForProbe)
    }

    @MainActor
    private func drain(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.main.run(until: min(deadline, Date().addingTimeInterval(0.005)))
        }
    }
}
