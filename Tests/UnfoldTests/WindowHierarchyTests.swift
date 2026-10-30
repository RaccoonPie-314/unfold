import AppKit
import UnfoldEngine
import UnfoldMac
import XCTest
@testable import Unfold

/// The window hierarchy that puts the split view controller in charge of the content region.
///
/// **Outcome of the live pass this file deferred to, 2026-10-30: the hierarchy does not clip the
/// dividers.** The user reported the same line again with the Diagnostics pane open ("the separator line
/// is back"), and the measurement below is why. The clip is `BandClippedSplitView`, asserted by
/// `DividerChromeClipTests`; this file's claim is the structure, and it still holds.
///
/// The user's screenshot of 2026-10-29: *"the separator on the diagnose bar is overlapping"* -- the
/// editor/diagnostics divider ran the full height of the window, straight up through the translucent
/// unified toolbar. Measured cause, probed on the old hierarchy before touching anything: the window's
/// `contentViewController` was a plain root `NSViewController` whose `Glass.windowBackground()` view
/// filled the window, with the `NSSplitViewController` pinned inside it as a child -- the split view's
/// frame spanned 0...480 pt while the titlebar+toolbar band is 52 pt (`contentLayoutRect` 428 of a 480
/// window), and AppKit's chrome does not clip dividers of a split view it does not own as content.
///
/// The fix is the standard hierarchy: `window.contentViewController = splitViewController` (what Notes
/// and Music-class apps do). That drops the root *view controller* wrapper, which is what had the
/// divider's x wrong. It does not, and cannot, drop the window-wide material: a `.behindWindow` material
/// only paints where a view exists to paint it, and the 1 pt column each divider occupies belongs to no
/// pane, so per-pane containers leave that column showing the desktop straight through the window. The
/// material therefore stays one view behind the whole split view -- pinned as a sibling beneath it, not
/// as the content view itself -- and `testOneWindowWideMaterialBacksTheWholeSplitView` is the contract.
///
/// What this file asserts: the split view controller *is* the window's content view controller, the root
/// wrapper is gone, the material is single and full-bleed, and the pane top spacing still reads the
/// 52 pt safe area exactly once. The divider's own paint is asserted elsewhere (`DividerChromeClipTests`).
///
/// Safe area, measured before and after (see the report): both panes' top inset stays 52 pt, equal to
/// the toolbar band (`window.frame.height − contentLayoutRect.height`), and the trigger field's offset
/// from the pane's top stays inset + `EditorViewController.firstControlTopGap` (20 pt) = 72 pt. The
/// assertions below pin all three numbers so a future change that doubles or collapses the inset, or
/// re-pins the form off the safe area, fails here.
///
/// Mutation-proven (each run red before reverting):
/// * restoring the root-wrapper hierarchy fails `testTheSplitViewControllerIsTheWindowContentViewController`;
/// * giving each pane its own `Glass.windowBackground()` and deleting the window-wide one fails
///   `testOneWindowWideMaterialBacksTheWholeSplitView` twice -- the count, and the pane-is-effect-view check;
/// * pinning the trigger field to the container's top edge instead of the safe area fails
///   `testThePaneTopSpacingSurvivesTheHierarchyChange` (gap loses the 52 pt inset).
final class WindowHierarchyTests: XCTestCase {
    /// The structural fact that makes AppKit own the titlebar chrome: the window's content view
    /// controller **is** the split view controller, and no root wrapper view controller (and no
    /// window-wide `NSVisualEffectView` content view) stands between them any more.
    @MainActor
    func testTheSplitViewControllerIsTheWindowContentViewController() throws {
        let controller = try makeController()
        defer { controller.window?.orderOut(nil) }
        let window = try XCTUnwrap(controller.window)

        XCTAssertTrue(window.contentViewController === controller.splitViewControllerForProbe,
                      "the window's contentViewController is \(String(describing: type(of: window.contentViewController))),"
                          + " not the split view controller — the root-wrapper hierarchy is back, which is"
                          + " exactly what let the pane divider run up through the unified toolbar")
        XCTAssertFalse(window.contentView is NSVisualEffectView,
                       "the content view is a window-wide effect view again: the root material moved to the"
                           + " panes' content layer and the wrapper must stay deleted")
        // `isOpaque = false` + clear background is what gives a behind-window material anything to
        // sample; the hierarchy change must not have dropped it.
        XCTAssertFalse(window.isOpaque, "a non-opaque window is the contract of .behindWindow material")
        XCTAssertEqual(window.backgroundColor, .clear)
    }

    /// One window-wide `.underWindowBackground` material, backmost in the window's content view and
    /// filling it -- and **no** per-pane backing. This is the divider-hole contract: a `.behindWindow`
    /// material only paints where a view exists, and the 1 pt column each divider occupies belongs to no
    /// pane, so per-pane containers leave it showing the desktop through a non-opaque window. Measured on
    /// the live window 2026-10-30 (alpha 0.000 in the band, 0.122 below, 1.000 one point either side),
    /// and the reason the material moved back out of the panes.
    @MainActor
    func testOneWindowWideMaterialBacksTheWholeSplitView() throws {
        let controller = try makeController()
        defer { controller.window?.orderOut(nil) }
        let window = try XCTUnwrap(controller.window)
        let host = try XCTUnwrap(window.contentView)

        let backings = host.subviews.compactMap { $0 as? NSVisualEffectView }
        XCTAssertEqual(backings.count, 1,
                       "the window's content view has \(backings.count) effect views; exactly one "
                           + "window-wide backing is the contract, because a per-pane pair leaves the "
                           + "divider column unbacked")
        let backing = try XCTUnwrap(backings.first)
        XCTAssertEqual(backing.material, .underWindowBackground)
        XCTAssertEqual(backing.blendingMode, .behindWindow)
        XCTAssertEqual(backing.state, .followsWindowActiveState)
        XCTAssertEqual(backing.frame, host.bounds,
                       "the backing does not cover the content view, so some column of the window has "
                           + "nothing behind it")
        XCTAssertEqual(host.subviews.first?.frame, host.bounds)

        for (name, pane) in [("editor", controller.editorPaneForProbe.view),
                             ("diagnostics", controller.diagnosticsPaneForProbe.view)] {
            XCTAssertFalse(pane is NSVisualEffectView,
                           "the \(name) pane is an effect view again — two stacked .behindWindow "
                               + "materials double-blur the pane region while the divider between them "
                               + "stays unbacked")
        }
        // A non-opaque window with a clear background is what the material samples through; if it ever
        // becomes opaque the whole question changes shape.
        XCTAssertFalse(window.isOpaque)
        XCTAssertEqual(window.backgroundColor, .clear)
    }

    /// Top spacing of the detail pane, measured rather than assumed: the safe area still reports the
    /// toolbar band exactly once (52 pt on the probed window, `frame.height − contentLayoutRect.height`
    /// -- before the fix the inset was 52, after it is also 52, so the form neither doubled down nor
    /// collapsed under the toolbar), and the pane's first control sits `firstControlTopGap` below that
    /// safe-area top, 72 pt below the pane's physical top on the probed window.
    @MainActor
    func testThePaneTopSpacingSurvivesTheHierarchyChange() throws {
        let controller = try makeController()
        defer { controller.window?.orderOut(nil) }
        let window = try XCTUnwrap(controller.window)
        let editor = controller.editorPaneForProbe
        editor.view.layoutSubtreeIfNeeded()

        let toolbarBand = window.frame.height - window.contentLayoutRect.height
        XCTAssertGreaterThan(toolbarBand, 0, "the probe is meaningless without a toolbar band")
        XCTAssertEqual(editor.view.safeAreaInsets.top, toolbarBand,
                       "the editor pane's top safe-area inset is \(editor.view.safeAreaInsets.top) pt but the "
                           + "titlebar+toolbar band is \(toolbarBand) pt — the hierarchy change either doubled "
                           + "or collapsed the inset the pane's constraints were written against")

        // The first control's offset from the pane's top edge: safe-area inset + the named gap. A pin
        // to the raw container edge would read 20 where 72 is measured, and a doubled inset reads 124.
        let field = editor.triggerFieldForProbe
        let gapFromPaneTop = editor.view.bounds.maxY - field.frame.maxY
        XCTAssertEqual(gapFromPaneTop, editor.view.safeAreaInsets.top + EditorViewController.firstControlTopGap,
                       accuracy: 0.5,
                       "the trigger field sits \(gapFromPaneTop) pt below the pane's top edge, not "
                           + "inset + \(EditorViewController.firstControlTopGap) — the form left the safe area")
    }

    /// The divider contract restated on the new hierarchy, because both numbers ride the view-realisation
    /// order the hierarchy change rewrote: the sidebar opens at its designed 218 pt (`setPosition` after
    /// the autosaved frame), and the Diagnostics reveal still lands the pane on 230 pt.
    /// `DiagnosticsDividerTests` pins the same two numbers; this test exists so the hierarchy file fails
    /// on its own if the re-order silently breaks one of them.
    @MainActor
    func testSidebarAndDiagnosticsDividerGeometrySurviveTheHierarchyChange() throws {
        let controller = try makeController()
        defer { controller.window?.orderOut(nil) }
        let split = try XCTUnwrap(controller.splitViewForProbe)
        split.layoutSubtreeIfNeeded()

        let sidebarWrapper = split.subviews.first {
            String(describing: Swift.type(of: $0)).contains("SplitViewItemViewWrapper")
                && $0.frame.minX == 0 && $0.frame.height > 100 && $0.frame.width > 100
        }
        XCTAssertEqual(sidebarWrapper?.frame.width ?? 0, 218, accuracy: 1.0,
                       "the sidebar opened at \(sidebarWrapper?.frame.width ?? 0) pt under the new "
                           + "contentViewController hierarchy — the fitting-size/autosave/setPosition order "
                           + "in `restoreFrame` no longer holds")

        controller.setDiagnosticsCollapsedForProbe(false)
        XCTAssertEqual(controller.diagnosticsPaneWidth, MainWindowController.diagnosticsExpandedWidth,
                       accuracy: 1.0,
                       "the Diagnostics pane lands at \(controller.diagnosticsPaneWidth) pt, not the designed "
                           + "\(MainWindowController.diagnosticsExpandedWidth), after the hierarchy change")
    }

    // MARK: - fixture

    /// The same fixture discipline as `DiagnosticsDividerTests`: a real controller over a scratch store,
    /// window ordered front off the corner of any plausible display, drain so the toolbar chrome and the
    /// safe-area propagation exist.
    @MainActor
    private func makeController() throws -> MainWindowController {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("unfold-window-hierarchy-\(UUID().uuidString)", isDirectory: true)
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
