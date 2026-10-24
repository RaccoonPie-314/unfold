import CoreGraphics
import UnfoldEngine
import XCTest
@testable import UnfoldMac

private final class FakeInjector: TextInjecting {
    var insertions: [(String, InsertionMode)] = []
    var deletions: [Int] = []
    var literals: [String] = []

    func insert(_ text: String, mode: InsertionMode) { insertions.append((text, mode)) }
    func deleteBackward(_ count: Int) { deletions.append(count) }
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
