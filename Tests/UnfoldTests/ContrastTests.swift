import AppKit
import XCTest
@testable import Unfold

/// Measured 2026-10-29 on macOS 27.2, with the label's alpha composited over the backing. Without
/// compositing, `secondaryLabelColor` reports 21:1 -- identical to `labelColor` -- because it is a
/// translucent color and the instrument ignored the alpha. That is the lie this test exists to catch.
final class ContrastTests: XCTestCase {
    func testEveryDeclaredPairMeetsItsFloor() {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            XCTAssertEqual(Contrast.failures(in: appearance), [],
                           "\(appearance.rawValue) must have no under-floor pair")
        }
    }

    /// The regression guard for the measurement itself: these are the values the shell had before
    /// Task 7, and the table must now resolve the offending ones through `labelColor`.
    func testMeasuredBaselineOfTheSemanticColors() {
        XCTAssertEqual(Contrast.ratio(foreground: .labelColor, background: .windowBackgroundColor,
                                      appearance: .aqua), 14.938, accuracy: 0.02)
        XCTAssertEqual(Contrast.ratio(foreground: .secondaryLabelColor,
                                      background: .windowBackgroundColor, appearance: .aqua),
                       3.949, accuracy: 0.02,
                       "secondary label under 4.5:1 in Light is the finding, not a bug in the math")
        XCTAssertEqual(Contrast.ratio(foreground: .secondaryLabelColor,
                                      background: .windowBackgroundColor, appearance: .darkAqua),
                       5.890, accuracy: 0.02)
        XCTAssertEqual(Contrast.ratio(foreground: .systemGreen, background: .windowBackgroundColor,
                                      appearance: .aqua), 2.220, accuracy: 0.02)
    }

    func testTableCoversEveryLabelInTheShell() {
        for element in ["caption.trigger", "caption.replacement", "caption.try", "editor.hint",
                        "diagnostics.summary", "diagnostics.result", "editor.path", "row.preview",
                        "row.trigger", "pill.status", "window.title"] {
            XCTAssertTrue(Contrast.pairs.contains { $0.element == element }, "\(element) is undeclared")
        }
    }

    /// The reason the pill is monochrome while it is working. These two are unusable as Light-mode
    /// glyph colours, so this pins the measurement that forced the decision -- if the system ever ships
    /// a greener green, the test says so instead of the table quietly re-adding it.
    func testGreenAndOrangeCannotClearTheGlyphFloorInLight() {
        let green = Contrast.ratio(foreground: .systemGreen, background: .windowBackgroundColor,
                                   appearance: .aqua)
        let orange = Contrast.ratio(foreground: .systemOrange, background: .windowBackgroundColor,
                                    appearance: .aqua)
        let red = Contrast.ratio(foreground: .systemRed, background: .windowBackgroundColor,
                                 appearance: .aqua)
        XCTAssertLessThan(green, 3.0, "systemGreen at \(green) must not be a Light-mode status glyph")
        XCTAssertLessThan(orange, 3.0, "systemOrange at \(orange) must not be a Light-mode status glyph")
        XCTAssertGreaterThanOrEqual(red, 3.0, "red is the status colour, so it has to clear 3:1")
    }
}
