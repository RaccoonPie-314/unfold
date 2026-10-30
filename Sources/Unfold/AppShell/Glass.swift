import AppKit

/// The system's Liquid Glass, and only the system's.
///
/// `NSGlassEffectView` exists from macOS 26, which is this app's floor, so there is no fallback path
/// to maintain and no hand-made blur to imitate it -- an imitation reads as a sticker the moment
/// anything moves behind it, and `liquid-glass.md` treats a fake glass surface as worse than none.
///
/// Placement follows Apple's boundary: glass is the floating **control** layer. The toolbar, the
/// status pill and the diagnostics cluster get it. The combo list and the editor fields do not -- text
/// on a surface that samples the desktop behind the window is text whose contrast nobody can
/// guarantee.
enum Glass {
    /// Wraps a control in glass, with `padding` of glass left around it.
    @MainActor
    static func wrap(_ content: NSView, cornerRadius: CGFloat, padding: CGFloat,
                     interactive: Bool = true) -> NSView {
        let glass = NSGlassEffectView()
        glass.style = .regular
        glass.cornerRadius = cornerRadius
        // The only availability check the shell keeps. The floor is macOS 26 and this property arrived
        // in 27, so below 27 the glass stays static -- its documented default -- rather than the call
        // being faked with a hand-made hover.
        if #available(macOS 27.0, *) { glass.effectIsInteractive = interactive }
        content.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView = content
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: glass.leadingAnchor, constant: padding),
            content.trailingAnchor.constraint(equalTo: glass.trailingAnchor, constant: -padding),
            content.topAnchor.constraint(equalTo: glass.topAnchor, constant: padding),
            content.bottomAnchor.constraint(equalTo: glass.bottomAnchor, constant: -padding),
        ])
        return glass
    }

    /// The window's single backing surface: a material that blurs what is behind it, which is what gives
    /// the glass controls something to refract. `.underWindowBackground` is the material meant for this
    /// slot.
    ///
    /// **Exactly one of these, pinned to the window's content view, behind the whole split view.** It
    /// must not be split into per-pane backings: a `.behindWindow` material only paints where a view
    /// exists, and the 1 pt column each `NSSplitView` divider occupies belongs to no pane, so per-pane
    /// containers leave that column with nothing behind it. On this window -- `isOpaque = false`, clear
    /// background -- the unbacked column is the desktop, and the user sees it as a separator line
    /// crossing the toolbar and "cracking" below it. Measured on a composited capture of the live window
    /// 2026-10-30: alpha 0.000 in the titlebar band, 0.122 below it, against 1.000 one point to either
    /// side.
    ///
    /// The history, so this does not oscillate again: it was the window root until 2026-10-29, when it
    /// moved into the panes to answer a divider crossing the toolbar. That was the wrong diagnosis -- the
    /// root *view controller* was the problem, and only for the divider's x -- and the divider's paint is
    /// now clipped by `BandClippedSplitView` instead. The window stays `isOpaque = false` with a clear
    /// background, or a behind-window material has nothing to sample.
    @MainActor
    static func windowBackground() -> NSView {
        let effect = NSVisualEffectView()
        effect.material = .underWindowBackground
        effect.blendingMode = .behindWindow
        effect.state = .followsWindowActiveState
        return effect
    }
}
