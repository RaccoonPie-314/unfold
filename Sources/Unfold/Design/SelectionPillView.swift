import AppKit

/// The sidebar's selection indicator: one glass pill that slides between rows.
///
/// The user asked for it on 2026-10-29 ("a glass enlarge pill and just sliding through, native Apple
/// animation tho"). It is **not** the return of `selectionMorph`, which they rejected outright (Ruling
/// AK): that was a 1 pt line travelling from a row *across the split view* to the trigger field. This
/// pill never leaves the list. The system source-list selection fill is switched off
/// (`tableView.selectionHighlightStyle = .none`) and this single surface sits **behind** the row text,
/// inside the table's own document view, so it scrolls with the rows and AppKit's row tiling can never
/// paint over it. Its travel from row to row is one `Motion.morph` under the plan's `selectionSlide`.
///
/// A hand-placed real `NSGlassEffectView` -- the shell's third, after the toolbar status pill and the
/// diagnostics cluster (see the spec's glass-placement table for the reason this one earns its place).
/// `style = .regular` and a `Theme.Radius` corner, **no `tintColor`** -- the colour budget is spent on
/// glyphs, not surfaces (Ruling V's discipline applies here too: no `NSGlassEffectContainerView`, there
/// is exactly one glass view at this site). `effectIsInteractive` stays at its documented default: the
/// pill marks a selection, it is not the background of a control the pointer presses.
final class SelectionPillView: NSView {
    /// The glass surface. Internal, not private, because `SelectionPillTests` measures *where this view
    /// sits in the hierarchy* -- behind the row views, inside the scrolled document -- and placement is
    /// the property this surface lives or dies by; a view the tests cannot name is a placement they
    /// cannot prove.
    let glass = NSGlassEffectView()

    init() {
        super.init(frame: .zero)
        glass.style = .regular
        glass.cornerRadius = Theme.Radius.pill
        glass.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glass)
        NSLayoutConstraint.activate([
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}
