import AppKit
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

    /// The pane's content must be pinned so it *cannot* be wider than the pane.
    ///
    /// This is the invariant a 2026-10-30 attempt to fix the reveal's *crush* broke. That attempt pinned
    /// the stack to a fixed 230 pt with a trailing anchor and set `container.clipsToBounds = true`, which
    /// did stop the titles re-wrapping as the divider travelled -- and put the button cluster drawing on
    /// top of the editor's hint text, because the clip never engaged (the cluster is an
    /// `NSGlassEffectView`, whose layer composites outside a plain view's bounds-clip). The user saw the
    /// overlap immediately; it was reverted the same day, and this test is what keeps it reverted.
    ///
    /// Asserted on the constraint set rather than on resolved geometry, because geometry cannot be made to
    /// show it here: squeezing the container below the cluster's intrinsic width (~206 pt) does not
    /// overflow the stack, it makes AppKit break the squeeze instead. Leading + trailing with no width
    /// constraint is what makes overflow unrepresentable, whatever the content's resistance.
    ///
    /// The crush it was chasing -- leading and trailing pins mean the stack narrows with the container and
    /// the titles re-wrap mid-travel -- is therefore still open. Fix it with something that clips *for
    /// real*, or with content that does not reflow. Not by letting the stack outgrow its pane.
    func testThePaneContentIsPinnedSoItCannotOutgrowThePane() throws {
        _ = NSApplication.shared
        let pane = DiagnosticsViewController()
        pane.loadViewIfNeeded()
        let container = pane.view
        let stack = try XCTUnwrap(container.subviews.compactMap { $0 as? NSStackView }.first,
                                  "the pane container has no stack view to measure")

        let pins = container.constraints.filter { $0.firstItem === stack || $0.secondItem === stack }
        func pinned(_ attribute: NSLayoutConstraint.Attribute) -> Bool {
            pins.contains { ($0.firstAttribute == attribute || $0.secondAttribute == attribute)
                && ($0.firstItem === container || $0.secondItem === container) }
        }

        XCTAssertTrue(pinned(.leading),
                      "the stack has no leading pin to the pane container — nothing holds its left edge "
                          + "inside the pane, so a narrowing reveal can put it over the editor")
        XCTAssertTrue(pinned(.trailing), "the stack has no trailing pin to the pane container")
        XCTAssertFalse(pinned(.width),
                       "the stack carries a width constraint against the pane, which is what let it draw "
                           + "outside the pane on the way in (2026-10-30) — the pane's width is the "
                           + "divider's business, not the content's")
    }
}
