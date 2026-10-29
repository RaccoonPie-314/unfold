import AppKit
import QuartzCore
import UnfoldEngine
import UnfoldMac
import XCTest
@testable import Unfold

/// The Diagnostics reveal is one divider move.
///
/// The user's complaint of 2026-10-29: *"when it expand there is just a line there and the animation
/// is awkward. When the text shrink when the diagnose panel expand out it shrink instantly awkwardly
/// too."* Both halves came from the same thing -- a content transform riding beside the system's own
/// divider move. The transform is deleted (the pane's layer is never handed an `unfold.morph`, and the
/// edge-pose helper it used went with it); what remains is `setDiagnosticsCollapsed(_:animated:)`:
/// the collapse of the `NSSplitViewItem` (which AppKit drives "purely from a constraint animation",
/// `NSSplitViewItem.h:32`) wrapped with `NSSplitView.setPosition(_:ofDividerAtIndex:)` -- the only
/// divider API on this SDK (no animated variant exists) -- inside one `NSAnimationContext` carrying the
/// plan's divider duration and the approved curve, with implicit animation on. Divider, arriving pane
/// and the middle pane's re-layout are then one pass, AppKit's.
///
/// What this file can decide in-process, and how:
/// * the pane **starts closed** (the item's `isCollapsed` flag is set and its wrapper shows nothing inside
///   the split view's bounds -- 0 pt on screen, which is what `diagnosticsPaneWidth` now measures; the
///   hidden wrapper itself keeps its 230 pt thickness since `FirstExpandPoseTests`' pre-warm lays the pane
///   out before the first expansion), and a launch-closed pane **stays** 0 wide as the window grows;
/// * the **geometry target is the designed number** -- the same collapse the animated path drives,
///   resolved *synchronously*, lands the wrapper at exactly 230 pt; the landing binds to the item's
///   `minimumThickness` (which `assembleSplitView` deliberately sets equal to `diagnosticsExpandedWidth`),
///   so the assertion fails if either drifts -- measured: setting `minimumThickness` to 300 made the
///   wrapper land at 300 and the assertion go red. It does **not** independently exercise
///   `diagnosticsDividerIndex` (a synchronous uncollapse reaches the same width whichever divider the
///   `setPosition` names), so the index is proven only by the live app's travel, listed as a live pass.
/// * the **animated toggle** (production's `toggleDiagnostics`) flips the collapse flag open and closed
///   on its own; and
/// * **no content transform**: during and after the animated toggle the whole window's subtree holds no
///   `unfold.morph` -- the deleted "line" stays deleted.
///
/// What only pixels can settle (live-pass): the *smoothness of the eased travel*. Measured while
/// writing this file, the constraint glide is driven by Core Animation's display-link commit cycle,
/// which the command-line `swift test` run loop does not pump: an animated `setDiagnosticsCollapsed`
/// flips `isCollapsed` immediately but leaves the divider at its start pose until the first real
/// on-screen frame -- reproduced with the window both off-screen at (-3200, -1800) **and** on the built-in
/// display. So "watch the divider travel smoothly" is on the live-pass list; the harness asserts the
/// target it travels to, not the in-between frames.
///
/// Mutation-proven: dropping the launch collapse fails the closed-at-launch and the grow-window
/// assertions; setting the item's `minimumThickness` to 300 (so the pane no longer lands on the
/// designed 230 pt) fails the geometry assertion; making `toggleDiagnostics` a no-op (the collapse flag
/// never flips) fails the flip assertions; re-adding a `Motion.morph` on the pane's layer fails the
/// content-transform poll. Each was run and made red before reverting.
final class DiagnosticsDividerTests: XCTestCase {
    private let morphKey = "unfold.morph"

    /// The divider move, resolved without the (harness-unpumpable) easing, lands the pane on the
    /// designed 230 pt -- and that is the same target `toggleDiagnostics` aims at with `animated: true`.
    @MainActor
    func testTheCollapseTargetLandsTheDividerOnTheDesignedWidth() throws {
        let controller = try makeController()
        defer { controller.window?.orderOut(nil) }

        XCTAssertEqual(controller.diagnosticsPaneWidth, 0, accuracy: 1.0,
                       "the Diagnostics pane is \(controller.diagnosticsPaneWidth) pt wide at launch; "
                           + "the initial collapse is part of the divider contract")

        controller.setDiagnosticsCollapsedForProbe(false)
        XCTAssertEqual(controller.diagnosticsPaneWidth, MainWindowController.diagnosticsExpandedWidth,
                       accuracy: 1.0,
                       "the collapse the toggle drives toward does NOT land the pane on the "
                           + "designed \(MainWindowController.diagnosticsExpandedWidth) pt target "
                           + "(wrapper \(controller.diagnosticsPaneWidth) pt) — the item's "
                           + "minimumThickness no longer equals diagnosticsExpandedWidth")
        XCTAssertFalse(controller.diagnosticsPaneCollapsed,
                       "a divider that reached the expanded target must have lifted the collapse flag")
    }

    /// Production's animated toggle: it flips the collapse flag both ways and installs no content
    /// transform. The eased travel is not observable here (see the file header), so the assertion is
    /// the flag flip and the empty morph poll -- not "the divider visually moved".
    @MainActor
    func testTheAnimatedToggleFlipsTheCollapseAndInstallsNoContentTransform() throws {
        let controller = try makeController()
        defer { controller.window?.orderOut(nil) }

        controller.toggleDiagnostics(nil)
        var alienMorphHolders: [String] = []
        drain(0.4) { [weak controller] _ in
            guard let root = controller?.window?.contentView else { return }
            for holder in Self.morphHolders(in: root) {
                alienMorphHolders.append("\(String(describing: Swift.type(of: holder))) holds "
                                            + "\(self.morphKey): the deleted content transform is back")
            }
        }
        XCTAssertFalse(controller.diagnosticsPaneCollapsed,
                       "toggleDiagnostics on a closed pane must open it — the collapse flag did not flip")
        XCTAssertTrue(alienMorphHolders.isEmpty, alienMorphHolders.joined(separator: "\n"))

        controller.toggleDiagnostics(nil)
        drain(0.4) { [weak controller] _ in
            guard let root = controller?.window?.contentView else { return }
            for holder in Self.morphHolders(in: root) {
                alienMorphHolders.append("\(String(describing: Swift.type(of: holder))) holds "
                                            + "\(self.morphKey): the deleted content transform is back")
            }
        }
        XCTAssertTrue(controller.diagnosticsPaneCollapsed,
                      "the closing toggle is the same divider on the same clock — it must return the "
                          + "collapse flag to closed")
        XCTAssertTrue(alienMorphHolders.isEmpty, alienMorphHolders.joined(separator: "\n"))
    }

    /// A launch-closed trailing pane stays closed when the window grows: `canCollapse` + the collapse
    /// set before the first layout hold it at 0 instead of letting the slack reopen it as a sliver.
    @MainActor
    func testAClosedPaneStaysClosedWhenTheWindowGrows() throws {
        let controller = try makeController()
        defer { controller.window?.orderOut(nil) }
        let window = try XCTUnwrap(controller.window)
        let start = window.contentView!.frame.width

        window.setContentSize(NSSize(width: start + 160, height: window.contentLayoutRect.height))
        drain(0.3)
        XCTAssertEqual(controller.diagnosticsPaneWidth, 0, accuracy: 1.0,
                       "widening the window re-opened the launch-closed pane as a sliver "
                           + "(\(controller.diagnosticsPaneWidth) pt) — the trailing item must stay at 0")
    }

    /// Every view in `view`'s subtree whose layer currently holds the driver's morph key. The reveal
    /// is supposed to move exactly one thing -- the divider -- so during a correct toggle this is empty
    /// for the whole window.
    private static func morphHolders(in view: NSView) -> [NSView] {
        var found: [NSView] = []
        if view.layer?.animationKeys()?.contains("unfold.morph") == true { found.append(view) }
        for sub in view.subviews { found.append(contentsOf: morphHolders(in: sub)) }
        return found
    }

    // MARK: - fixture

    /// A real `MainWindowController` over a scratch store in a temporary directory, its window
    /// ordered front off the corner of any plausible display -- the same fixture discipline as
    /// `StatusPillWidthTests`. The coordinator is built untrusted, so no tap is attached.
    @MainActor
    private func makeController() throws -> MainWindowController {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("unfold-diagnostics-divider-\(UUID().uuidString)", isDirectory: true)
        let store = Store(url: directory.appendingPathComponent("combos.json"))
        let combos = [
            Combo(id: UUID(), trigger: "sig", label: "", enabled: true,
                  parts: [.text("Sent from my iPhone")], insertion: .paste)
        ]
        try store.save(CombosFile(formatVersion: CombosFile.currentFormatVersion, combos: combos))

        let coordinator = ExpansionCoordinator(combos: combos)
        let controller = MainWindowController(coordinator: coordinator, store: store)
        let window = try XCTUnwrap(controller.window)
        window.setFrameOrigin(NSPoint(x: -3_200, y: -1_800))
        window.orderFrontRegardless()
        drain(0.15)

        // The sidebar's 218 pt position is a real divider move -- verified through the `splitViewView`
        // lookup the old `view as? NSSplitView` cast could not reach. Asserted here so a regression
        // re-introducing the nil cast (which silently no-ops `setPosition(218, ...)`) fails every test in
        // this file, not just one.
        let split = try XCTUnwrap(controller.splitViewForProbe)
        split.layoutSubtreeIfNeeded()
        let sidebar = split.subviews.first {
            String(describing: Swift.type(of: $0)).contains("SplitViewItemViewWrapper")
                && $0.frame.minX == 0 && $0.frame.height > 100 && $0.frame.width > 100
        }
        XCTAssertEqual(sidebar?.frame.width ?? 0, 218, accuracy: 1.0,
                       "the sidebar opened at \(sidebar?.frame.width ?? 0) pt, not the designed 218 — "
                           + "the splitViewView lookup that replaced the nil `view as? NSSplitView` cast "
                           + "is not reaching the real split view, or setPosition is applied before the "
                           + "autosaved frame clobbers it again")
        return controller
    }

    @MainActor
    private func drain(_ seconds: TimeInterval, check: (Date) -> Void = { _ in }) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            let slice = min(deadline, Date().addingTimeInterval(0.005))
            RunLoop.main.run(until: slice)
            check(Date())
        }
    }
}
