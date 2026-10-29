import AppKit

/// One pair per labelled element in the shell, and the WCAG math that reads them.
///
/// Meaningful text is floored at 4.5:1 up to 17 pt. That floor is why the captions, the hint line, the
/// counters, the path label and the row preview are `labelColor` and not the `secondaryLabelColor`
/// they used to be: secondary label over a light window background measures 3.95:1, so the colour step
/// that was carrying hierarchy was carrying it below legibility. Hierarchy now comes from 11 pt
/// against 13 pt and weight against weight (`typography.md`, `color.md`).
///
/// A pair's backing is the *opaque* material base, and that makes every row here a **best case**: the
/// equivalent of full reduce-transparency, never the surface the app actually renders. The window roots
/// itself in `Glass.windowBackground()` -- an `NSVisualEffectView` with `blendingMode = .behindWindow` on
/// a non-opaque window -- so the desktop reads through the panes and *all* of this text, the pill included,
/// samples colours this table cannot see; the inactive-window material swap is unmodelled here too. The
/// numbers stay because they are the ceiling worth measuring, but the real ratios for the pane text, not
/// only the pill, belong to Task 12's capture pass.
struct ContrastPair {
    let element: String
    let text: NSColor
    let backing: NSColor
    /// 4.5 for text, 3.0 for a glyph or large text.
    let floor: Double
}

enum Contrast {
    static let pairs: [ContrastPair] = [
        .init(element: "window.title", text: .labelColor, backing: .windowBackgroundColor, floor: 4.5),
        .init(element: "caption.trigger", text: .labelColor, backing: .windowBackgroundColor, floor: 4.5),
        .init(element: "caption.replacement", text: .labelColor, backing: .windowBackgroundColor, floor: 4.5),
        .init(element: "caption.try", text: .labelColor, backing: .windowBackgroundColor, floor: 4.5),
        .init(element: "editor.hint", text: .labelColor, backing: .windowBackgroundColor, floor: 4.5),
        .init(element: "diagnostics.summary", text: .labelColor, backing: .windowBackgroundColor, floor: 4.5),
        .init(element: "diagnostics.result", text: .labelColor, backing: .windowBackgroundColor, floor: 4.5),
        .init(element: "diagnostics.section", text: .labelColor, backing: .windowBackgroundColor, floor: 4.5),
        .init(element: "editor.path", text: .labelColor, backing: .windowBackgroundColor, floor: 4.5),
        .init(element: "row.trigger", text: .labelColor, backing: .windowBackgroundColor, floor: 4.5),
        .init(element: "row.preview", text: .labelColor, backing: .windowBackgroundColor, floor: 4.5),
        // **Deliberately absent: the on-pill pairs.** The selected row's two lines render over
        // `SelectionPillView`'s glass, and the only honest backing for that is the translucent
        // `NSGlassEffectView` itself -- which samples whatever is behind the window, a colour this table
        // cannot name. `ratio` refuses a translucent backing rather than inventing one, so certifying
        // `row.triggerOnPill` / `row.previewOnPill` here would mean pointing them at
        // `windowBackgroundColor` and calling the number honest. It is not: the pair is left to the
        // live pass (both appearances, over a light and a dark desktop picture). The colours themselves
        // are the ones above -- `labelColor`, and `secondaryLabelColor` for a disabled trigger -- because
        // with the system highlight off, what `ComboRowView.apply` sets is exactly what the glass carries.
        .init(element: "pill.status", text: .labelColor, backing: .windowBackgroundColor, floor: 4.5),
        // The status glyph is the one coloured element in the control layer, and red is the only
        // semantic status colour that clears the 3:1 graphic floor in both appearances -- measured,
        // systemGreen is 2.22:1 and systemOrange 2.31:1 in Light. Task 12 therefore renders the
        // working and paused states in `labelColor` and colours only the broken ones.
        .init(element: "pill.statusSymbol", text: .systemRed, backing: .windowBackgroundColor, floor: 3.0),
        // 3.0 and not 4.5: a glyph beside a sentence that already states the fact is decorative for
        // contrast purposes (WCAG 1.4.11), so it holds the graphic floor. `showHint`'s failure triangle.
        .init(element: "editor.hintSymbol", text: .systemRed, backing: .windowBackgroundColor, floor: 3.0),
        // The one place contrast is deliberately lowered: "disabled" is the message, and the slash
        // symbol plus the tooltip say it without colour.
        .init(element: "row.triggerDisabled", text: .secondaryLabelColor,
              backing: .windowBackgroundColor, floor: 3.0),
        // 3.0 and not 4.5: the slash says what the trigger label's own dimming and the row tooltip
        // already say, so it is measured as a graphic, not as text. `ComboRowView`'s disabled symbol.
        .init(element: "row.disabledSymbol", text: .secondaryLabelColor,
              backing: .windowBackgroundColor, floor: 3.0),
    ]

    /// Returned when no measurement exists: an unresolvable appearance, a colour that will not convert
    /// to sRGB, or a translucent backing. It is not a ratio, and `failures(in:)` never prints it as one.
    static let cannotMeasure = -1.0

    static func ratio(foreground: NSColor, background: NSColor,
                      appearance: NSAppearance.Name) -> Double {
        guard let named = NSAppearance(named: appearance),
              let f = resolve(foreground, in: named), let b = resolve(background, in: named) else {
            return cannotMeasure
        }
        // A translucent backing is refused rather than composited: `composite` has nothing behind the
        // backing to blend toward, so it would silently treat the backing as its own dim colour and
        // overstate the ratio. Every declared backing is opaque today -- `windowBackgroundColor` measures
        // a = 1.0000 in both appearances -- so a translucent one means a new row pointed at a material
        // base this table cannot certify, which is a bug in the table. The sentinel says so out loud.
        guard b.a == 1 else { return cannotMeasure }
        let l1 = luminance(composite(f, b)), l2 = luminance((b.r, b.g, b.b))
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    static func failures(in appearance: NSAppearance.Name) -> [String] {
        pairs.compactMap { pair in
            let measured = ratio(foreground: pair.text, background: pair.backing, appearance: appearance)
            // A broken gauge must not look like a pair that failed, or like one that passed at -1.00:1.
            if measured == cannotMeasure {
                return "\(pair.element): measurement failed — the instrument broke, not the colour"
            }
            guard measured < pair.floor else { return nil }
            return "\(pair.element) = \(String(format: "%.2f", measured)):1 under \(pair.floor)"
        }
    }

    /// A semantic color must be resolved *inside* the appearance it is being measured against, or
    /// `usingColorSpace` hands back whatever the process default says.
    private static func resolve(_ color: NSColor, in appearance: NSAppearance)
        -> (r: Double, g: Double, b: Double, a: Double)? {
        var out: (Double, Double, Double, Double)?
        appearance.performAsCurrentDrawingAppearance {
            guard let c = color.usingColorSpace(.sRGB) else { return }
            out = (Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent),
                   Double(c.alphaComponent))
        }
        guard let o = out else { return nil }
        return (o.0, o.1, o.2, o.3)
    }

    /// Label colors are translucent, so the backing must be composited before any luminance is taken.
    private static func composite(_ f: (r: Double, g: Double, b: Double, a: Double),
                                  _ b: (r: Double, g: Double, b: Double, a: Double))
        -> (Double, Double, Double) {
        (f.a * f.r + (1 - f.a) * b.r, f.a * f.g + (1 - f.a) * b.g, f.a * f.b + (1 - f.a) * b.b)
    }

    private static func luminance(_ t: (Double, Double, Double)) -> Double {
        func channel(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * channel(t.0) + 0.7152 * channel(t.1) + 0.0722 * channel(t.2)
    }
}
