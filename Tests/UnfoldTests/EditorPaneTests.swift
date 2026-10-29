import AppKit
import XCTest
@testable import Unfold

/// Coverage for the editor pane.
///
/// The pane used to host a morph proxy over the trigger field -- the 1 pt line a shared-element morph
/// animates -- and Task 4 shipped it *visible*: a separator-coloured rule drew through the middle of the
/// user's trigger text on every launch, found by eye because the plan had created the view and never said
/// when it becomes visible. The line and the morph it belonged to were both removed by user decision on
/// 2026-10-29. What the pane still owes as a regression gate:
///
/// 1. it hosts **no** such line -- re-growing a twelfth overlay subview over the field is exactly the
///    mistake Task 4 shipped once, so the pinned subview list is a gate, not style.
final class EditorPaneTests: XCTestCase {
    func testThePaneHostsOnlyItsOwnControls() throws {
        // Realizing an `NSViewController`'s view builds AppKit controls, which want the shared
        // application object to exist. `NSApp` is nil before this line.
        _ = NSApplication.shared

        let editor = EditorViewController()
        editor.loadViewIfNeeded()

        // The pane's eleven controls -- three captions, the trigger field, the hint glyph and label,
        // the two scroll views, the pop-up, the checkbox, the path label -- and nothing above them.
        XCTAssertEqual(editor.view.subviews.count, 11,
                       "the pane hosts a twelfth view: nothing that draws an overlay over the trigger "
                           + "text belongs here — that is the mistake Task 4 shipped once")
    }
}
