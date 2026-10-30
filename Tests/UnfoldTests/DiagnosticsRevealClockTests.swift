import AppKit
import QuartzCore
import UnfoldEngine
import UnfoldMac
import XCTest
@testable import Unfold

/// The Diagnostics reveal must run on **one** clock.
///
/// The user's report of 2026-10-30: *"the diagnostic panel flickering when expanding outward but
/// inward doesn't"*, pointed at the band between the editor's right edge and the panel's left edge.
///
/// Measured on the live window with a 2 ms sampler (`/tmp/unfold-divider-probe.log`, 456 samples per
/// 0.9 s phase): during the animated uncollapse the split item's **model** frame travels the eased
/// path (x 900 → 884 → 829 → 752 → 692 → 673 → 670 over ~280 ms) while its **presentation** frame
/// lags behind it by up to **21.4 pt** on a later expansion and **226.4 pt** on the first one -- the
/// first expansion starts with the collapsed wrapper parked at the open rect (`670...900`, `isHidden`),
/// so un-hiding it paints the panel fully open before the travel begins. The painted edge is therefore
/// never where the layout says the edge is, and the strip between the editor's laid-out trailing edge
/// and the panel's painted leading edge grows and shrinks mid-flight: the flicker.
///
/// The asymmetry is the same lag read from the other side. Expanding, the lag leaves a **hole**
/// (painted edge right of the laid-out edge) and a hole in a non-opaque window shows the material
/// behind the panes. Collapsing, the lag makes the panel paint **over** the editor's empty trailing
/// padding, which has nothing in it to look wrong.
///
/// Cause: `NSAnimationContext.allowsImplicitAnimation` is what drives the divider at all (measured --
/// with it off the pane snaps open with no travel at all, so it is not the thing to remove), and every
/// frame change that travel makes *also* gets a Core Animation implicit action on the item's layer.
/// Two interpolators, one of them always behind: the glide plus the lag on top of the glide.
///
/// The fix keeps the AppKit clock and refuses the second one by opening a `CATransaction` with
/// `setDisableActions(true)` around the group. Measured with that in place: `presX == modelX` at
/// **every** sample of **every** phase (0.0 pt worst lag against 21.4 / 226.4), the model still
/// travels the eased path, and the collapse still ends parked at `900...1130` hidden.
///
/// What this harness can see is the animation *installed*, not the animation *in flight* (the display
/// link is not pumped by `swift test` -- see `DiagnosticsDividerTests`), so the assertion below is
/// checked against the unfixed code first.
final class DiagnosticsRevealClockTests: XCTestCase {
    /// Un-hiding the Diagnostics item inside the animated group must not leave a Core Animation
    /// action on the item's own layer: the divider's travel is the motion, and a second interpolator
    /// on the pane's frame is what paints it somewhere other than where it is laid out.
    @MainActor
    func testTheAnimatedRevealInstallsNoLayerActionOnThePane() throws {
        let (controller, split) = try fixture()
        defer { controller.window?.orderOut(nil) }
        let wrapper = try XCTUnwrap(controller.diagnosticsPaneForProbe.view.superview)

        controller.setDiagnosticsCollapsed(false, animated: true)
        split.layoutSubtreeIfNeeded()

        var holders: [String] = []
        for view in [wrapper, controller.diagnosticsPaneForProbe.view, split] {
            guard let keys = view.layer?.animationKeys(), !keys.isEmpty else { continue }
            holders += keys.map { "\(String(describing: Swift.type(of: view))).\($0)" }
        }
        XCTAssertTrue(holders.isEmpty,
                      "the animated reveal left Core Animation actions installed: \(holders) — the "
                          + "divider's AppKit glide and a layer action on the same frame put the "
                          + "panel's painted edge behind its laid-out edge, which is the flicker")
    }

    /// The counter-assertion that keeps the first one honest: a reveal that never animates installs
    /// nothing either, so an empty `holders` list must not be read as "the motion was removed". This
    /// drives the same code with `animated: false`, where no `NSAnimationContext` is opened at all.
    @MainActor
    func testTheSynchronousRevealStillLandsThePaneOpen() throws {
        let (controller, _) = try fixture()
        defer { controller.window?.orderOut(nil) }

        controller.setDiagnosticsCollapsed(false, animated: false)
        XCTAssertEqual(controller.diagnosticsPaneWidth,
                       MainWindowController.diagnosticsExpandedWidth, accuracy: 1.0,
                       "the synchronous reveal does not land the pane at its designed width, so this "
                           + "fixture is not measuring the same move the animated path makes")
    }

    // MARK: - fixture

    @MainActor
    private func fixture() throws -> (MainWindowController, NSSplitView) {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("unfold-reveal-clock-\(UUID().uuidString)", isDirectory: true)
        let store = Store(url: directory.appendingPathComponent("combos.json"))
        try store.save(CombosFile(formatVersion: CombosFile.currentFormatVersion, combos: []))

        let controller = MainWindowController(coordinator: ExpansionCoordinator(combos: []), store: store)
        let window = try XCTUnwrap(controller.window)
        window.setFrameOrigin(NSPoint(x: -3_200, y: -1_800))
        window.orderFrontRegardless()
        drain(0.15)
        let split = try XCTUnwrap(controller.splitViewForProbe)
        split.layoutSubtreeIfNeeded()
        return (controller, split)
    }

    @MainActor
    private func drain(_ seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.main.run(until: min(deadline, Date().addingTimeInterval(0.005)))
        }
    }
}
