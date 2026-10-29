import AppKit
import XCTest
@testable import Unfold

/// Coverage for the editor pane after Ruling AG.
///
/// The pane used to host a morph proxy over the trigger field -- the 1 pt line the shared-element morph
/// animates -- and Task 4 shipped it *visible*: a separator-coloured rule drew through the middle of the
/// user's trigger text on every launch, found by eye because the plan had created the view and never
/// said when it becomes visible. Ruling AG moved the line to `MainWindowController`'s window-level
/// overlay (see `SelectionOverlayTests`, which now owns the hidden-at-rest half of that guard), because
/// the split view's `_NSSplitViewItemViewWrapper` -- `masksToBounds == true`, measured in the Task 11b
/// note §5.2 -- clipped the morph's `k ≈ 40` start pose inside the pane. What the pane still owes:
///
/// 1. it hosts **no** such line -- re-growing a twelfth subview over the field would put the shared
///    element back behind a clipping wrapper, so the pinned subview list is a regression gate, not
///    style; and
/// 2. `triggerFieldFrameInWindow`, the accessor the morph lands on, answers nil with no window and
///    the field's rect in screen coordinates once it has one.
final class EditorPaneTests: XCTestCase {
    func testPaneHostsNoMorphLineAndStillAnswersTheLandingRect() throws {
        // Realizing an `NSViewController`'s view builds AppKit controls, which want the shared
        // application object to exist. `NSApp` is nil before this line.
        _ = NSApplication.shared

        let editor = EditorViewController()
        editor.loadViewIfNeeded()

        // The pane's eleven controls -- three captions, the trigger field, the hint glyph and label,
        // the two scroll views, the pop-up, the checkbox, the path label -- and nothing above them.
        XCTAssertEqual(editor.view.subviews.count, 11,
                       "the pane hosts a twelfth view: Ruling AG moved the morph line to the window's "
                           + "content view because this pane's wrapper clips it — nothing that draws a "
                           + "line over the trigger text belongs here")
        XCTAssertNil(editor.triggerFieldFrameInWindow,
                     "no window, no landing rect: the accessor answers nil rather than reading "
                         + "geometry out of a detached view tree")

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 420),
                              styleMask: [.titled],
                              backing: .buffered,
                              defer: false)
        window.contentView = editor.view
        window.setFrameOrigin(NSPoint(x: -3_200, y: -1_800))
        window.orderFrontRegardless()
        editor.view.layoutSubtreeIfNeeded()
        defer { window.orderOut(nil) }

        let landing = try XCTUnwrap(editor.triggerFieldFrameInWindow,
                                    "with a window the accessor must answer, or the selection morph "
                                        + "has no destination")
        let contentOnScreen = window.convertToScreen(window.contentView!.frame)
        XCTAssertTrue(contentOnScreen.contains(landing),
                      "the landing rect is not inside the window it belongs to: \(landing) vs \(contentOnScreen)")
        XCTAssertGreaterThan(landing.width, 100, "the trigger field is a wide control, not a sliver")
        XCTAssertGreaterThan(landing.height, 0, "a non-heighted landing means the layout has not run")
    }
}
