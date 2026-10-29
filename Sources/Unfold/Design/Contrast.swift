import AppKit

/// One pair per labelled element in the shell, and the WCAG math that reads them.
///
/// Meaningful text is floored at 4.5:1 up to 17 pt. That floor is why the captions, the hint line, the
/// counters, the path label and the row preview are `labelColor` and not the `secondaryLabelColor`
/// they used to be: secondary label over a light window background measures 3.95:1, so the colour step
/// that was carrying hierarchy was carrying it below legibility. Hierarchy now comes from 11 pt
/// against 13 pt and weight against weight (`typography.md`, `color.md`).
///
/// A pair's backing is the *opaque* material base, which is the honest approximation for content-layer
/// text. Text on glass samples whatever is behind the window and cannot be computed here; the pill is
/// covered by a screenshot pass in Task 12 instead, and its label is monochrome `labelColor` for the
/// same reason.
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
        .init(element: "editor.path", text: .labelColor, backing: .windowBackgroundColor, floor: 4.5),
        .init(element: "row.trigger", text: .labelColor, backing: .windowBackgroundColor, floor: 4.5),
        .init(element: "row.preview", text: .labelColor, backing: .windowBackgroundColor, floor: 4.5),
        .init(element: "pill.status", text: .labelColor, backing: .windowBackgroundColor, floor: 4.5),
        // The status glyph is the one coloured element in the control layer, and red is the only
        // semantic status colour that clears the 3:1 graphic floor in both appearances -- measured,
        // systemGreen is 2.22:1 and systemOrange 2.31:1 in Light. Task 12 therefore renders the
        // working and paused states in `labelColor` and colours only the broken ones.
        .init(element: "pill.statusSymbol", text: .systemRed, backing: .windowBackgroundColor, floor: 3.0),
        // The one place contrast is deliberately lowered: "disabled" is the message, and the slash
        // symbol plus the tooltip say it without colour.
        .init(element: "row.triggerDisabled", text: .secondaryLabelColor,
              backing: .windowBackgroundColor, floor: 3.0),
    ]

    static func ratio(foreground: NSColor, background: NSColor,
                      appearance: NSAppearance.Name) -> Double {
        guard let named = NSAppearance(named: appearance),
              let f = resolve(foreground, in: named), let b = resolve(background, in: named) else {
            return -1
        }
        let l1 = luminance(composite(f, b)), l2 = luminance((b.r, b.g, b.b))
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    static func failures(in appearance: NSAppearance.Name) -> [String] {
        pairs.filter { ratio(foreground: $0.text, background: $0.backing, appearance: appearance) < $0.floor }
             .map { "\($0.element) = \(String(format: "%.2f", ratio(foreground: $0.text, background: $0.backing, appearance: appearance))):1 under \($0.floor)" }
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
