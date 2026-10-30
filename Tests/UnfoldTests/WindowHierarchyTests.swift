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
/// and Music-class apps do). That removes the window-wide root material the glass pill refracts, so
/// the material moves into the content layer: the editor and diagnostics pane containers are now
/// `.underWindowBackground` / `.behindWindow` `NSVisualEffectView`s (measured necessary -- with the root
/// gone and plain containers, a subtree scan found no behind-window effect view over either pane).
///
/// What this file asserts, and which half of "the divider no longer crosses the titlebar" is provable
/// in-process: the divider paint itself is not observable without a display pass, and with
/// `.fullSizeContentView` the split view **still** spans the titlebar band (measured: frame still
/// (0, 0, 1470, 480) -- that underlap is what lets the sidebar material reach the window top, the same
/// geometry Notes has). So the assertion is the **structural fact that produces the clipping** -- the
/// split view controller *is* the window's content view controller, and the root wrapper is gone -- not
/// a frame claim about the divider region. Whether the pixels actually clip is a live-pass item.
///
/// Safe area, measured before and after (see the report): both panes' top inset stays 52 pt, equal to
/// the toolbar band (`window.frame.height − contentLayoutRect.height`), and the trigger field's offset
/// from the pane's top stays inset + `EditorViewController.firstControlTopGap` (20 pt) = 72 pt. The
/// assertions below pin all three numbers so a future change that doubles or collapses the inset, or
/// re-pins the form off the safe area, fails here.
///
/// Mutation-proven (each run red before reverting):
/// * restoring the root-wrapper hierarchy fails `testTheSplitViewControllerIsTheWindowContentViewController`;
/// * making the editor container a plain `NSView` fails `testTheContentPanesCarryTheBehindWindowMaterial`;
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

    /// The `.underWindowBackground` material the glass pill refracts now lives in the content layer,
    /// as the backmost view (the container itself) of both content panes. Measured necessary for the
    /// diagnostics pane too: an unbacked container on this clear-backed window showed the raw desktop.
    @MainActor
    func testTheContentPanesCarryTheBehindWindowMaterial() throws {
        let controller = try makeController()
        defer { controller.window?.orderOut(nil) }

        for (name, pane) in [("editor", controller.editorPaneForProbe.view),
                             ("diagnostics", controller.diagnosticsPaneForProbe.view)] {
            let effect = try XCTUnwrap(pane as? NSVisualEffectView,
                                       "the \(name) pane's container is \(type(of: pane)), not an "
                                           + "NSVisualEffectView — the window no longer paints a root "
                                           + "material, so a plain container here leaves the glass pill "
                                           + "with nothing translucent to refract")
            XCTAssertEqual(effect.material, .underWindowBackground)
            XCTAssertEqual(effect.blendingMode, .behindWindow)
            XCTAssertEqual(effect.state, .followsWindowActiveState)
        }
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
