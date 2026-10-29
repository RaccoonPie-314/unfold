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

    /// A pane's backing surface: a material that blurs what is behind it, which is what gives the
    /// glass controls something to refract. `.underWindowBackground` is the material meant for this
    /// slot.
    ///
    /// **Moved to the content layer on 2026-10-29.** It used to be the window's root view behind a
    /// pinned `NSSplitView`; that made the split view span the titlebar band and its divider drew
    /// through the unified toolbar. The split view controller is now the window's own content view
    /// controller -- AppKit's chrome clips the dividers -- and this material is instead the backmost
    /// view of the editor and diagnostics pane containers. Standard materials belong in the content
    /// layer; only Liquid Glass is restricted to the functional layer, so this placement is within
    /// the project's glass rules. The window stays `isOpaque = false` with a clear background, or a
    /// behind-window material has nothing to sample.
    @MainActor
    static func windowBackground() -> NSView {
        let effect = NSVisualEffectView()
        effect.material = .underWindowBackground
        effect.blendingMode = .behindWindow
        effect.state = .followsWindowActiveState
        return effect
    }
}
