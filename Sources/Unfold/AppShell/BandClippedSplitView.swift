import AppKit

/// The split view that keeps its dividers out of the window's titlebar/toolbar band.
///
/// Why it is needed, measured rather than theorised: the window carries `.fullSizeContentView`, so the
/// split view spans the whole window height -- `WindowHierarchyTests` recorded its frame as
/// `(0, 0, 1470, 480)` against a `contentLayoutRect` 428 pt tall, i.e. 52 pt of it under the chrome.
/// The panes honour that underlap through their 52 pt safe-area inset; `NSSplitView` does not. It hands
/// `drawDivider(in:)` "the entire divider rectangle in the receiver's coordinates" (`NSSplitView.h:48`),
/// which reaches the top of the window, so the line paints straight up through the translucent unified
/// toolbar. That is the user's "the separator on the diagnose bar is overlapping" (2026-10-29), and its
/// return on 2026-10-30: the hierarchy change in `5576ff0` moved the divider's *x* and its root wrapper,
/// never its vertical span, and the state it was checked in was the closed one -- where a collapsed
/// divider parks off the right edge and cannot be seen to be wrong.
///
/// Only the **drawn** rect is trimmed. `dividerThickness`, the divider's x and its effective (hit-test)
/// rect stay AppKit's, so divider dragging and `setPosition(_:ofDividerAt:)` are untouched.
final class BandClippedSplitView: NSSplitView {
    /// The rect most recently handed to `super` for a divider. Internal for `DividerChromeClipTests`,
    /// which forces a real display pass to prove the clip sits on AppKit's live drawing path and is not
    /// just correct as a pure function nobody calls.
    private(set) var lastDrawnDividerRect: NSRect?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // `NSSplitViewController` documents its own default as "vertical with a dividerStyle of
        // NSSplitViewDividerStyleThin" (`NSSplitViewController.h:31`). That default belongs to the view
        // *it* creates, so a supplied subclass has to state it: a bare `NSSplitView` is horizontal with
        // thick dividers.
        isVertical = true
        dividerStyle = .thin
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not used") }

    override func drawDivider(in rect: NSRect) {
        let clipped = Self.clip(rect, to: chromeFreeRect)
        lastDrawnDividerRect = clipped
        super.drawDivider(in: clipped)
    }

    /// The part of this view that is not under the window's titlebar/toolbar band, in this view's own
    /// coordinates. `contentLayoutRect` is the window's own statement of that region, so nothing here
    /// hard-codes the 52 pt or assumes a toolbar height.
    private var chromeFreeRect: NSRect {
        guard let window, let host = window.contentView else { return bounds }
        return convert(window.contentLayoutRect, from: host)
    }

    /// Trim `rect` to the band. An empty band means there is nothing to clip against -- pass the rect
    /// through rather than erase every divider in the window over a missing chrome measurement.
    static func clip(_ rect: NSRect, to band: NSRect) -> NSRect {
        band.isEmpty ? rect : rect.intersection(band)
    }
}
