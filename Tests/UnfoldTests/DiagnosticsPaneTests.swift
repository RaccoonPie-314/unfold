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
}
