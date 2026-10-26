import AppKit

/// The system's Liquid Glass, and only the system's.
///
/// `NSGlassEffectView` exists from macOS 26. Where it does not exist, these helpers hand back the
/// plain view rather than imitating glass with a hand-made blur -- an imitation reads as a sticker
/// the moment anything moves behind it, and `liquid-glass.md` treats a fake glass surface as worse
/// than no glass surface.
///
/// Placement follows Apple's own boundary: glass is the floating **control** layer. The toolbar, the
/// status pill and the diagnostics panel get it. The combo list and the editor fields do not -- text
/// sitting on a surface that samples the desktop behind the window is text whose contrast nobody can
/// guarantee.
enum Glass {
    /// Wraps a control in glass, with `padding` of glass left around it.
    @MainActor
    static func wrap(_ content: NSView, cornerRadius: CGFloat, padding: CGFloat,
                     interactive: Bool = true, tint: NSColor? = nil) -> NSView {
        guard #available(macOS 26.0, *) else { return content }
        let glass = NSGlassEffectView()
        glass.style = .regular
        glass.cornerRadius = cornerRadius
        if #available(macOS 27.0, *) { glass.effectIsInteractive = interactive }
        if let tint { glass.tintColor = tint }
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
    /// glass controls something to refract. Apple's `.underWindowBackground` is the material meant
    /// for exactly this slot.
    @MainActor
    static func windowBackground() -> NSView {
        let effect = NSVisualEffectView()
        effect.material = .underWindowBackground
        effect.blendingMode = .behindWindow
        effect.state = .followsWindowActiveState
        return effect
    }
}
