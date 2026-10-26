import CoreGraphics
import Foundation
import XCTest
@testable import UnfoldMac

/// The document is asked before anything is deleted, so every answer it can give needs a test -- and the
/// `false` answer is the one that protects the user's text.
private final class ScriptedText: FocusedTextReading {
    var text: String?
    var range: CFRange?
    /// Models a field that takes the call and puts the selection somewhere else, or not at all.
    var honoursSelection = true
    private(set) var requested: [(location: Int, length: Int)] = []

    func value() -> String? { text }
    func selectedRange() -> CFRange? { range }

    func select(unitsBeforeCaret units: Int) -> Bool {
        guard let current = range, current.length == 0, current.location >= units else { return false }
        let wanted = CFRange(location: current.location - units, length: units)
        requested.append((wanted.location, wanted.length))
        guard honoursSelection else { return false }
        range = wanted
        return true
    }
}

final class DocumentTriggerEraserTests: XCTestCase {
    /// `CFRange` has no `Equatable`, so the ranges the field was asked for are checked piece by piece.
    private func assertAsked(to select: [(Int, Int)], on field: ScriptedText,
                             file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(field.requested.count, select.count, file: file, line: line)
        for (index, wanted) in select.enumerated() where index < field.requested.count {
            XCTAssertEqual(field.requested[index].location, wanted.0, file: file, line: line)
            XCTAssertEqual(field.requested[index].length, wanted.1, file: file, line: line)
        }
    }

    private func field(_ text: String, caret: Int) -> ScriptedText {
        let field = ScriptedText()
        field.text = text
        field.range = CFRange(location: caret, length: 0)
        return field
    }

    func testTheTriggerSittingBeforeTheCaretIsSelected() {
        let source = field("hello addr", caret: 10)

        XCTAssertEqual(DocumentTriggerEraser(text: source).erase(trigger: "addr"), .selected)
        assertAsked(to: [(6, 4)], on: source)
    }

    func testOtherTextBeforeTheCaretMeansStandingDown() {
        let source = field("hello addx", caret: 10)

        XCTAssertEqual(DocumentTriggerEraser(text: source).erase(trigger: "addr"), .absent)
        XCTAssertTrue(source.requested.isEmpty, "nothing is selected when the document says it is not ours")
    }

    /// The shape the reported bug came from: the rewrite runs after the user has already typed the next
    /// word, so the characters in front of the caret are not the trigger any more.
    func testTypingThatGotAheadOfTheRewriteMeansStandingDown() {
        let source = field("hello addr and", caret: 14)

        XCTAssertEqual(DocumentTriggerEraser(text: source).erase(trigger: "addr"), .absent)
        XCTAssertTrue(source.requested.isEmpty)
    }

    func testAFieldThatWillNotSayItsTextIsLeftToTheTally() {
        let silent = ScriptedText()
        silent.text = nil
        silent.range = CFRange(location: 10, length: 0)

        XCTAssertEqual(DocumentTriggerEraser(text: silent).erase(trigger: "addr"), .unknown)
    }

    func testACaretThatIsNotInFrontOfAnythingIsLeftToTheTally() {
        let source = ScriptedText()
        source.text = "hello addr"
        source.range = nil

        XCTAssertEqual(DocumentTriggerEraser(text: source).erase(trigger: "addr"), .unknown)
    }

    /// The user has text selected. Taking the selection away to make room for a snippet is not ours to
    /// do, so this is the tally's problem -- and the tally is what the user watched happen.
    func testAFieldWithASelectionIsNotTouched() {
        let source = field("hello addr", caret: 10)
        source.range = CFRange(location: 10, length: 3)

        XCTAssertEqual(DocumentTriggerEraser(text: source).erase(trigger: "addr"), .unknown)
        XCTAssertTrue(source.requested.isEmpty)
    }

    func testACaretBeyondTheReportedTextIsNotTrusted() {
        let source = field("ab", caret: 40)

        XCTAssertEqual(DocumentTriggerEraser(text: source).erase(trigger: "addr"), .unknown)
    }

    /// A field that reports the range the eraser could not have asked for, or ignores it, has not
    /// actually been selected -- and pasting into it would land on the caret, not on the trigger.
    func testAFieldThatRefusesTheSelectionIsLeftToTheTally() {
        let source = field("hello addr", caret: 10)
        source.honoursSelection = false

        XCTAssertEqual(DocumentTriggerEraser(text: source).erase(trigger: "addr"), .unknown)
    }

    func testATriggerOfSeveralUTF16UnitsIsMeasuredInUnitsNotCharacters() {
        // "e" plus U+0301 is one `Character` and two UTF-16 units, which is what an Accessibility range
        // counts. A tally in characters would select one unit and leave half the trigger on screen.
        let source = field("xe\u{0301}", caret: 3)

        XCTAssertEqual(DocumentTriggerEraser(text: source).erase(trigger: "e\u{0301}"), .selected)
        assertAsked(to: [(1, 2)], on: source)
    }

    func testAnEmptyTriggerErasesNothing() {
        let source = field("hello", caret: 5)

        XCTAssertEqual(DocumentTriggerEraser(text: source).erase(trigger: ""), .unknown)
    }

    /// TextEdit capitalises the first word of a sentence while it is being typed, so the user's `addr`
    /// arrives in the document as `Addr`. Case alone does not make it somebody else's text.
    func testATriggerTheAppRecapitalisedIsStillOurs() {
        let source = field("hello Addr", caret: 10)

        XCTAssertEqual(DocumentTriggerEraser(text: source).erase(trigger: "addr"), .selected)
        assertAsked(to: [(6, 4)], on: source)
    }

    func testAWordThatIsNotTheTriggerEvenInAnotherCaseStandsDown() {
        let source = field("hello ADDRess", caret: 13)

        XCTAssertEqual(DocumentTriggerEraser(text: source).erase(trigger: "addr"), .absent)
        XCTAssertTrue(source.requested.isEmpty)
    }

    func testTheTrailingWordOfAModelIsWhatResyncSees() {
        XCTAssertEqual(DocumentWord.trailingWord("hello addr"), "addr")
        XCTAssertEqual(DocumentWord.trailingWord("hello add"), "add")
        XCTAssertEqual(DocumentWord.trailingWord("hello "), "")
        XCTAssertEqual(DocumentWord.trailingWord("ad,dr"), "dr")
        XCTAssertEqual(DocumentWord.trailingWord(""), "")
    }

    /// An emoji is two UTF-16 units and not a word character, so it ends the run rather than joining it.
    func testATrailingWordStopsAtANonWordCharacter() {
        XCTAssertEqual(DocumentWord.trailingWord("\u{1F600}dd"), "dd")
        XCTAssertEqual(DocumentWord.trailingWord("dd\u{1F600}"), "")
    }
}

