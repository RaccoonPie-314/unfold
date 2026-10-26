import XCTest
@testable import UnfoldEngine

final class MatcherTests: XCTestCase {
    /// A hand correction: the user typed `adrr`, deleted two characters, and is about to type `dr `.
    /// No keystroke sequence spelled `addr` in order, so the candidate has to come from the document.
    func testResyncSeedsACandidateTheKeystrokesNeverSpelled() {
        let addr = makeCombo("addr", replacement: "123 Main St")
        var matcher = Matcher(index: TriggerIndex(combos: [addr]))
        _ = matcher.feed("a"); _ = matcher.feed("d"); _ = matcher.feed("r"); _ = matcher.feed("r")
        _ = matcher.forget()

        matcher.resync(word: "ad")
        XCTAssertEqual(matcher.buffer, "ad")
        XCTAssertEqual(matcher.feed("d"), [.swallow])
        XCTAssertEqual(matcher.feed("r"), [.swallow])
        XCTAssertEqual(matcher.feed(" "), [.expand(addr), .emit(" ")])
    }

    func testResyncRefusesAWordThatCannotBecomeATrigger() {
        var matcher = Matcher(index: TriggerIndex(combos: [makeCombo("addr")]))
        matcher.resync(word: "paddin")
        XCTAssertEqual(matcher.buffer, "")
        matcher.resync(word: "")
        XCTAssertEqual(matcher.buffer, "")
    }

    func testResyncOfACompletedTriggerFiresOnTheNextDelimiter() {
        // The user deleted only the space. The word in front of the caret is the whole trigger.
        let addr = makeCombo("addr", replacement: "123 Main St")
        var matcher = Matcher(index: TriggerIndex(combos: [addr]))
        matcher.resync(word: "addr")

        XCTAssertEqual(matcher.feed(" "), [.expand(addr), .emit(" ")])
    }

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
        XCTAssertEqual(matcher.reset(), [.emit("a"), .emit("d")])
        XCTAssertEqual(matcher.buffer, "")
    }

    // Rule 6 plus rule 7: `reset()` is the adapter's teardown path, so it must hand back what the
    // engine was holding instead of discarding it, and it must not pretend that nothing was ever
    // typed. Deleting the drain makes the second assertion fail; deleting the boundary preservation
    // (i.e. clearing `lastEmitted`) makes the `add ` sequence below expand.
    func testResetDoesNotFabricateAWordBoundary() {
        let add = makeCombo("add")
        var matcher = Matcher(index: TriggerIndex(combos: [add]))

        XCTAssertEqual(matcher.feed("p"), [.emit("p")])
        XCTAssertEqual(matcher.reset(), [], "nothing is buffered, so reset must emit nothing")

        var actions: [MatchAction] = []
        for character in "add " {
            actions.append(contentsOf: matcher.feed(character))
        }
        XCTAssertEqual(
            actions, [.emit("a"), .emit("d"), .emit("d"), .emit(" ")],
            "`p` reached the document, so a match may not begin at `a`"
        )
        XCTAssertFalse(actions.contains(.expand(add)), "reset() must not open a boundary inside a word")
    }

    func testResetEmitsWhateverWasBuffered() {
        let addr = makeCombo("addr")
        var matcher = Matcher(index: TriggerIndex(combos: [addr]))
        XCTAssertEqual(matcher.feed("a"), [.swallow])
        XCTAssertEqual(matcher.feed("d"), [.swallow])

        XCTAssertEqual(matcher.reset(), [.emit("a"), .emit("d")], "a swallowed keystroke is never lost")
        XCTAssertEqual(matcher.buffer, "")
    }

    func testPartialPrefixReleasedOnDelimiter() {
        let actions = collect("add ", from: Matcher(index: TriggerIndex(combos: [makeCombo("address")])))

        XCTAssertEqual(actions, [
            .swallow, .swallow, .swallow,
            .emit("a"), .emit("d"), .emit("d"), .emit(" "),
        ])
    }

    func testTypingAddedNeverFiresTheAddTrigger() {
        let actions = collect("added ", from: Matcher(index: TriggerIndex(combos: [makeCombo("add", replacement: "address")])))

        XCTAssertEqual(actions, [
            .swallow, .swallow, .swallow,
            .emit("a"), .emit("d"), .emit("d"), .emit("e"), .emit("d"), .emit(" "),
        ])
    }

    func testIdleReleaseEmitsBufferedCharacters() {
        var matcher = Matcher(index: TriggerIndex(combos: [makeCombo("addr")]))
        _ = matcher.feed("a")
        _ = matcher.feed("d")
        XCTAssertEqual(matcher.buffer, "ad")

        XCTAssertEqual(matcher.releasePending(), [.emit("a"), .emit("d")])
        XCTAssertEqual(matcher.buffer, "")
    }

    func testIdleReleaseNeverExpandsACompleteTrigger() {
        // Rule 7, second half: releasing buffered characters is verbatim emission, never
        // expansion -- expansion requires a delimiter. Idling on the *complete* trigger
        // "add" must still emit a, d, d rather than fire it.
        let add = makeCombo("add")
        var matcher = Matcher(index: TriggerIndex(combos: [add]))
        _ = matcher.feed("a")
        _ = matcher.feed("d")
        _ = matcher.feed("d")
        XCTAssertEqual(matcher.buffer, "add")

        let released = matcher.releasePending()
        XCTAssertEqual(released, [.emit("a"), .emit("d"), .emit("d")])
        XCTAssertFalse(released.contains(.expand(add)), "releasePending must never expand")
    }

    func testIdleReleaseKeepsTheBoundaryClosedUntilADelimiterArrives() {
        let add = makeCombo("add")
        var matcher = Matcher(index: TriggerIndex(combos: [add]))
        _ = matcher.feed("a")
        XCTAssertEqual(matcher.releasePending(), [.emit("a")])

        // The released `a` reached the document, so an immediately following `a` cannot
        // start a trigger -- rule 6. A delimiter has to reopen the boundary first.
        XCTAssertEqual(matcher.feed("a"), [.emit("a")])
        _ = matcher.feed(" ")
        _ = matcher.feed("a")
        _ = matcher.feed("d")
        _ = matcher.feed("d")
        XCTAssertEqual(matcher.feed(" "), [.expand(add), .emit(" ")])
    }

    func testNothingIsLostAcrossAnExpansionFollowedByAnotherTrigger() {
        let addr = makeCombo("addr", replacement: "123 Main St")
        let add = makeCombo("add", replacement: "address")
        var matcher = Matcher(index: TriggerIndex(combos: [addr, add]))

        let actions = collect("addr add ", from: matcher)

        XCTAssertEqual(actions, [
            .swallow, .swallow, .swallow, .swallow,
            .expand(addr), .emit(" "),
            .swallow, .swallow, .swallow,
            .expand(add), .emit(" "),
        ])
    }

    func testReleasedBufferKeepsTheBoundaryClosedAgainstALaterTrigger() {
        // Releasing the swallowed `add` must leave the boundary closed, so the trailing
        // "ed" cannot quietly start buffering the `ed` trigger and expand on the space.
        // Deleting the `lastEmitted = pending.last` line in releaseBufferThenReconsider()
        // makes this test expand `ed` instead of emitting every keystroke.
        let add = makeCombo("add", replacement: "address")
        let ed = makeCombo("ed", replacement: "e")
        let actions = collect("added ", from: Matcher(index: TriggerIndex(combos: [add, ed])))

        XCTAssertEqual(actions, [
            .swallow, .swallow, .swallow,
            .emit("a"), .emit("d"), .emit("d"), .emit("e"), .emit("d"), .emit(" "),
        ])
        XCTAssertFalse(actions.contains(.expand(ed)), "released 'add' must not let 'ed' expand")
    }

    // With triggers `ad` and `addr`, `add` is a live prefix but not a trigger. The only correct
    // answer when the delimiter arrives is to release it: a `combo(for:)` that fell back to the
    // longest prefix would expand `ad` here and eat the third `d`.
    func testBufferThatIsOnlyAPrefixIsNeverExpanded() {
        let ad = makeCombo("ad", replacement: "advertisement")
        let addr = makeCombo("addr", replacement: "123 Main St")
        let actions = collect("add ", from: Matcher(index: TriggerIndex(combos: [ad, addr])))

        XCTAssertEqual(actions, [
            .swallow, .swallow, .swallow,
            .emit("a"), .emit("d"), .emit("d"), .emit(" "),
        ])
        XCTAssertFalse(actions.contains(.expand(ad)), "`add` is not the trigger `ad`")
        XCTAssertFalse(actions.contains(.expand(addr)), "`add` is not the trigger `addr`")
    }

    // F3: `MatchAction` cannot say which action concerns the event in hand, so the contract is
    // positional and this is what pins it: the last action of every `feed` result is about the
    // character just typed, and everything before it is about characters swallowed earlier -- either
    // the buffer released verbatim, in order, or the single expansion that consumed it.
    func testFeedResultsHonorThePositionalContract() {
        let index = TriggerIndex(combos: [
            makeCombo("add", replacement: "address"),
            makeCombo("addr", replacement: "123 Main St"),
            makeCombo("ed", replacement: "e"),
            makeCombo("a", replacement: "alpha"),
        ])

        for input in ["add ", "addr ", "added ", "padding ", "ad!d", "ad a ", "a", "x add ed ", " add"] {
            var matcher = Matcher(index: index)
            for character in input {
                let bufferedBefore = matcher.buffer
                let actions = matcher.feed(character)
                XCTAssertFalse(actions.isEmpty, "feed(`\(character)`) must account for the event it got")
                let leading = Array(actions.dropLast())

                if leading.count == 1, case .expand(let combo) = leading[0] {
                    XCTAssertEqual(
                        combo.trigger, bufferedBefore,
                        "an expansion in a leading position replaces exactly the buffer (input `\(input)`)"
                    )
                } else if !leading.isEmpty {
                    let released = leading.compactMap(Self.emitted)
                    XCTAssertEqual(
                        released.count, leading.count,
                        "only `.emit` may precede the action for the event in hand (input `\(input)`)"
                    )
                    XCTAssertEqual(
                        String(released), bufferedBefore,
                        "leading `.emit`s are the swallowed buffer, in order (input `\(input)`)"
                    )
                }

                if let last = actions.last {
                    switch last {
                    case .swallow:
                        XCTAssertTrue(
                            matcher.buffer.hasSuffix(String(character)),
                            "`.swallow` means the event in hand is now held in the buffer (input `\(input)`)"
                        )
                    case .emit(let emitted):
                        XCTAssertEqual(emitted, character, "the last action must be the event in hand (input `\(input)`)")
                    case .expand:
                        XCTFail("a `feed` result never ends with `.expand`: the delimiter still has to pass through")
                    }
                }
            }
        }
    }

    private static func emitted(_ action: MatchAction) -> Character? {
        if case .emit(let character) = action { return character }
        return nil
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
