import AppKit
import UnfoldEngine
import UnfoldMac
import XCTest
@testable import Unfold

/// Wiring coverage for the diagnostics pane.
///
/// Task 5 moved the diagnostics buttons out of `MainWindowController` and onto nil targets, so the only
/// automated proof that a press can still reach an implementation is this: every button carries no
/// target, and the selector it does carry is one `MainWindowController`'s instances answer. The pane is
/// asked to be the responder chain's *passenger* here -- the buttons skip it entirely -- and `Ruling L`
/// forbids launching the app during execution, so nobody has pressed one yet. If a future edit retargets
/// a button at the pane, renames an action so the selector no longer resolves, or replaces
/// `containerForMotionProbe` with a throwaway view, this fails.
final class DiagnosticsPaneTests: XCTestCase {
    func testButtonsAreWiredToTheWindowControllerThroughTheResponderChain() {
        _ = NSApplication.shared

        let pane = DiagnosticsViewController()
        pane.loadViewIfNeeded()

        let cluster = pane.containerForMotionProbe
        XCTAssertTrue(cluster is NSStackView,
                      "the probe host is the diagnostics button stack itself, the one Task 10 measures; "
                          + "a different view type means the probe is looking at something else")
        let buttons = (cluster as? NSStackView)?.arrangedSubviews.compactMap { $0 as? NSButton } ?? []
        XCTAssertTrue(cluster.isDescendant(of: pane.view),
                      "Task 10 measures this view's geometry; a view outside the pane's hierarchy has none")

        // The full expected button list, by selector, in order. This replaces a bare count assertion:
        // adding a button should be a deliberate edit here (the row plus its action), not a number that
        // silently drifts. The order is the on-screen order, so a reorder that moves a destructive
        // action next to a routine one also fails.
        let expected: [Selector?] = [
            #selector(MainWindowController.runConsistencyTest),
            #selector(MainWindowController.runStressTest),
            #selector(MainWindowController.runSelfTest),
            #selector(MainWindowController.testIdleTimeout),
            #selector(MainWindowController.testControlC),
            #selector(MainWindowController.runMotionProbe),
            #selector(MainWindowController.restartTap),
            #selector(MainWindowController.relaunch),
            #selector(MainWindowController.revealApp),
        ]
        XCTAssertEqual(buttons.map(\.action), expected,
                       "the diagnostics cluster is not the expected button list, in order — a button "
                           + "was added, dropped, retargeted, or reordered without updating its reviewer")

        for button in buttons {
            XCTAssertNil(button.target,
                         "\(button.title) must be sent with a nil target so it travels the responder "
                             + "chain to the window controller")
            guard let action = button.action else {
                XCTFail("\(button.title) has no action selector")
                continue
            }
            XCTAssertTrue(MainWindowController.instancesRespond(to: action),
                          "nil-target action \(NSStringFromSelector(action)) has no implementor in "
                              + "MainWindowController — the button would do nothing")
        }
    }

    /// The content's minimum width must fit the pane it opens into, and the stack must carry that width as
    /// its own constraint rather than inheriting it from the container.
    ///
    /// The button floor was 190 pt, which with the glass's 8 pt padding and the stack's 16 pt insets made
    /// the content's minimum **238 pt inside a 230 pt pane**. A set that cannot be satisfied at the width
    /// the pane opens to is resolved by AppKit breaking a pin -- and which pin it breaks changes as the
    /// container narrows, so the content's pose moved during the reveal. The floor is derived from the
    /// pane width now, so the arithmetic is one expression instead of three numbers that can drift apart;
    /// restoring the literal 190 fails this with `238 > 230`.
    func testThePaneContentFitsThePane() throws {
        _ = NSApplication.shared
        let pane = DiagnosticsViewController()
        pane.loadViewIfNeeded()
        let container = pane.view
        let stack = try XCTUnwrap(container.subviews.compactMap { $0 as? NSStackView }.first,
                                  "the pane container has no stack view to measure")
        let cluster = pane.containerForMotionProbe
        cluster.layoutSubtreeIfNeeded()

        let contentMinimum = cluster.fittingSize.width
            + 2 * DiagnosticsViewController.glassPadding
            + 2 * DiagnosticsViewController.stackInset
        XCTAssertLessThanOrEqual(contentMinimum, MainWindowController.diagnosticsExpandedWidth,
                                 "the cluster needs \(contentMinimum) pt (\(cluster.fittingSize.width) + "
                                     + "glass padding + stack insets) but the pane opens to only "
                                     + "\(MainWindowController.diagnosticsExpandedWidth) pt — an "
                                     + "unsatisfiable set at rest is resolved by breaking a pin, and the "
                                     + "broken pin moves during the reveal")

        XCTAssertTrue(stack.constraints.contains {
            $0.firstItem === stack && $0.firstAttribute == .width
                && $0.secondAttribute == .notAnAttribute
        }, "the stack has no fixed width, so the reveal can re-lay-it-out instead of holding one pose")
    }

    /// The curtain's two structural halves, measured where they can actually be seen: with the pane in a
    /// window, so AppKit's split-item wrapper exists.
    ///
    /// *The wrapper, not the pane's own container, is the clipping ancestor.* Mid-travel the wrapper is
    /// the visible pane (`884...900` on a 900 pt split) while the container is `884...1114` -- AppKit hands the
    /// item's view its full thickness and parks it at the divider. So a stack pinned to the container's
    /// trailing edge rides the divider and hangs its titles off the window's right edge until the last
    /// frames of the travel (the shimmer the user reported on 2026-10-30: *only while the pane is moving,
    /// only the Diagnostics panel*), and a mask on that container would cut off the very content the pin
    /// is positioning. The pin and the clip both belong on the wrapper, whose trailing edge sits on the
    /// window's edge at every sample.
    @MainActor
    func testTheWrapperHoldsTheContentStillAndCutsItOff() throws {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("unfold-pane-curtain-\(UUID().uuidString)", isDirectory: true)
        let store = Store(url: directory.appendingPathComponent("combos.json"))
        try store.save(CombosFile(formatVersion: CombosFile.currentFormatVersion, combos: []))
        let controller = MainWindowController(coordinator: ExpansionCoordinator(combos: []), store: store)
        let window = try XCTUnwrap(controller.window)
        window.setFrameOrigin(NSPoint(x: -3_200, y: -1_800))
        window.orderFrontRegardless()
        let deadline = Date().addingTimeInterval(0.2)
        while Date() < deadline { RunLoop.main.run(until: deadline) }
        defer { window.orderOut(nil) }

        let container = controller.diagnosticsPaneForProbe.view
        let holder = try XCTUnwrap(container.superview,
                                   "the pane's view has no split-item wrapper to pin to or clip with")
        let stack = try XCTUnwrap(container.subviews.first as? NSStackView,
                                  "the pane container has no stack view to measure")

        XCTAssertTrue(holder.wantsLayer && holder.clipsToBounds,
                      "the split-item wrapper does not clip, so the panel paints over the editor while "
                          + "the divider travels past it")
        XCTAssertEqual(holder.layer?.masksToBounds, true,
                       "the wrapper is not layer-masked, so `clipsToBounds` cannot cut off a "
                           + "layer-backed glass subview")

        let split = try XCTUnwrap(controller.splitViewForProbe)
        XCTAssertTrue(split.constraints.contains {
            ($0.firstItem === stack || $0.secondItem === stack)
                && ($0.firstAttribute == .trailing || $0.secondAttribute == .trailing)
        }, "the stack is not pinned to the split view's trailing edge — pinned to the pane container's "
            + "instead, it rides the divider off the window's right edge and snaps back at the end of the "
            + "travel")
        XCTAssertFalse(container.constraints.contains {
            ($0.firstItem === stack || $0.secondItem === stack)
                && ($0.firstAttribute == .trailing || $0.secondAttribute == .trailing)
        }, "the stack carries a trailing pin to the container again")

        controller.setDiagnosticsCollapsed(false, animated: false)
        let open = stack.convert(stack.bounds, to: nil)
        XCTAssertEqual(open.width, MainWindowController.diagnosticsExpandedWidth, accuracy: 1.0,
                       "the content is \(open.width) pt wide, not the pane's designed "
                           + "\(MainWindowController.diagnosticsExpandedWidth) pt")
        XCTAssertEqual(open.maxX, window.contentView?.bounds.maxX ?? -1, accuracy: 2.0,
                       "the content's right edge sits at \(open.maxX) against a content width of "
                           + "\(window.contentView?.bounds.maxX ?? -1) — this is the pose the wrapper "
                           + "pin exists to hold still while the divider moves")
    }
}
