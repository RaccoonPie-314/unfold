import AppKit
import XCTest
@testable import Unfold

/// Ruling B: one status vocabulary, two surfaces. `MenuStatusTests` pins what the menu says; this
/// pins what the pill renders from the *same* decision -- that `shortText` stays compact enough for
/// the toolbar, and that the symbol/colour pairs are exactly the plan's table, so a future edit to
/// either is a deliberate change rather than a drift. The colour rule is the one the measurements
/// forced: red for the five broken states, `labelColor` for `paused` and `listening` --
/// `ContrastTests.testGreenAndOrangeCannotClearTheGlyphFloorInLight` says why green/orange cannot
/// come back.
final class StatusVocabularyTests: XCTestCase {
    /// The whole enum, as literals. `MenuStatus` is deliberately not `CaseIterable` -- a new case must
    /// be answered by every exhaustive switch (`text`, `shortText`, `symbolName`, `emphasisColor`), so
    /// the compiler guards the vocabulary; this list keeps the tests here in step and the table size
    /// pinned below.
    private let everyCase: [MenuStatus] = [
        .notPermitted, .paused, .tapGivenUp, .notReceivingKeystrokes,
        .tapInterrupted, .tapDetached, .listening,
    ]

    func testShortTextIsNonEmptyAndFitsThePill() {
        for status in everyCase {
            XCTAssertFalse(status.shortText.isEmpty, "\(status) must say something on the pill")
            XCTAssertLessThan(status.shortText.count, 14,
                              "\(status)'s pill text «\(status.shortText)» is "
                                  + "\(status.shortText.count) characters; the toolbar pill is "
                                  + "sized for the menu's short forms (Task 12 Step 1)")
        }
    }

    /// The plan's table, verbatim. Editing these strings here is how a vocabulary change gets
    /// noticed; editing them in `MenuStatus` without touching this test is a build-time red flag
    /// in review, not a silent rewording.
    func testSymbolAndShortTextPairsAreThePlansTable() {
        let expected: [MenuStatus: (symbol: String, short: String)] = [
            .notPermitted: ("exclamationmark.triangle.fill", "Grant access"),
            .paused: ("pause.circle.fill", "Paused"),
            .tapGivenUp: ("exclamationmark.triangle.fill", "Tap stopped"),
            .notReceivingKeystrokes: ("exclamationmark.circle.fill", "Tap silent"),
            .tapInterrupted: ("exclamationmark.circle.fill", "Tap off"),
            .tapDetached: ("slash.circle.fill", "Tap off"),
            .listening: ("checkmark.circle.fill", "Ready"),
        ]
        for status in everyCase {
            guard let want = expected[status] else {
                XCTFail("\(status) is not in the table"); continue
            }
            XCTAssertEqual(status.symbolName, want.symbol, "\(status) symbol")
            XCTAssertEqual(status.shortText, want.short, "\(status) short text")
        }
        XCTAssertEqual(expected.count, everyCase.count, "the table and the enum must be the same size")
    }

    /// Red for the five broken states, `labelColor` for the two working ones -- no green, no orange,
    /// nothing else; `systemGreen` (2.22:1) and `systemOrange` (2.31:1) cannot clear the 3:1 glyph
    /// floor in Light mode, which is the measurement Ruling B was written against.
    func testEmphasisColoursAreTheRuledPairOnly() {
        let broken: [MenuStatus] = [.notPermitted, .tapGivenUp, .notReceivingKeystrokes,
                                    .tapInterrupted, .tapDetached]
        let working: [MenuStatus] = [.paused, .listening]
        for status in broken {
            XCTAssertEqual(status.emphasisColor, NSColor.systemRed,
                           "\(status) is a broken state and must read red")
        }
        for status in working {
            XCTAssertEqual(status.emphasisColor, NSColor.labelColor,
                           "\(status) is a working state and must stay monochrome — green and "
                               + "orange fail the Light-mode glyph floor (see ContrastTests)")
        }
        for status in everyCase {
            XCTAssertTrue(status.emphasisColor == NSColor.systemRed
                              || status.emphasisColor == NSColor.labelColor,
                          "\(status) spends a colour the ruling did not allow")
        }
    }

    /// The pill and the menu must describe the same fact from the same case: `shortText` is never a
    /// second opinion, it is keyed off the identical value `text` is keyed off. `evaluate` already
    /// has its precedence tests in `MenuStatusTests`; this pins that both vocabularies are total and
    /// consistent over its outputs.
    func testEveryEvaluatedStatusHasFullVocabulary() {
        for status in everyCase {
            XCTAssertFalse(status.text.isEmpty)
            XCTAssertFalse(status.shortText.isEmpty)
            XCTAssertFalse(status.symbolName.isEmpty)
            // A symbol the system can render: if this fails, the pill would show a placeholder.
            XCTAssertNotNil(NSImage(systemSymbolName: status.symbolName, accessibilityDescription: nil),
                            "\(status) names a symbol that does not exist on this system")
        }
    }
}
