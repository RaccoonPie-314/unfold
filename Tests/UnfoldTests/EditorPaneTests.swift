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
/// 1. it hosts **no** such line -- re-growing an extra overlay subview over the field is exactly the
///    mistake Task 4 shipped once, so the pinned subview list is a gate, not style. The count is twelve,
///    not eleven: the Enabled control is now a native `NSSwitch` (item 4, 2026-10-29) whose "Enabled" text
///    is a **separate** `NSTextField` label rather than the control's own title, so a real peer control
///    joined the list. The gate is re-asserted on composition (a switch + a label) so it still refuses a
///    stray overlay -- the number moved because the interface gained a view that belongs, not because the
///    invariant loosened.
final class EditorPaneTests: XCTestCase {
    func testThePaneHostsOnlyItsOwnControls() throws {
        // Realizing an `NSViewController`'s view builds AppKit controls, which want the shared
        // application object to exist. `NSApp` is nil before this line.
        _ = NSApplication.shared

        let editor = EditorViewController()
        editor.loadViewIfNeeded()

        // The pane's twelve controls -- three captions, the trigger field, the hint glyph and label,
        // the two scroll views, the pop-up, the `NSSwitch`, its "Enabled" label, and the path label --
        // and nothing above them.
        XCTAssertEqual(editor.view.subviews.count, 12,
                       "the pane hosts a thirteenth view: nothing that draws an overlay over the trigger "
                           + "text belongs here — that is the mistake Task 4 shipped once")

        // The Enabled control is the native pill and the word is a separate label, not a checkbox title.
        XCTAssertTrue(editor.view.subviews.contains { $0 is NSSwitch },
                      "the Enabled control is not an `NSSwitch` — the user asked for the native pill toggle")
        let labels = editor.view.subviews.compactMap { $0 as? NSTextField }
            .filter { $0.stringValue == "Enabled" }
        XCTAssertEqual(labels.count, 1,
                       "the 'Enabled' text must be exactly one separate label beside the switch")
    }
}
