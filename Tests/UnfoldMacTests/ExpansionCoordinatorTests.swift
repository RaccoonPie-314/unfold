import CoreGraphics
import UnfoldEngine
import XCTest
@testable import UnfoldMac

private final class FakeInjector: TextInjecting {
    var insertions: [(String, InsertionMode)] = []
    /// The tally the rewrite was given, in characters. The document's own answer is a separate seam --
    /// see `DocumentTriggerEraserTests`.
    var deletions: [Int] = []
    var erasedTriggers: [String] = []
    var literals: [String] = []
    /// False models a field that reports its own contents and says the trigger is not in front of the
    /// caret: the rewrite must then stand down instead of deleting what it finds there.
    var erases = true

    func insert(_ text: String, mode: InsertionMode) { insertions.append((text, mode)) }
    func eraseTrigger(_ trigger: String, typedCount: Int) -> Bool {
        erasedTriggers.append(trigger)
        deletions.append(typedCount)
        return erases
    }
    func typeLiteral(_ text: String) { literals.append(text) }
}

private final class RepostRecorder {
    var posted: [CGEvent] = []
    func record(_ event: CGEvent) { posted.append(event) }
}

private func combo(_ trigger: String, parts: [Part], enabled: Bool = true,
                   insertion: InsertionMode = .paste) -> Combo {
    Combo(id: UUID(), trigger: trigger, label: trigger, enabled: enabled,
          parts: parts, insertion: insertion)
}

private func textPart(_ value: String) -> Part { .text(value) }

private func keyEvent(_ virtualKey: Int, down: Bool) -> CGEvent {
    CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(virtualKey), keyDown: down)!
}

// CGEvent is a CF type with no Equatable conformance, so events are compared by identity. Do not add
// `==` to TapOutcome to shorten assertions.
private func isPass(_ outcome: TapOutcome) -> Bool {
    if case .pass = outcome { return true }
    return false
}

private func passedEvent(_ outcome: TapOutcome) -> CGEvent? {
    switch outcome {
    case .pass(let event): return event
    case .repost(_, thenPass: let event): return event
    case .swallow: return nil
    }
}

/// The adapter's contract changed on 2026-10-24 after live testing: it no longer swallows a trigger
/// prefix, because invisible typing is not acceptable. Every keystroke renders; when a trigger
/// completes, exactly the characters typed are deleted and the replacement inserted. These tests pin
/// that contract, not the old hold-and-release one.
final class ExpansionCoordinatorTests: XCTestCase {
    private func subject(_ combos: [Combo], trusted: Bool = true)
        -> (ExpansionCoordinator, FakeInjector, RepostRecorder) {
        let injector = FakeInjector()
        let recorder = RepostRecorder()
        let coordinator = ExpansionCoordinator(
            combos: combos,
            injector: injector,
            repost: { recorder.posted.append($0) },
            isTrusted: { trusted },
            perform: { $0() }
        )
        coordinator.resume()
        return (coordinator, injector, recorder)
    }

    func testPlaceholderCombosAreCountedButNotRegistered() {
        let prompted = combo("citytrip", parts: [.placeholder(.init(id: "city", options: []))])
        let (coordinator, _, _) = subject([combo("addr", parts: [textPart("123 Main St")]), prompted])

        XCTAssertEqual(coordinator.activeCount, 1)
        XCTAssertEqual(coordinator.inactivePlaceholderCount, 1)
        XCTAssertEqual(coordinator.registeredTriggers, ["addr"])
    }

    func testDisabledCombosAppearInNeitherCount() {
        let off = combo("addr", parts: [textPart("123 Main St")], enabled: false)
        let (coordinator, _, _) = subject([off])

        XCTAssertEqual(coordinator.activeCount, 0)
        XCTAssertEqual(coordinator.inactivePlaceholderCount, 0)
    }

    func testATriggerPrefixIsRenderedNotSwallowed() {
        let (coordinator, injector, recorder) = subject([combo("addr", parts: [textPart("123 Main St")])])
        let a = keyEvent(0, down: true)

        let outcome = coordinator.handle(.keyDown("a", 0), flags: [], original: a)

        XCTAssertTrue(passedEvent(outcome) === a, "the user must see the character they typed")
        XCTAssertEqual(recorder.posted.count, 0)
        XCTAssertTrue(injector.insertions.isEmpty)
    }

    func testCompletingATriggerDeletesWhatWasTypedThenInserts() {
        let (coordinator, injector, _) = subject([combo("addr", parts: [textPart("123 Main St")])])
        for (character, code) in [(Character("a"), 0), (Character("d"), 2), (Character("d"), 2), (Character("r"), 15)] {
            _ = coordinator.handle(.keyDown(character, code), flags: [], original: keyEvent(code, down: true))
        }

        let space = keyEvent(49, down: true)
        let outcome = coordinator.handle(.keyDown(" ", 49), flags: [], original: space)

        XCTAssertFalse(isPass(outcome), "the delimiter is swallowed and re-typed after the insertion")
        XCTAssertEqual(injector.deletions, [4], "exactly the four typed characters are erased")
        XCTAssertEqual(injector.insertions.count, 1)
        XCTAssertEqual(injector.insertions.first?.0, "123 Main St")
        XCTAssertEqual(injector.literals, [" "], "the space the user pressed still lands, after the text")
    }

    func testAFieldThatNoLongerHoldsTheTriggerStillLandsTheDelimiter() {
        let (coordinator, injector, _) = subject([combo("addr", parts: [textPart("123 Main St")])])
        injector.erases = false
        for character in "addr" {
            _ = coordinator.handle(.keyDown(character, 0), flags: [], original: keyEvent(0, down: true))
        }

        let outcome = coordinator.handle(.keyDown(" ", 49), flags: [], original: keyEvent(49, down: true))

        XCTAssertFalse(isPass(outcome))
        XCTAssertEqual(injector.erasedTriggers, ["addr"], "the document is asked about the trigger, not a count")
        XCTAssertTrue(injector.insertions.isEmpty, "nothing is pasted over text that is not ours")
        XCTAssertEqual(injector.literals, [" "], "the swallowed keystroke is still owed to the user")
    }

    /// The other half of the complaint: delete the whole word and type it again. The model empties as
    /// the characters go, so the retyped word starts clean.
    func testATriggerRetypedAfterBeingFullyDeletedStillExpands() {
        let (coordinator, injector, _) = subject([combo("addr", parts: [textPart("123 Main St")])])
        for (character, code) in [(Character("a"), 0), (Character("d"), 2), (Character("d"), 2),
                                  (Character("r"), 15)] {
            _ = coordinator.handle(.keyDown(character, code), flags: [], original: keyEvent(code, down: true))
        }
        for _ in 0..<4 {
            _ = coordinator.handle(.edit(51), flags: [], original: keyEvent(51, down: true))
            _ = coordinator.handle(.keyUp(51), flags: [], original: keyEvent(51, down: false))
        }

        for (character, code) in [(Character("a"), 0), (Character("d"), 2), (Character("d"), 2),
                                  (Character("r"), 15)] {
            _ = coordinator.handle(.keyDown(character, code), flags: [], original: keyEvent(code, down: true))
        }
        _ = coordinator.handle(.keyDown(" ", 49), flags: [], original: keyEvent(49, down: true))

        XCTAssertEqual(injector.erasedTriggers, ["addr"], "the retyped word is a fresh word")
        XCTAssertEqual(injector.insertions.map(\.0), ["123 Main St"])
    }

    func testAPartialCorrectionCompletesFromTheDocument() {
        let (coordinator, injector, _) = subject([combo("addr", parts: [textPart("123 Main St")])])
        for (character, code) in [(Character("a"), 0), (Character("d"), 2), (Character("r"), 15),
                                  (Character("r"), 15)] {
            _ = coordinator.handle(.keyDown(character, code), flags: [], original: keyEvent(code, down: true))
        }
        for _ in 0..<2 {
            _ = coordinator.handle(.edit(51), flags: [], original: keyEvent(51, down: true))
            _ = coordinator.handle(.keyUp(51), flags: [], original: keyEvent(51, down: false))
        }

        _ = coordinator.handle(.keyDown("d", 2), flags: [], original: keyEvent(2, down: true))
        _ = coordinator.handle(.keyDown("r", 15), flags: [], original: keyEvent(15, down: true))
        _ = coordinator.handle(.keyDown(" ", 49), flags: [], original: keyEvent(49, down: true))

        XCTAssertEqual(injector.erasedTriggers, ["addr"], "the word in the document is the candidate")
        XCTAssertEqual(injector.insertions.map(\.0), ["123 Main St"])
    }

    /// A caret move changes no text, so there is nothing to re-read. Reseeding on a move would let an
    /// arrow key arm an expansion nobody typed.
    func testACaretMoveClearsTheCandidateWithoutReseedingIt() {
        let (coordinator, injector, _) = subject([combo("addr", parts: [textPart("123 Main St")])])
        _ = coordinator.handle(.keyDown("a", 0), flags: [], original: keyEvent(0, down: true))
        _ = coordinator.handle(.keyDown("d", 2), flags: [], original: keyEvent(2, down: true))

        _ = coordinator.handle(.edit(123), flags: [], original: keyEvent(123, down: true))

        _ = coordinator.handle(.keyDown("d", 2), flags: [], original: keyEvent(2, down: true))
        _ = coordinator.handle(.keyDown("r", 15), flags: [], original: keyEvent(15, down: true))
        _ = coordinator.handle(.keyDown(" ", 49), flags: [], original: keyEvent(49, down: true))

        XCTAssertTrue(injector.insertions.isEmpty, "an arrow key must not arm an expansion")
    }

    /// `⌥⌫` deletes a word and `⌘⌫` the line. A model that dropped one character for each would end up
    /// longer than the screen, and the next correction would be computed from text that is not there.
    func testWordAndLineDeletionsMoveTheModelByWhatTheyActuallyRemove() {
        let (coordinator, injector, _) = subject([combo("addr", parts: [textPart("123 Main St")])])
        for (character, code) in [(Character("a"), 0), (Character("d"), 2), (Character("d"), 2),
                                  (Character("r"), 15)] {
            _ = coordinator.handle(.keyDown(character, code), flags: [], original: keyEvent(code, down: true))
        }
        // ⌥⌫: the app drops the whole word. The model must agree, so the candidate that follows is
        // rebuilt from what is left rather than from a word that no longer exists.
        _ = coordinator.handle(.edit(51), flags: .maskAlternate, original: keyEvent(51, down: true))
        _ = coordinator.handle(.keyUp(51), flags: .maskAlternate, original: keyEvent(51, down: false))

        for (character, code) in [(Character("a"), 0), (Character("d"), 2), (Character("d"), 2),
                                  (Character("r"), 15)] {
            _ = coordinator.handle(.keyDown(character, code), flags: [], original: keyEvent(code, down: true))
        }
        _ = coordinator.handle(.keyDown(" ", 49), flags: [], original: keyEvent(49, down: true))

        XCTAssertEqual(injector.insertions.map(\.0), ["123 Main St"],
                       "the model has to match the screen after a word delete")
    }

    /// Clearing the field with ⌘A then delete empties the document, but our model of it sees only the
    /// one delete. Keeping the rest of the model makes every later correction answer with words that
    /// are not on screen -- the reported "it only works once".
    func testASelectAllShortcutThrowsTheModelAway() {
        let (coordinator, injector, _) = subject([combo("addr", parts: [textPart("123 Main St")])])
        func type(_ text: String) {
            for character in text {
                _ = coordinator.handle(.keyDown(character, 0), flags: [], original: keyEvent(0, down: true))
            }
        }
        func backspace() {
            _ = coordinator.handle(.edit(51), flags: [], original: keyEvent(51, down: true))
            _ = coordinator.handle(.keyUp(51), flags: [], original: keyEvent(51, down: false))
        }

        type("adddr")
        // ⌘A: a shortcut we never render, whose effect on the document we cannot see.
        _ = coordinator.handle(.keyDown("a", 0), flags: .maskCommand, original: keyEvent(0, down: true))
        backspace()

        type("adddr")
        for _ in 0..<3 { backspace() }   // leaves "ad"
        type("dr ")
        XCTAssertEqual(injector.insertions.map(\.0), ["123 Main St"],
                       "the correction after a select-all clear has to work")
    }

    func testAnIdleTickWhileTheTriggerIsStillBeingTypedDoesNotAbandonIt() {
        let (coordinator, injector, _) = subject([combo("addr", parts: [textPart("123 Main St")])])
        for (character, code) in [(Character("a"), 0), (Character("d"), 2), (Character("d"), 2)] {
            _ = coordinator.handle(.keyDown(character, code), flags: [], original: keyEvent(code, down: true))
        }

        // The timer ticks whatever the keys are doing. One second after the last keystroke is not idle,
        // and draining anyway would clear a candidate one character from completing.
        _ = coordinator.handleIdle(now: Date().addingTimeInterval(1))

        _ = coordinator.handle(.keyDown("r", 15), flags: [], original: keyEvent(15, down: true))
        _ = coordinator.handle(.keyDown(" ", 49), flags: [], original: keyEvent(49, down: true))

        XCTAssertEqual(injector.insertions.map(\.0), ["123 Main St"],
                       "a candidate the person is still typing survives an early tick")
    }

    func testEightSecondsOfSilenceAbandonsTheCandidate() {
        let (coordinator, injector, _) = subject([combo("addr", parts: [textPart("123 Main St")])])
        _ = coordinator.handle(.keyDown("a", 0), flags: [], original: keyEvent(0, down: true))

        _ = coordinator.handleIdle(now: Date().addingTimeInterval(ExpansionCoordinator.idleGrace))

        for (character, code) in [(Character("d"), 2), (Character("d"), 2), (Character("r"), 15)] {
            _ = coordinator.handle(.keyDown(character, code), flags: [], original: keyEvent(code, down: true))
        }
        _ = coordinator.handle(.keyDown(" ", 49), flags: [], original: keyEvent(49, down: true))

        XCTAssertTrue(injector.insertions.isEmpty,
                      "after a walk-away the word starts over, so the abandoned 'a' cannot complete it")
    }

    func testAPrefixThatStopsMatchingDoesNotTouchTheInjector() {
        let (coordinator, injector, _) = subject([combo("addr", parts: [textPart("123 Main St")])])
        _ = coordinator.handle(.keyDown("a", 0), flags: [], original: keyEvent(0, down: true))
        let z = keyEvent(44, down: true)

        XCTAssertTrue(passedEvent(coordinator.handle(.keyDown("z", 44), flags: [], original: z)) === z)
        XCTAssertTrue(injector.deletions.isEmpty)
        XCTAssertTrue(injector.insertions.isEmpty)
    }

    func testABlockingModifierNeitherSwallowsNorInjects() {
        let (coordinator, injector, _) = subject([combo("addr", parts: [textPart("123 Main St")])])
        _ = coordinator.handle(.keyDown("a", 0), flags: [], original: keyEvent(0, down: true))

        let commandD = keyEvent(2, down: true)
        let outcome = coordinator.handle(.keyDown("d", 2), flags: .maskCommand, original: commandD)

        XCTAssertTrue(passedEvent(outcome) === commandD)
        XCTAssertTrue(injector.deletions.isEmpty)
    }

    func testPausedExpansionPassesEverythingAndInjectsNothing() {
        let (coordinator, injector, _) = subject([combo("add", parts: [textPart("address")])])
        _ = coordinator.pause()

        for (character, code) in [(Character("a"), 0), (Character("d"), 2), (Character("d"), 2), (Character(" "), 49)] {
            let event = keyEvent(code, down: true)
            XCTAssertTrue(passedEvent(coordinator.handle(.keyDown(character, code), flags: [],
                                                          original: event)) === event)
        }
        XCTAssertTrue(injector.insertions.isEmpty)
        XCTAssertTrue(injector.deletions.isEmpty)
    }

    func testResumingAfterPauseExpandsAgain() {
        let (coordinator, injector, _) = subject([combo("add", parts: [textPart("address")])])
        _ = coordinator.pause()
        coordinator.resume()

        for (character, code) in [(Character("a"), 0), (Character("d"), 2), (Character("d"), 2), (Character(" "), 49)] {
            _ = coordinator.handle(.keyDown(character, code), flags: [], original: keyEvent(code, down: true))
        }
        XCTAssertEqual(injector.deletions, [3])
        XCTAssertEqual(injector.insertions.first?.0, "address")
    }

    func testATriggerCanExpandTwiceInARow() {
        let (coordinator, injector, _) = subject([combo("addr", parts: [textPart("123 Main St")])])
        for round in 0..<2 {
            for (character, code) in [(Character("a"), 0), (Character("d"), 2),
                                      (Character("d"), 2), (Character("r"), 15),
                                      (Character(" "), 49)] {
                _ = coordinator.handle(.keyDown(character, code), flags: [],
                                       original: keyEvent(code, down: true))
            }
            XCTAssertEqual(injector.deletions.count, round + 1,
                           "round \(round + 1) must expand; a boundary left closed by round 1 makes round 2 silently stop working")
        }
        XCTAssertEqual(injector.insertions.count, 2)
    }

    func testACommandShortcutDoesNotPoisonTheBoundary() {
        let (coordinator, injector, _) = subject([combo("addr", parts: [textPart("123 Main St")])])

        // Select-all is ⌘A -- a keyDown carrying the character "a" with Command held. It renders no
        // text, so it must not become the "last character typed". Doing so closed the word boundary
        // and made the next trigger unmatchable, which is what the user hit after select-all/undo.
        _ = coordinator.handle(.keyDown("a", 0), flags: .maskCommand, original: keyEvent(0, down: true))

        for (character, code) in [(Character("a"), 0), (Character("d"), 2),
                                  (Character("d"), 2), (Character("r"), 15),
                                  (Character(" "), 49)] {
            _ = coordinator.handle(.keyDown(character, code), flags: [],
                                   original: keyEvent(code, down: true))
        }

        XCTAssertEqual(injector.deletions.count, 1, "a shortcut before the trigger must not block it")
        XCTAssertEqual(injector.insertions.first?.0, "123 Main St")
    }

    func testComposedTextJoinsLiteralParts() {
        let signature = combo("sig", parts: [textPart("Best, "), textPart("Robin")])
        let (coordinator, _, _) = subject([signature])
        XCTAssertEqual(coordinator.composedText(for: signature), "Best, Robin")
    }

    func testAttachRefusesWhenUntrusted() {
        let (coordinator, _, _) = subject([combo("addr", parts: [textPart("123 Main St")])], trusted: false)
        XCTAssertFalse(coordinator.attachTap())
        XCTAssertEqual(coordinator.tapRefusalReason, .accessibilityNotTrusted)
    }
}
