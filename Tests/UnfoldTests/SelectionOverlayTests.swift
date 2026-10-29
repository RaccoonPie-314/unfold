import AppKit
import UnfoldEngine
import UnfoldMac
import XCTest
@testable import Unfold

/// Ruling AG, measured in-process: the selection morph's 1 pt line is hosted by the **window's own
/// content view** -- the common unclipped ancestor of the sidebar and the editor -- owned by
/// `MainWindowController`, and runs from `sidebar.selectedRowFrame` to `editor.triggerFieldFrameInWindow`
/// (both screen-space, both converted into the overlay's host space at morph time).
///
/// Four measurements, each driving the real wiring (`tableViewSelectionDidChange` → `sidebar.onSelect`
/// → `selectionMorph`) on a real controller window ordered front off the corner of any display -- the
/// technique `MotionDriverTests` and `SidebarRowMotionTests` already use. The live pass remains what
/// the user sees; this is what the geometry, the clip chain and the completion pairing actually are.
///
/// 1. **The start pose lands on the row.** The pose is read from the installed animation's `fromValue`
///    rather than a presentation sample, and that is a measured difference: `selectionMorph` is a
///    200 ms `.easeOut(0.33, 1, 0.68, 1)` whose curve leaves the start steeply -- ~5 ms in (the fastest
///    sample this process can take) it is already ~7% of the way down the ramp, and 7% of a
///    source-to-destination span of half a window is tens of points away from the row. The `fromValue`
///    transform *is* what is painted at t = 0; applying it to the resting frame about the layer's real
///    anchor checks Ruling AE's compensation end-to-end on the new host. (`MotionDriverTests` samples
///    presentations because its springs start at rest; that suite keeps doing that.)
/// 2. **Nothing clips the pose.** The host chain's `masksToBounds` is walked and reported, not assumed;
///    the window's content view must answer false, and any ancestor that answers true must contain the
///    pose in its own bounds. The pane-hosted proxy had neither property: its wrapper chain is
///    `_NSSplitViewItemViewWrapper masks=true` (Task 11b note §5.2) and the pose sits over the
///    *sidebar*, outside the editor pane's bounds.
/// 3. **The line is hidden at rest, unhidden while the morph runs, hidden again by the completion** --
///    and, where this process enters a render cycle, the presentation tree shows the 1 pt line at a
///    row-sized pose mid-flight.
/// 4. **Interruption**: a second selection while the first morph is in flight leaves the *newer*
///    animation holding `unfold.morph` for its whole ramp (the interrupted morph's stale completion is
///    refused by `Motion`'s identity guard), and the line hides exactly once, after the newer morph
///    ends.
final class SelectionOverlayTests: XCTestCase {
    /// The key the driver installs under, as a literal: retargeting it in the driver must fail here
    /// rather than be quietly followed, same discipline as `MotionDriverTests`.
    private let morphKey = "unfold.morph"

    // MARK: - measurements 1 + 2: the pose and the clip chain

    @MainActor
    func testTheStartPoseLandsOnTheSidebarRowAndNothingAlongTheHostChainClipsIt() throws {
        let controller = try makeController()
        defer { controller.window?.orderOut(nil) }
        let window = try XCTUnwrap(controller.window)
        let overlay = controller.selectionOverlay

        // Ruling AG's host: the window's own content view, installed above the split view.
        let host = try XCTUnwrap(overlay.superview,
                                 "the overlay must be installed when the window is assembled")
        XCTAssertTrue(host === window.contentView,
                      "the selection line must be hosted by the window's content view — the common "
                          + "unclipped ancestor of both panes — not by a pane (found \(Swift.type(of: host)))")

        // Drive the real wiring: picking another row reports through `onSelect` and morphs the line.
        controller.sidebar.listTableView.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        let layer = try awaitMorphKey(on: overlay)
        let basic = try XCTUnwrap(layer.animation(forKey: morphKey) as? CABasicAnimation,
                                  "selectionMorph is the plan's ease-out curve — a CABasicAnimation — "
                                      + "so a different object under the key means a different transition ran")
        let start = CATransform3DGetAffineTransform(
            try XCTUnwrap((basic.fromValue as? NSValue)?.caTransform3DValue,
                          "the installed morph carries no from pose"))

        // The morphing rects live in the host's space; two equivalences make the reading comparable,
        // both measured rather than assumed: the layer is joined to the host's layer, the host's layer
        // is not geometry-flipped, and the resting layer frame is the view's frame (Ruling D).
        let hostLayer = try XCTUnwrap(host.layer,
                                      "the window content view has no layer, so there is nothing to "
                                          + "compare the pose against — the overlay cannot be rendering")
        XCTAssertTrue(layer.superlayer === hostLayer,
                      "the overlay's layer is not parented to the content view's layer: this is not "
                          + "measuring the claimed host")
        XCTAssertEqual(hostLayer.isGeometryFlipped, false,
                       "the content view's layer mirrors a flippedness the view does not have; the "
                           + "rect conversions below need reworking")
        XCTAssertEqual(layer.frame, overlay.frame,
                       "the resting layer frame is not the view's frame, so the rects the morph was "
                           + "handed are not in the layer's space")

        let anchor = layer.anchorPoint
        let pose = installedStartPose(of: layer, transformedBy: start)
        let poseInWindow = host.convert(pose, from: nil)
        let expected = window.convertFromScreen(
            try XCTUnwrap(controller.sidebar.selectedRowFrame,
                          "the selected row answers no frame, so the morph had no source either"))

        let report = "anchor=\(anchor) restingLayerFrame=\(layer.frame) "
            + "poseHost=\(String(format: "(%.2f, %.2f, %.2f x %.2f)", pose.minX, pose.minY, pose.width, pose.height)) "
            + "poseWindow=\(String(format: "(%.2f, %.2f, %.2f x %.2f)", poseInWindow.minX, poseInWindow.minY, poseInWindow.width, poseInWindow.height)) "
            + "sourceWindow=\(String(format: "(%.2f, %.2f, %.2f x %.2f)", expected.minX, expected.minY, expected.width, expected.height))"
        print("selection overlay start pose:\n\(report)")
        NSLog("selection overlay pose: %@", report)

        XCTAssertEqual(poseInWindow.minX, expected.minX, accuracy: 1.0,
                       "the installed start pose missed the row by more than a point in x (\(report))")
        XCTAssertEqual(poseInWindow.minY, expected.minY, accuracy: 1.0,
                       "the installed start pose missed the row by more than a point in y (\(report))")
        XCTAssertEqual(poseInWindow.width, expected.width, accuracy: 1.0, "pose width vs source (\(report))")
        XCTAssertEqual(poseInWindow.height, expected.height, accuracy: 1.0, "pose height vs source (\(report))")

        // The pose sits inside the host's own bounds -- which is the whole ruling: over the *sidebar*,
        // it was outside the editor pane's bounds and the pane's wrapper clipped it.
        XCTAssertTrue(host.bounds.insetBy(dx: -1.0, dy: -1.0).contains(pose),
                      "the start pose is not inside the hosting view's bounds, so whatever mask the "
                          + "chain carries would cut it (\(report) vs bounds \(host.bounds))")

        // What the landing is: the trigger field's line, one point tall. `Motion.morph` always lands
        // on `view.frame`, so this pins the destination half of the shared element.
        let field = window.convertFromScreen(
            try XCTUnwrap(controller.editor.triggerFieldFrameInWindow,
                          "the trigger field answers no landing rect"))
        XCTAssertEqual(overlay.frame.minX, field.minX, accuracy: 1.0, "the line starts where the field starts")
        XCTAssertEqual(overlay.frame.width, field.width, accuracy: 1.0, "the line is field-wide")
        XCTAssertEqual(overlay.frame.midY, field.midY, accuracy: 1.0, "the line sits on the field's centre")
        XCTAssertEqual(overlay.frame.height, 1, accuracy: 0.001, "the line is 1 pt tall")

        // The clip chain: walked, reported, and asserted. The window's content view must not clip
        // (that is what Ruling AG rests on); every *higher* ancestor that does clip must be wide
        // enough to contain the pose -- for the theme frame that is automatic, and it is checked.
        var findings: [String] = ["\(Swift.type(of: overlay)): masksToBounds=\(masked(overlay)) [the line itself]"]
        var node: NSView? = host
        while let view = node {
            let masks = masked(view)
            findings.append("\(Swift.type(of: view)): masksToBounds=\(masks) bounds=\(view.bounds)")
            if view.layer?.masksToBounds == true {
                let poseHere = view.convert(pose, from: host)
                XCTAssertTrue(view.bounds.insetBy(dx: -1.0, dy: -1.0).contains(poseHere),
                              "\(Swift.type(of: view)) clips and the start pose sits outside its "
                                  + "bounds — the line would be cut there (pose \(poseHere) vs \(view.bounds))")
            }
            node = view.superview
        }
        let chain = findings.joined(separator: "\n")
        print("selection overlay host chain:\n\(chain)")
        NSLog("selection overlay chain: %@", findings.joined(separator: " | "))
        XCTAssertEqual(host.layer?.masksToBounds, false,
                       "the window content view's layer clips — Ruling AG's host stops being "
                           + "unclipped and the ruling needs revisiting; do not work around this "
                           + "by moving the host again without a ruling (\(chain))")
    }

    // MARK: - measurement 3: hidden at rest, visible in flight, hidden again

    @MainActor
    func testTheLineShipsHiddenIsUnhiddenThroughTheMorphAndGoesBackAtTheEnd() throws {
        let controller = try makeController()
        defer { controller.window?.orderOut(nil) }
        let overlay = controller.selectionOverlay
        XCTAssertTrue(overlay.isHidden,
                      "Ruling R, moved with the line: a standing-by overlay must not paint a "
                          + "separator across the window at rest")

        controller.sidebar.listTableView.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        let layer = try awaitMorphKey(on: overlay)
        XCTAssertFalse(overlay.isHidden, "unhide before installing is what makes the morph visible")

        let transition = try XCTUnwrap(MotionPlan.lookup(.selectionMorph))
        var readings = 0
        var sawRowSizedPose = false
        var hiddenDuringFlight = false
        let started = Date()
        drain(from: started, until: started.addingTimeInterval(transition.duration + 0.35)) { now in
            let elapsed = now.timeIntervalSince(started)
            if elapsed < transition.duration * 0.75, overlay.isHidden {
                hiddenDuringFlight = true
            }
            guard elapsed < transition.duration, let presentation = layer.presentation() else { return }
            readings += 1
            // The moving geometry: a 1 pt line at pose scale k is the shared element mid-flight; the
            // start pose is row-sized (k_y ≈ 40), so anything past 4 pt proves the line is painting a
            // travelling bar rather than sitting at rest.
            if presentation.bounds.height * presentation.affineTransform().d > 4 {
                sawRowSizedPose = true
            }
        }

        XCTAssertFalse(hiddenDuringFlight,
                       "the line hid itself while its own morph was still in flight")
        XCTAssertTrue(overlay.isHidden,
                      "the completion did not put the line back (readings=\(readings) in "
                          + "\(String(format: "%.0f", transition.duration * 1000))ms)")
        XCTAssertNil(layer.animation(forKey: morphKey),
                     "the finished morph left its animation parked on the layer")

        // The render-cycle valve, same shape as `MotionDriverTests`: no presentation frame anywhere
        // means this process never painted, which is an environment fact, not a driver failure --
        // everything above is model state and holds either way.
        try XCTSkipUnless(readings > 0,
                          "presentation() never produced a frame for a morph attached under "
                              + "\(morphKey): this process entered no render cycle; the live pass owns it")
        XCTAssertTrue(sawRowSizedPose,
                      "the 1 pt line never read row-sized while the morph ran (\(readings) readings): "
                          + "the shared element is not travelling from the row")
    }

    // MARK: - measurement 4: interruption hides the line exactly once

    @MainActor
    func testAnInterruptingSelectionLeavesTheNewerMorphHoldingTheLineUntilItEnds() throws {
        let controller = try makeController()
        defer { controller.window?.orderOut(nil) }
        let overlay = controller.selectionOverlay
        let table = controller.sidebar.listTableView

        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        let layer = try awaitMorphKey(on: overlay)
        let first = try XCTUnwrap(layer.animation(forKey: morphKey))
        let started = Date()
        drain(from: started, until: started.addingTimeInterval(0.10))

        // Interrupt: pick the other row while the first morph is still ramping. The wait breaks the
        // instant the newer animation holds the key -- running past it would let the *newer* morph
        // finish inside the detection loop, and the flight window below would then poll a corpse
        // (measured: that version reads "nothing under the key" at every flight poll).
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        var second: CAAnimation?
        let detecting = Date()
        while Date() < detecting.addingTimeInterval(0.15) {
            let current = layer.animation(forKey: morphKey)
            if let current, current !== first {
                second = current
                break
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        let newer = try XCTUnwrap(second,
                                  "the second selection left the first morph's animation under "
                                      + "\(morphKey) — the interrupt did not retarget the line")
        XCTAssertFalse(newer === first, "identity check: the holder after the interrupt is not the first morph")
        XCTAssertTrue(newer is CABasicAnimation,
                      "after the interrupt the animation under the key is \(Swift.type(of: newer)), "
                          + "not the second ease-out morph")

        var alienHolders: [String] = []
        var hideTransitions: [TimeInterval] = []
        var wasHidden = overlay.isHidden
        let t0 = Date()
        let duration = try XCTUnwrap(MotionPlan.lookup(.selectionMorph)).duration
        drain(from: t0, until: t0.addingTimeInterval(duration + 0.6)) { now in
            let elapsed = now.timeIntervalSince(t0)
            if overlay.isHidden != wasHidden {
                if overlay.isHidden { hideTransitions.append(elapsed) }
                wasHidden = overlay.isHidden
            }
            // Inside the newer morph's own window, whatever holds the key must *be* the newer morph.
            // (Core Animation retires a finished animation a hair before the completion block runs,
            // so the last 20 ms belong to CA, same cut as `MotionDriverTests`.)
            guard elapsed < duration - 0.02 else { return }
            let current = layer.animation(forKey: morphKey)
            if current !== newer {
                alienHolders.append("t=\(String(format: "%.3f", elapsed))s: "
                                    + "\(current.map { String(describing: Swift.type(of: $0)) } ?? "nothing under the key")")
            }
        }

        let report = "hideTransitions=\(hideTransitions.map { String(format: "%.3f", $0) }) "
            + "alienHolders=\(alienHolders)"
        print("selection overlay interrupt: \(report)")
        NSLog("selection overlay interrupt: %@", report)
        XCTAssertTrue(alienHolders.isEmpty,
                      "something other than the interrupting morph held \(morphKey) during its ramp — "
                          + "the interrupted morph's stale completion stole the line (\(report))")
        XCTAssertEqual(hideTransitions.count, 1,
                       "the line did not hide exactly once across the pair of morphs (\(report)) — the "
                           + "identity-guarded completion is what makes fast selections hide it once, "
                           + "at the end")
        XCTAssertGreaterThan(hideTransitions.first ?? 0, duration * 0.5,
                             "the single hide happened mid-ramp of the morph that survived "
                                 + "(\(report)) — that is the stale completion hiding an in-flight line")
        XCTAssertTrue(overlay.isHidden, "and it ends hidden")
    }

    // MARK: - the overlay never eats a click

    @MainActor
    func testTheOverlayHitTestsThroughEvenWhileItIsVisible() throws {
        let controller = try makeController()
        defer { controller.window?.orderOut(nil) }
        let overlay = controller.selectionOverlay

        // Unhidden, mid-morph -- the only time it paints, and the only time a pass-through overlay
        // could mislead a hit test.
        controller.sidebar.listTableView.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        _ = try awaitMorphKey(on: overlay)
        XCTAssertFalse(overlay.isHidden)
        let pointInOverlay = NSPoint(x: overlay.bounds.midX, y: overlay.bounds.midY)
        XCTAssertNil(overlay.hitTest(pointInOverlay),
                     "the overlay answered a hit test: a window-level view that can be clicked would "
                         + "steal clicks from both panes for the length of every morph")
        if let host = overlay.superview {
            let pointInHost = overlay.convert(pointInOverlay, to: host)
            if let hit = host.hitTest(pointInHost) {
                XCTAssertFalse(hit === overlay, "the host's hit test resolved to the overlay")
            }
        }
    }

    // MARK: - fixtures

    /// A real `MainWindowController` over a scratch store in a temporary directory: two combos so the
    /// list has a row to move the selection to, the window ordered front off the corner of any display
    /// (on-screen-ness, not position, is what gates the render cycle and the `window.isVisible` the
    /// morph itself checks), and a few run-loop turns for AppKit to join the layers and lay the panes
    /// out. Nothing is deleted, saved or typed at the keyboard layer: the coordinator is built
    /// untrusted, so no tap is ever attached.
    @MainActor
    private func makeController() throws -> MainWindowController {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("unfold-selection-overlay-\(UUID().uuidString)", isDirectory: true)
        let store = Store(url: directory.appendingPathComponent("combos.json"))
        let combos = [
            Combo(id: UUID(), trigger: "sig", label: "", enabled: true,
                  parts: [.text("Sent from my iPhone")], insertion: .paste),
            Combo(id: UUID(), trigger: "addr", label: "", enabled: true,
                  parts: [.text("1 Main Street")], insertion: .paste),
        ]
        try store.save(CombosFile(formatVersion: CombosFile.currentFormatVersion, combos: combos))

        let coordinator = ExpansionCoordinator(combos: combos)
        let controller = MainWindowController(coordinator: coordinator, store: store)
        let window = try XCTUnwrap(controller.window)
        window.setFrameOrigin(NSPoint(x: -3_200, y: -1_800))
        window.orderFrontRegardless()
        let started = Date()
        drain(from: started, until: started.addingTimeInterval(0.12))
        return controller
    }

    /// The table posts its selection change on a run-loop turn, so the morph lands a moment after
    /// `selectRowIndexes`; this waits for the key and **fails** -- never skips -- if the wiring never
    /// installs anything, so "selection did not drive the overlay" cannot hide behind a
    /// render-cycle excuse.
    @MainActor
    private func awaitMorphKey(on overlay: NSView) throws -> CALayer {
        let started = Date()
        while Date() < started.addingTimeInterval(0.5) {
            if let layer = overlay.layer, layer.animationKeys()?.contains(morphKey) == true {
                return layer
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
        XCTFail("no \(morphKey) animation was installed on the overlay within 0.5 s of the selection "
                + "change — the selection wiring, not the render cycle, is what failed (layer="
                + "\(String(describing: overlay.layer)), wantsLayer=\(overlay.wantsLayer), "
                + "host=\(String(describing: overlay.superview)))")
        return overlay.layer ?? CALayer()
    }

    /// The rect the driver tells the layer to paint at t = 0: the resting frame in the superlayer's
    /// space, carried through the transform about the layer's actual `anchorPoint` -- the same corner
    /// mapping `MotionDriverTests.readStartPose` applies to a live presentation, pinned to the
    /// installed from pose instead of a sampled one.
    private func installedStartPose(of layer: CALayer, transformedBy t: CGAffineTransform) -> CGRect {
        let rest = layer.frame
        let anchor = layer.anchorPoint
        let anchorAbs = CGPoint(x: rest.minX + rest.width * anchor.x,
                                y: rest.minY + rest.height * anchor.y)
        let corners = [CGPoint(x: rest.minX, y: rest.minY), CGPoint(x: rest.maxX, y: rest.minY),
                       CGPoint(x: rest.minX, y: rest.maxY), CGPoint(x: rest.maxX, y: rest.maxY)]
        let drawn = corners.map {
            CGPoint(x: anchorAbs.x + t.a * ($0.x - anchorAbs.x) + t.tx,
                    y: anchorAbs.y + t.d * ($0.y - anchorAbs.y) + t.ty)
        }
        let xs = drawn.map(\.x), ys = drawn.map(\.y)
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    /// `masksToBounds` as a reportable string, distinguishing "no layer" from "not clipping".
    private func masked(_ view: NSView) -> String {
        view.layer.map { String($0.masksToBounds) } ?? "nil layer"
    }

    /// Advances the main run loop to `deadline`, calling `check` on every pass (~5 ms) -- copied from
    /// `MotionDriverTests`, where the reason is measured: XCTest's own wait loop does not let Core
    /// Animation retire a transaction, so a completion the driver installed would never run here.
    @MainActor
    private func drain(from start: Date, until deadline: Date, check: (Date) -> Void = { _ in }) {
        while Date() < deadline {
            let slice = min(deadline, Date().addingTimeInterval(0.005))
            RunLoop.main.run(until: slice)
            check(Date())
        }
    }
}
