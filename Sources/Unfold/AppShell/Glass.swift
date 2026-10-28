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

    /// The window's own surface: a material that blurs what is behind it, which is what gives the
    /// glass controls something to refract. `.underWindowBackground` is the material meant for this
    /// slot.
    @MainActor
    static func windowBackground() -> NSView {
        let effect = NSVisualEffectView()
        effect.material = .underWindowBackground
        effect.blendingMode = .behindWindow
        effect.state = .followsWindowActiveState
        return effect
    }
}
