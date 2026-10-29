import AppKit
import XCTest
@testable import Unfold

/// The carried question from Task 11: `SelectionOverlayLineView` resolves `NSColor.separatorColor`
/// **inside** `draw(_:)`. Does a colour resolved there re-resolve when the appearance flips -- or does the
/// line stay painted in the old one until something else asks for a redraw?
///
/// Measured in this process on the real class (macOS 27.2, system appearance DarkAqua), two halves:
///
/// 1. **The drawn colour follows the appearance the view draws in.** A draw forced with the view's
///    appearance set to aqua paints `separatorColor` as (0, 0, 0, α0.102); the same view forced under
///    darkAqua paints (1, 1, 1, α0.122). Those are exactly the components the colour resolves to inside
///    each named appearance, so nothing is captured at init and nothing is cached: resolution is per draw.
/// 2. **A flip schedules that draw by itself.** With `draw(_:)` counted: after an app-level flip settles
///    at 6 draws, a second idle 0.2 s drain adds **0**, and one drain after `NSApp.appearance` changes
///    adds **1** -- the invalidation is asynchronous (0 on the assignment itself), so the repaint lands on
///    the next display pass, already in the new appearance. The control is what makes the 1 mean
///    something, and one more number makes it causal: flipping Dark → Match System on a machine already
///    in Dark -- an assignment that changes nothing effective -- added 0.
///
/// Conclusion, and the reason there is **no** `viewDidChangeEffectiveAppearance` override on the class:
/// it would set `needsDisplay` for a repaint AppKit already schedules, and that repaint already resolves
/// the new colour. Both halves are asserted below, so if AppKit ever stops doing either one the suite
/// says so instead of the line quietly holding its old colour through a morph.
///
/// Scope: the overlay only paints for the length of a `selectionMorph`, so the failure this rules out is
/// an appearance flip mid-flight -- a 200 ms line crossing the divider -- not a stale surface at rest.
final class AppearanceFlipTests: XCTestCase {
    @MainActor
    func testTheLineResolvesItsColourAtDrawTimeInEitherAppearance() throws {
        let fixture = try makeFixture()
        defer { fixture.window.orderOut(nil) }
        let line = fixture.line

        func drawnPixel(_ view: NSView) throws -> (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
            let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds),
                                    "no caching rep for a \(view.bounds) view")
            view.cacheDisplay(in: view.bounds, to: rep)
            let color = try XCTUnwrap(rep.colorAt(x: Int(view.bounds.midX.rounded()), y: 0)?
                                        .usingColorSpace(.sRGB),
                                      "the 1 pt line painted nothing at its own centre")
            return (color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent)
        }

        line.appearance = NSAppearance(named: .aqua)
        let light = try drawnPixel(line)
        line.appearance = NSAppearance(named: .darkAqua)
        let dark = try drawnPixel(line)
        line.appearance = nil

        XCTAssertGreaterThan(abs(light.r - dark.r), 0.5,
                             "the same view drew the same red in both appearances — the colour is being "
                                 + "resolved once instead of per draw (light \(light.r), dark \(dark.r))")
        for (name, pixel, appearance) in [("aqua", light, NSAppearance.Name.aqua),
                                          ("dark", dark, NSAppearance.Name.darkAqua)] {
            let expected = try XCTUnwrap(resolvedSeparator(appearance), "\(name) did not resolve")
            XCTAssertEqual(Double(pixel.r), expected.r, accuracy: 0.011, "\(name): red")
            XCTAssertEqual(Double(pixel.g), expected.g, accuracy: 0.011, "\(name): green")
            XCTAssertEqual(Double(pixel.b), expected.b, accuracy: 0.011, "\(name): blue")
            XCTAssertEqual(Double(pixel.a), expected.a, accuracy: 0.011, "\(name): alpha")
        }
    }

    @MainActor
    func testAnAppearanceFlipRepaintsWithoutBeingAsked() throws {
        let fixture = try makeFixture(counting: true)
        defer { fixture.window.orderOut(nil) }
        let line = try XCTUnwrap(fixture.line as? DrawCountingOverlay,
                                 "the fixture did not hand back the counting instance")
        // Restore the process-wide appearance this test moves, same as `ThemeTests` does.
        defer { AppearancePreference.system.apply() }

        // Start from an explicit, *different* appearance, so the flip is a real change whatever the
        // machine's own setting is (this run measured the system as DarkAqua).
        AppearancePreference.light.apply()
        XCTAssertEqual(line.effectiveAppearance.name, .aqua, "the fixture did not land in aqua")
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        let settled = line.draws

        // CONTROL: a drain with nothing changed must repaint nothing, or the count below would prove
        // nothing. This is the assertion that makes the flip measurement a measurement.
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(line.draws, settled,
                       "an idle drain alone repainted the line \(line.draws - settled)× — the flip "
                           + "cannot be credited with a draw the run loop was already taking")

        AppearancePreference.dark.apply()
        XCTAssertEqual(line.effectiveAppearance.name, .darkAqua,
                       "the appearance never reached the view, so there was nothing to re-resolve")
        RunLoop.main.run(until: Date().addingTimeInterval(0.25))

        XCTAssertGreaterThan(line.draws, settled,
                             "the appearance flip scheduled no redraw: the line would keep painting the "
                                 + "old appearance's separator until something else dirtied it, and "
                                 + "`viewDidChangeEffectiveAppearance` would be required (measured "
                                 + "extra draws: \(line.draws - settled))")
    }

    // MARK: - fixtures

    /// Resolves the semantic colour *inside* the named appearance -- the same instrument `Contrast` uses,
    /// so "what `draw` should paint" is derived rather than hardcoded as RGB literals.
    private func resolvedSeparator(_ name: NSAppearance.Name) -> (r: Double, g: Double, b: Double, a: Double)? {
        guard let appearance = NSAppearance(named: name) else { return nil }
        var out: (r: Double, g: Double, b: Double, a: Double)?
        appearance.performAsCurrentDrawingAppearance {
            guard let c = NSColor.separatorColor.usingColorSpace(.sRGB) else { return }
            out = (Double(c.redComponent), Double(c.greenComponent),
                   Double(c.blueComponent), Double(c.alphaComponent))
        }
        return out
    }

    struct Fixture {
        let window: NSWindow
        let line: SelectionOverlayLineView
    }

    /// `DrawCountingOverlay` is `SelectionOverlayLineView` with a counter in front of `super.draw`, so
    /// the drawing being measured is still the production implementation and AppKit's invalidation
    /// decision is the one a plain instance would get.
    final class DrawCountingOverlay: SelectionOverlayLineView {
        private(set) var draws = 0
        override func draw(_ dirtyRect: NSRect) {
            draws += 1
            super.draw(dirtyRect)
        }
    }

    /// A real window ordered front off the corner of any display (on-screen-ness, not position, is what
    /// lets the display pass run), holding an unhidden 1 pt line -- the state the overlay is in for the
    /// length of a morph. `wantsLayer` is left as the window sets it, because the measured redraw path
    /// is the layer-backed one the app actually uses.
    @MainActor
    private func makeFixture(counting: Bool = false) throws -> Fixture {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.setFrameOrigin(NSPoint(x: -3_200, y: -1_800))
        let line: SelectionOverlayLineView = counting ? DrawCountingOverlay() : SelectionOverlayLineView()
        line.frame = NSRect(x: 10, y: 100, width: 300, height: 1)
        line.isHidden = false
        window.contentView!.addSubview(line)
        window.orderFrontRegardless()
        window.layoutIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        return Fixture(window: window, line: line)
    }
}
