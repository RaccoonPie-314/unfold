import XCTest
@testable import UnfoldEngine

final class MatcherTests: XCTestCase {
    func testTriggerThenDelimiterExpandsAndPassesTheDelimiterThrough() {
        let add = makeCombo("add", replacement: "address")
        var matcher = Matcher(index: TriggerIndex(combos: [add]))

        XCTAssertEqual(matcher.feed("a"), [.swallow])
        XCTAssertEqual(matcher.feed("d"), [.swallow])
        XCTAssertEqual(matcher.feed("d"), [.swallow])
        XCTAssertEqual(matcher.feed(" "), [.expand(add), .emit(" ")])
        XCTAssertEqual(matcher.buffer, "")
    }

    func testPunctuationAlsoCountsAsTheExpandingDelimiter() {
        let add = makeCombo("add", replacement: "address")
        var matcher = Matcher(index: TriggerIndex(combos: [add]))
        _ = matcher.feed("a"); _ = matcher.feed("d"); _ = matcher.feed("d")

        XCTAssertEqual(matcher.feed("!"), [.expand(add), .emit("!")])
    }

    func testDelimiterWithNothingBufferedIsPassedThrough() {
        var matcher = Matcher(index: TriggerIndex(combos: [makeCombo("add")]))
        XCTAssertEqual(matcher.feed(" "), [.emit(" ")])
    }

    func testShorterTriggerWaitsWhileALongerOneIsStillPossible() {
        let ad = makeCombo("ad", replacement: "advertisement")
        var matcher = Matcher(index: TriggerIndex(combos: [ad, makeCombo("add")]))
        _ = matcher.feed("a")

        XCTAssertEqual(matcher.feed("d"), [.swallow])
        XCTAssertEqual(matcher.buffer, "ad")
        XCTAssertEqual(matcher.feed(" "), [.expand(ad), .emit(" ")])
    }

    func testLongerTriggerWinsWhenTypedInFull() {
        let add = makeCombo("add", replacement: "one")
        let address = makeCombo("address", replacement: "two")
        let actions = collect("address ", from: Matcher(index: TriggerIndex(combos: [add, address])))

        XCTAssertEqual(
            actions,
            Array(repeating: MatchAction.swallow, count: 7) + [.expand(address), .emit(" ")]
        )
    }

    func testMatchCannotStartInTheMiddleOfAWord() {
        let actions = collect("padding", from: Matcher(index: TriggerIndex(combos: [makeCombo("add")])))

        XCTAssertEqual(actions, Array("padding").map { MatchAction.emit($0) })
        XCTAssertEqual(actions.count, 7, "no keystroke may be dropped")
    }

    func testSwallowedPrefixIsReleasedWhenTheWordKeepsGrowing() {
        let add = makeCombo("add", replacement: "address")
        let actions = collect("added ", from: Matcher(index: TriggerIndex(combos: [add])))

        XCTAssertEqual(
            actions,
            Array(repeating: MatchAction.swallow, count: 3)
                + [.emit("a"), .emit("d"), .emit("d"), .emit("e"), .emit("d"), .emit(" ")]
        )
        XCTAssertFalse(actions.contains(.expand(add)), "added must never fire the add trigger")
    }

    func testDelimiterOverAPartialPrefixReleasesItInsteadOfDroppingIt() {
        let actions = collect("ad!", from: Matcher(index: TriggerIndex(combos: [makeCombo("addr")])))

        XCTAssertEqual(actions, [MatchAction.swallow, .swallow, .emit("a"), .emit("d"), .emit("!")])
    }

    func testExpansionReopensTheBoundaryForTheNextTrigger() {
        let add = makeCombo("add", replacement: "address")
        var matcher = Matcher(index: TriggerIndex(combos: [add]))
        _ = matcher.feed("a")
        _ = matcher.feed("d")
        _ = matcher.feed("d")

        XCTAssertEqual(matcher.feed(" "), [.expand(add), .emit(" ")])
        // The delimiter, not the replacement text, is what last reached the document.
        XCTAssertEqual(matcher.feed("a"), [.swallow])
        XCTAssertEqual(matcher.buffer, "a")
    }

    func testBufferIsReadableForDiagnostics() {
        var matcher = Matcher(index: TriggerIndex(combos: [makeCombo("addr")]))
        _ = matcher.feed("a")
        _ = matcher.feed("d")
        XCTAssertEqual(matcher.buffer, "ad")
        matcher.reset()
        XCTAssertEqual(matcher.buffer, "")
    }
}

/// Feeds `text` through a copy of `matcher` and returns every action produced.
///
/// `private` on purpose: it must not leak into the shared test-module namespace, and Task 4
/// appends its cases to this same file, so it reuses this helper instead of redeclaring it.
private func collect(_ text: String, from matcher: Matcher) -> [MatchAction] {
    var running = matcher
    var actions: [MatchAction] = []
    for character in text {
        actions.append(contentsOf: running.feed(character))
    }
    return actions
}
