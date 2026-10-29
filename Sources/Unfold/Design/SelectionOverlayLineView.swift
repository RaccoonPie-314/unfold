import AppKit

/// The window-level line `selectionMorph` travels from a sidebar row to the editor's trigger field
/// (Ruling AG). It fills its bounds with the semantic separator colour -- the same colour the
/// pane-hosted proxy used, so it spends no new colour -- draws nothing while hidden, and its `hitTest`
/// returns nil so an overlay covering the whole window can never eat a click.
///
/// **The colour resolves per draw, and a flip triggers that draw.** Measured in-process
/// (`AppearanceFlipTests`, macOS 27.2): a forced paint with the view in aqua fills
/// `separatorColor` as black α0.102 and the same view in darkAqua as white α0.122 -- the components the
/// colour resolves to inside each named appearance -- and one run-loop pass after `NSApp.appearance`
/// changes the view has painted again, with an idle drain painting zero times in between. So no
/// `viewDidChangeEffectiveAppearance` override is needed: an appearance flip mid-morph re-resolves the
/// line on the repaint AppKit already schedules.
///
/// Lives in `Design/` because it is the shell's only custom-drawn view (Ruling AJ2 -- the spec's
/// architecture puts drawing here, not in the coordinator); `MainWindowController` owns the *instance*,
/// because its two rects live in different panes. Internal rather than private only so the overlay tests
/// can read the real view's geometry, and not `final` only so `AppearanceFlipTests` can count `draw(_:)`
/// calls through a subclass that forwards to `super` -- the drawing measured stays this implementation's.
class SelectionOverlayLineView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard !isHidden else { return }
        NSColor.separatorColor.setFill()
        dirtyRect.fill()
    }
}
