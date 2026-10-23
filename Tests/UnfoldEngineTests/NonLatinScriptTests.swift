import XCTest
@testable import UnfoldEngine

/// The spec's test plan (line 199) calls non-Latin layouts "the highest-value test surface in the
/// project", and every fixture written before this suite was ASCII.
///
/// These tables pin what the engine does **today**. Where the outcome is a misfire -- every keystroke
/// reaches the document, but nothing fires -- the row's label says MISFIRE and asserts that actual
/// sequence. No row here demands behaviour the engine does not have.
///
/// The load-bearing facts are that the engine's input unit is Swift's `Character`, which is an
/// extended grapheme cluster, and that `String` and `Character` equality in Swift is
/// canonical-equivalence comparison. Together those make NFC and NFD interchangeable *when a composed
/// cluster arrives as one event*, and dead wrong when an adapter delivers a combining mark on its own.
final class NonLatinScriptTests: XCTestCase {
    // MARK: - Classification

    func testWordCharacterClassificationAcrossScripts() {
        let table: [(label: String, character: Character, isWord: Bool)] = [
            ("U+00BD VULGAR FRACTION ONE HALF is a number", "\u{00BD}", true),
            ("U+2460 CIRCLED DIGIT ONE is a number", "\u{2460}", true),
            ("U+01C6 LATIN SMALL LETTER DZ is a letter", "\u{01C6}", true),
            ("U+00E9 LATIN SMALL LETTER E WITH ACUTE is a letter", "\u{00E9}", true),
            ("U+4F60 CJK ideograph is a letter", "\u{4F60}", true),
            ("U+043F CYRILLIC SMALL LETTER PE is a letter", "\u{043F}", true),
            ("U+0E40 THAI CHARACTER HO HIGHMAI is a letter", "\u{0E40}", true),
            ("U+0E31 THAI CHARACTER MAI HAN AKOT arrives as its own event, and Swift calls it a letter", "\u{0E31}", true),
            ("U+0301 COMBINING ACUTE ACCENT alone is not a word character", "\u{0301}", false),
            ("U+0591 HEBREW ACCENT ETNAHTA alone is not a word character", "\u{0591}", false),
            ("U+200D ZERO WIDTH JOINER alone is not a word character", "\u{200D}", false),
            ("U+1F600 GRINNING FACE is not a word character", "\u{1F600}", false),
            ("U+000D CARRIAGE RETURN is not a word character", "\r", false),
            ("U+000A LINE FEED is not a word character", "\n", false),
            ("CRLF reaches the engine as one delimiter event", "\r\n", false),
            ("an emoji ZWJ sequence reaches the engine as one delimiter event", "\u{1F469}\u{200D}\u{1F4BB}", false),
        ]

        for row in table {
            XCTAssertEqual(isWordCharacter(row.character), row.isWord, row.label)
        }
    }

    // MARK: - Trigger acceptance

    func testIndexAcceptsComposedNonLatinTriggers() {
        // Every character in these triggers is a word character as the engine sees the cluster, so
        // each one is reachable and must be accepted.
        let triggers = [
            "caf\u{00E9}",           // café, NFC
            "cafe\u{0301}",         // café, NFD -- the mark rides inside é's cluster
            "你好",                  // CJK
            "привет",               // Cyrillic
            "\u{0E40}\u{0E31}",     // Thai, one cluster
            "\u{00BD}",             // ½
            "\u{05D0}\u{0591}",     // Hebrew letter with a pointing mark
        ]

        for trigger in triggers {
            let index = TriggerIndex(combos: [makeCombo(trigger)])
            XCTAssertEqual(index.rejections, [], "`\(trigger)` holds only word characters")
            XCTAssertEqual(index.accepted.count, 1, "`\(trigger)` must be reachable")
        }
    }

    func testIndexRejectsNonLatinTriggersTheMatcherCannotReach() {
        let table: [(label: String, trigger: String)] = [
            ("emoji in the middle of a trigger", "x\u{1F600}y"),
            ("a leading Hebrew accent is its own cluster", "\u{0591}\u{05D0}"),
            ("a leading combining mark is its own cluster", "\u{0301}x"),
            ("an en dash is a delimiter, not a trigger character", "e\u{2013}mail"),
        ]

        for row in table {
            let index = TriggerIndex(combos: [makeCombo(row.trigger)])
            XCTAssertEqual(index.rejections.map(\.problem), [.containsNonWordCharacter], row.label)
            XCTAssertTrue(index.accepted.isEmpty, row.label)
        }
    }

    // MARK: - Matching

    private struct KeystrokeRow {
        let label: String
        let trigger: String
        /// The stream as an adapter would deliver it: one entry per keystroke, each a whole cluster.
        let events: [Character]
        let expected: (Combo) -> [MatchAction]
    }

    func testMatcherBehaviourOnNonLatinKeystrokeStreams() {
        let table: [KeystrokeRow] = [
            KeystrokeRow(
                label: "an NFC trigger matches NFD keystrokes, because é arrives as one cluster",
                trigger: "caf\u{00E9}",
                events: Array("cafe\u{0301} "),
                expected: { swallows(4) + [.expand($0), .emit(" ")] }
            ),
            KeystrokeRow(
                label: "the reverse: an NFD trigger matches NFC keystrokes",
                trigger: "cafe\u{0301}",
                events: Array("caf\u{00E9} "),
                expected: { swallows(4) + [.expand($0), .emit(" ")] }
            ),
            KeystrokeRow(
                label: "MISFIRE: a dead-key é delivered as `e` then U+0301 never completes the NFC trigger, and nothing is lost",
                trigger: "caf\u{00E9}",
                events: ["c", "a", "f", "e", "\u{0301}", " "],
                expected: { _ in swallows(3) + emits(["c", "a", "f", "e", "\u{0301}", " "]) }
            ),
            KeystrokeRow(
                label: "MISFIRE: a cluster-valued Thai trigger is unreachable when its two scalars arrive separately, and nothing is lost",
                trigger: "\u{0E40}\u{0E31}",
                events: ["\u{0E40}", "\u{0E31}", " "],
                expected: { _ in emits(["\u{0E40}", "\u{0E31}", " "]) }
            ),
            KeystrokeRow(
                label: "emoji is a delimiter, so it expands the way a space does",
                trigger: "add",
                events: Array("add\u{1F600}"),
                expected: { swallows(3) + [.expand($0), .emit("\u{1F600}")] }
            ),
            KeystrokeRow(
                label: "an emoji ZWJ sequence is a single delimiter event",
                trigger: "add",
                events: Array("add\u{1F469}\u{200D}\u{1F4BB}"),
                expected: { swallows(3) + [.expand($0), .emit("\u{1F469}\u{200D}\u{1F4BB}")] }
            ),
            KeystrokeRow(
                label: "Return is a delimiter",
                trigger: "add",
                events: Array("add\r"),
                expected: { swallows(3) + [.expand($0), .emit("\r")] }
            ),
            KeystrokeRow(
                label: "CJK triggers match CJK keystrokes",
                trigger: "你好",
                events: Array("你好 "),
                expected: { swallows(2) + [.expand($0), .emit(" ")] }
            ),
            KeystrokeRow(
                label: "Cyrillic triggers match Cyrillic keystrokes",
                trigger: "привет",
                events: Array("привет "),
                expected: { swallows(6) + [.expand($0), .emit(" ")] }
            ),
            KeystrokeRow(
                label: "a Thai trigger arrives as one cluster and expands on the delimiter",
                trigger: "\u{0E40}\u{0E31}",
                events: Array("\u{0E40}\u{0E31} "),
                expected: { swallows(1) + [.expand($0), .emit(" ")] }
            ),
            KeystrokeRow(
                label: "U+00BD is a word character, so it can be a trigger and cannot be a delimiter",
                trigger: "\u{00BD}",
                events: Array("\u{00BD} "),
                expected: { swallows(1) + [.expand($0), .emit(" ")] }
            ),
            KeystrokeRow(
                label: "a circled digit and the small-dz ligature survive as trigger characters",
                trigger: "\u{2460}\u{01C6}",
                events: Array("\u{2460}\u{01C6} "),
                expected: { swallows(2) + [.expand($0), .emit(" ")] }
            ),
            KeystrokeRow(
                label: "rule 6 with a composed accent: `caféx` never fires the `café` trigger",
                trigger: "caf\u{00E9}",
                events: Array("caféx "),
                expected: { _ in swallows(4) + emits(Array("caféx ")) }
            ),
        ]

        for row in table {
            let combo = makeCombo(row.trigger)
            let index = TriggerIndex(combos: [combo])
            XCTAssertEqual(index.rejections, [], "\(row.label): the trigger must be reachable first")

            var matcher = Matcher(index: index)
            var actions: [MatchAction] = []
            for event in row.events {
                actions.append(contentsOf: matcher.feed(event))
            }

            XCTAssertEqual(actions, row.expected(combo), row.label)
            XCTAssertEqual(matcher.buffer, "", row.label)

            let expansions = actions.filter { if case .expand = $0 { return true } else { return false } }
            if expansions.isEmpty {
                // Nothing fired, so every keystroke must have reached the document verbatim.
                XCTAssertEqual(
                    emittedCharacters(in: actions),
                    row.events,
                    "\(row.label): no keystroke may be dropped"
                )
            } else {
                XCTAssertEqual(expansions.count, 1, row.label)
                // The trigger's own characters are the only ones the document never sees.
                XCTAssertEqual(
                    emittedCharacters(in: actions).count,
                    row.events.count - Array(combo.trigger).count,
                    row.label
                )
            }
        }
    }

    /// The keystrokes that reached the document.
    private func emittedCharacters(in actions: [MatchAction]) -> [Character] {
        actions.compactMap { if case .emit(let character) = $0 { return character } else { return nil } }
    }
}

/// File-scope so the table's expectation closures use them without capturing `self`.
private func swallows(_ count: Int) -> [MatchAction] {
    Array(repeating: .swallow, count: count)
}

private func emits(_ characters: [Character]) -> [MatchAction] {
    characters.map { MatchAction.emit($0) }
}
