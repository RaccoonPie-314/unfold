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
                      "the button cluster is the stack Task 6 puts in a glass container and Task 10 "
                          + "measures; a different view type means the probe is looking at something else")
        let buttons = (cluster as? NSStackView)?.arrangedSubviews.compactMap { $0 as? NSButton } ?? []
        XCTAssertEqual(buttons.count, 8,
                       "the probe container must be the real button cluster, not a stand-in")
        XCTAssertTrue(cluster.isDescendant(of: pane.view),
                      "Task 10 measures this view's geometry; a view outside the pane's hierarchy has none")

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
