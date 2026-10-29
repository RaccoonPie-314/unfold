import AppKit
import XCTest
@testable import Unfold

/// Regression coverage for the editor pane's morph proxy.
///
/// Task 4 shipped `triggerFieldProxy` -- the 1 pt line the Task 11 shared-element morph animates --
/// *visible*: nothing gated its visibility, so a separator-coloured rule drew through the middle of the
/// user's trigger text on every launch. Review found it by eye, because the plan had created the view
/// and never said when it becomes visible. This is the assertion that would have found it in the suite:
/// the contract is "hidden until the morph unhides it, and still inside the pane's view", and both
/// halves are checkable here -- no window, no app launch, no live `combos.json`.
///
/// Deleting the `triggerProxy.isHidden = true` line in `EditorViewController.loadView()` fails this test.
final class EditorPaneTests: XCTestCase {
    func testTriggerProxyStartsHiddenInsideThePaneView() {
        // Realizing an `NSViewController`'s view builds AppKit controls, which want the shared
        // application object to exist. `NSApp` is nil before this line.
        _ = NSApplication.shared

        let editor = EditorViewController()
        editor.loadViewIfNeeded()

        XCTAssertTrue(editor.triggerFieldProxy.isHidden,
                      "the morph proxy must be hidden until Task 11 shows it — standing by, it paints a "
                          + "line across the trigger text")
        XCTAssertTrue(editor.triggerFieldProxy.isDescendant(of: editor.view),
                      "the proxy has to be the real subview of the pane, positioned by the pinned "
                          + "constraints — a view outside the hierarchy would morph nothing the user sees")
    }
}
