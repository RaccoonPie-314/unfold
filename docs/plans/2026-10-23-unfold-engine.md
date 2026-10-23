# Unfold Pure Engine Implementation Plan

**Goal:** Build and fully test Unfold's permission-free engine -- template parsing, trigger indexing, the keystroke matching state machine, and JSON storage -- plus a command-line demonstrator that proves the matcher behaves.

**Architecture:** Four small pure types in one SwiftPM library target. `Template` turns `{{name:opts}}` text into `[Part]` and back. `TriggerIndex` validates triggers and precomputes every prefix so lookups are O(1). `Matcher` consumes one decoded character at a time and returns `[MatchAction]` telling the caller to swallow, re-emit, or expand. `Store` reads and writes `combos.json` atomically. Nothing in this target imports AppKit, so every test runs without accessibility permissions.

**Tech Stack:** Swift 6.4 toolchain, SwiftPM, XCTest, Foundation only.

**Spec:** `docs/specs/2026-10-23-macos-text-expander-design.md` -- read it alongside this plan. The Matching and Storage sections were amended on 2026-10-23 while writing this plan; the amendments are already reflected there and here.

## Global Constraints

- Swift tools version `6.0`, `swiftLanguageModes: [.v5]`. Do not raise either; CGEventTap callbacks in a later plan need language mode 5.
- Minimum platform `.macOS(.v14)`.
- `UnfoldEngine` imports **Foundation only**. Never AppKit, UIKit, Carbon, or ApplicationServices in this target. That rule is what keeps the tests permission-free.
- No third-party dependencies.
- Bundle identifier `io.github.raccoonpie314.unfold`. Store path `~/Library/Application Support/io.github.raccoonpie314.unfold/combos.json`.
- Matching fires at a delimiter, never inside a word. Word character = `character.isLetter || character.isNumber`.
- A `Placeholder` carries exactly `id` and `options`.
- Triggers must be non-empty, contain no whitespace, and end in a word character; duplicates keep the first.
- Commit messages are plain imperative sentences, no `feat:` prefixes -- that is this repo's style. Commit locally after each task; **never `git push`**, the user drives the remote.
- Run a single suite with `swift test --filter <SuiteName>` from the project root. The project path contains a space, so always quote it in `cd`.

## File Structure

| File | Responsibility |
|---|---|
| `Sources/UnfoldEngine/Models.swift` | `Combo`, `Part`, `Placeholder`, `CombosFile` -- plain Codable data, no behavior. Modified in Task 1. |
| `Sources/UnfoldEngine/Template.swift` | `[Part]` ⇄ plain-text form. Escaping. Placeholder validation. |
| `Sources/UnfoldEngine/MatchAction.swift` | `MatchAction` and the shared `isWordCharacter` definition. |
| `Sources/UnfoldEngine/TriggerIndex.swift` | Trigger validation, duplicate policy, prefix/exact lookup tables. |
| `Sources/UnfoldEngine/Matcher.swift` | The character-at-a-time state machine. |
| `Sources/UnfoldEngine/Store.swift` | `combos.json` load and atomic save, format-version guard. |
| `Sources/UnfoldCTL/main.swift` | `check` and `match` commands that exercise the engine from a terminal. |
| `Package.swift` | Adds the `UnfoldCTL` executable target in Task 6. |

Each test file mirrors its source file: `TemplateTests.swift`, `TriggerIndexTests.swift`, `MatcherTests.swift`, `StoreTests.swift`, all in `Tests/UnfoldEngineTests/`.

Two shared test helpers live in `Tests/UnfoldEngineTests/TestSupport.swift`, created in Task 2 -- build them once there rather than re-declaring per suite.

## Deferred to later plans

Deliberately absent here, each its own plan: the `CGEventTap` capture adapter and `Injector` (Plan 2), the status item and combo editor UI (Plan 3), the combobox prompt panel and cancel semantics (Plan 4), Developer ID signing, notarization and Sparkle (Plan 5). This plan ends with a tested engine and a CLI that demonstrates it -- no GUI, no permissions.

---

### Task 1: Trim the placeholder model and add the template parser

**Files:**
- Modify: `Sources/UnfoldEngine/Models.swift` (the `Placeholder` struct, lines 9-21)
- Modify: `Tests/UnfoldEngineTests/CombosFileTests.swift` (its `Placeholder` construction)
- Create: `Sources/UnfoldEngine/Template.swift`
- Create: `Tests/UnfoldEngineTests/TemplateTests.swift`

**Interfaces:**
- Consumes: `Part`, `Placeholder` from `Models.swift`.
- Produces: `Template.parse(_ text: String) throws -> [Part]`, `Template.serialize(_ parts: [Part]) -> String`, `TemplateError` with cases `unclosedPlaceholder(String)`, `emptyPlaceholderName`, `invalidPlaceholderName(String)`, `duplicatePlaceholderName(String)`. Task 3 uses `Template.serialize` for human-readable output; Plan 3 uses it for the editor's plain-text mode.
- After this task `Placeholder` is `Placeholder(id: String, options: [String])`.

- [ ] **Step 1: Trim `Placeholder` and repair the existing test**

In `Sources/UnfoldEngine/Models.swift`, replace the whole `Placeholder` struct with:

```swift
public struct Placeholder: Codable, Equatable, Sendable {
    public var id: String
    public var options: [String]

    public init(id: String, options: [String]) {
        self.id = id
        self.options = options
    }
}
```

In `Tests/UnfoldEngineTests/CombosFileTests.swift`, replace the `.placeholder(.init(...))` argument with the two-field form:

```swift
                        .placeholder(.init(
                            id: "city",
                            options: ["Shanghai", "Tokyo"]
                        )),
```

- [ ] **Step 2: Run the existing test to verify it still passes**

Run: `swift test --filter CombosFileTests`
Expected: PASS. The model change is behavior-neutral, so this must stay green before anything new is written.

- [ ] **Step 3: Write the failing template tests**

Create `Tests/UnfoldEngineTests/TemplateTests.swift`:

```swift
import XCTest
@testable import UnfoldEngine

final class TemplateTests: XCTestCase {
    func testPlainTextBecomesOneTextPart() throws {
        XCTAssertEqual(try Template.parse("See you soon"), [.text("See you soon")])
    }

    func testPlaceholderWithoutOptions() throws {
        XCTAssertEqual(
            try Template.parse("Hi {{name}},"),
            [.text("Hi "), .placeholder(.init(id: "name", options: [])), .text(",")]
        )
    }

    func testPlaceholderWithColonSeparatedOptions() throws {
        XCTAssertEqual(
            try Template.parse("I love {{city:Shanghai,Tokyo}} restaurant"),
            [
                .text("I love "),
                .placeholder(.init(id: "city", options: ["Shanghai", "Tokyo"])),
                .text(" restaurant"),
            ]
        )
    }

    func testAdjacentPlaceholdersProduceNoEmptyTextPart() throws {
        XCTAssertEqual(
            try Template.parse("{{a}}{{b}}"),
            [.placeholder(.init(id: "a", options: [])), .placeholder(.init(id: "b", options: []))]
        )
    }

    func testEscapedBracesStayLiteralText() throws {
        XCTAssertEqual(
            try Template.parse(#"\{{a}} and {{b}}"#),
            [.text("{{a}} and "), .placeholder(.init(id: "b", options: []))]
        )
    }

    func testUnclosedPlaceholderThrows() {
        XCTAssertThrowsError(try Template.parse("Hello {{name")) { error in
            XCTAssertEqual(error as? TemplateError, .unclosedPlaceholder("name"))
        }
    }

    func testEmptyPlaceholderNameThrows() {
        XCTAssertThrowsError(try Template.parse("a {{}} b")) { error in
            XCTAssertEqual(error as? TemplateError, .emptyPlaceholderName)
        }
    }

    func testDuplicatePlaceholderNameThrows() {
        XCTAssertThrowsError(try Template.parse("{{x}} then {{x}}")) { error in
            XCTAssertEqual(error as? TemplateError, .duplicatePlaceholderName("x"))
        }
    }

    func testSerializeRoundTripsUnchanged() throws {
        let source = "I love {{city:Shanghai,Tokyo}} restaurant"
        XCTAssertEqual(try Template.serialize(Template.parse(source)), source)
    }

    func testSerializeEscapesLiteralBraces() throws {
        let parts: [Part] = [.text("use {{braces}} here")]
        XCTAssertEqual(Template.serialize(parts), #"use \{{braces}} here"#)
    }

    func testPlaceholderNameWithBracesIsRejected() {
        XCTAssertThrowsError(try Template.parse("a {{x{y}} b")) { error in
            XCTAssertEqual(error as? TemplateError, .invalidPlaceholderName("x{y"))
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they fail**

Run: `swift test --filter TemplateTests`
Expected: BUILD FAIL -- `cannot find 'Template' in scope`. That is the red state; do not proceed until you have seen it.

- [ ] **Step 5: Write the template parser**

Create `Sources/UnfoldEngine/Template.swift`:

```swift
import Foundation

public enum TemplateError: Error, Equatable, CustomStringConvertible {
    case unclosedPlaceholder(String)
    case emptyPlaceholderName
    case invalidPlaceholderName(String)
    case duplicatePlaceholderName(String)

    public var description: String {
        switch self {
        case .unclosedPlaceholder(let body):
            return "placeholder `{{\(body)` has no closing `}}`"
        case .emptyPlaceholderName:
            return "placeholder name is empty"
        case .invalidPlaceholderName(let name):
            return "placeholder name `\(name)` may not contain braces or a colon"
        case .duplicatePlaceholderName(let name):
            return "placeholder name `\(name)` is used more than once in this combo"
        }
    }
}

public enum Template {
    public static func parse(_ text: String) throws -> [Part] {
        let characters = Array(text)
        var parts: [Part] = []
        var literal = ""
        var seenNames = Set<String>()
        var index = 0

        func flushLiteral() {
            if !literal.isEmpty {
                parts.append(.text(literal))
                literal = ""
            }
        }

        while index < characters.count {
            if characters[index] == "\\",
               index + 2 < characters.count,
               characters[index + 1] == "{",
               characters[index + 2] == "{" {
                literal += "{{"
                index += 3
                continue
            }

            if characters[index] == "{", index + 1 < characters.count, characters[index + 1] == "{" {
                var close = index + 2
                while close < characters.count {
                    if characters[close] == "}", characters[close - 1] == "}" { break }
                    close += 1
                }
                guard close < characters.count else {
                    throw TemplateError.unclosedPlaceholder(String(characters[(index + 2)...]))
                }

                let body = String(characters[(index + 2)..<(close - 1)])
                flushLiteral()
                let placeholder = try makePlaceholder(body)
                if !seenNames.insert(placeholder.id).inserted {
                    throw TemplateError.duplicatePlaceholderName(placeholder.id)
                }
                parts.append(.placeholder(placeholder))
                index = close + 1
                continue
            }

            literal.append(characters[index])
            index += 1
        }

        flushLiteral()
        return parts
    }

    public static func serialize(_ parts: [Part]) -> String {
        var output = ""
        for part in parts {
            switch part {
            case .text(let value):
                output += value.replacingOccurrences(of: "{{", with: "\\{{")
            case .placeholder(let placeholder):
                if placeholder.options.isEmpty {
                    output += "{{\(placeholder.id)}}"
                } else {
                    output += "{{\(placeholder.id):\(placeholder.options.joined(separator: ","))}}"
                }
            }
        }
        return output
    }

    private static func makePlaceholder(_ body: String) throws -> Placeholder {
        let trimmed = body.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { throw TemplateError.emptyPlaceholderName }

        guard let colon = trimmed.firstIndex(of: ":") else {
            try validateName(trimmed)
            return Placeholder(id: trimmed, options: [])
        }

        let name = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
        if name.isEmpty { throw TemplateError.emptyPlaceholderName }
        try validateName(name)

        // An option may not contain a comma: the separator and the value share a
        // character set, so this is a documented v1 limit, not an oversight.
        let rawOptions = String(trimmed[trimmed.index(after: colon)...])
        let options = rawOptions
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        return Placeholder(id: name, options: options)
    }

    private static func validateName(_ name: String) throws {
        if name.contains(where: { $0 == "{" || $0 == "}" || $0 == ":" }) {
            throw TemplateError.invalidPlaceholderName(name)
        }
    }
}
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `swift test --filter TemplateTests`
Expected: PASS, 11 tests, 0 failures.

- [ ] **Step 7: Run the whole suite to verify nothing regressed**

Run: `swift test`
Expected: PASS. `CombosFileTests` and `TemplateTests` both green.

- [ ] **Step 8: Commit**

```bash
cd "$REPO_ROOT"
git add Sources/UnfoldEngine/Models.swift Sources/UnfoldEngine/Template.swift Tests/UnfoldEngineTests/CombosFileTests.swift Tests/UnfoldEngineTests/TemplateTests.swift
git commit -m "Add template parser and trim placeholder to id plus options"
```

---

### Task 2: Trigger validation and prefix lookup

**Files:**
- Create: `Sources/UnfoldEngine/MatchAction.swift`
- Create: `Sources/UnfoldEngine/TriggerIndex.swift`
- Create: `Tests/UnfoldEngineTests/TestSupport.swift`
- Create: `Tests/UnfoldEngineTests/TriggerIndexTests.swift`

**Interfaces:**
- Consumes: `Combo`, `InsertionMode`, `Part` from `Models.swift`.
- Produces:
  - `func isWordCharacter(_ character: Character) -> Bool` -- internal, used by `Matcher` in Task 3.
  - `enum MatchAction { case emit(Character), swallow, expand(Combo) }` -- the engine's output vocabulary, consumed by Task 3 and by the Plan 2 adapter.
  - `struct TriggerIndex` with `init(combos: [Combo])`, `func combo(for buffer: String) -> Combo?`, `func isPrefix(_ candidate: String) -> Bool`, `var accepted: [Combo]`, `var rejections: [TriggerIndex.Rejection]`.
  - `TriggerIndex.Problem` cases `empty`, `containsWhitespace`, `mustEndWithWordCharacter`, `duplicateTrigger`.
  - Test helper `func makeCombo(_ trigger: String, replacement: String, enabled: Bool) -> Combo` in `TestSupport.swift`, used by Tasks 2, 3, 4, and 5.

- [ ] **Step 1: Write the action vocabulary**

Create `Sources/UnfoldEngine/MatchAction.swift`:

```swift
import Foundation

public enum MatchAction: Equatable {
    /// Send this character to the target app verbatim.
    case emit(Character)
    /// Suppress the keystroke event; it belongs to a possible trigger.
    case swallow
    /// The buffer completed a trigger: insert it and stop suppressing.
    case expand(Combo)
}

func isWordCharacter(_ character: Character) -> Bool {
    character.isLetter || character.isNumber
}
```

- [ ] **Step 2: Write the failing index tests**

Create `Tests/UnfoldEngineTests/TriggerIndexTests.swift`:

```swift
import XCTest
@testable import UnfoldEngine

final class TriggerIndexTests: XCTestCase {
    func testRegistersEveryPrefixIncludingTheWholeTrigger() {
        let index = TriggerIndex(combos: [makeCombo("addr")])
        for candidate in ["a", "ad", "add", "addr"] {
            XCTAssertTrue(index.isPrefix(candidate), "`\(candidate)` should be a live prefix")
        }
        XCTAssertFalse(index.isPrefix("addrs"))
        XCTAssertFalse(index.isPrefix(""))
    }

    func testEmptyTriggerIsRejected() {
        let index = TriggerIndex(combos: [makeCombo("")])
        XCTAssertEqual(index.rejections.map(\.problem), [.empty])
        XCTAssertTrue(index.accepted.isEmpty)
    }

    func testWhitespaceTriggerIsRejected() {
        let index = TriggerIndex(combos: [makeCombo("my trigger")])
        XCTAssertEqual(index.rejections.map(\.problem), [.containsWhitespace])
    }

    func testTriggerMustEndWithAWordCharacter() {
        let index = TriggerIndex(combos: [makeCombo("add.")])
        XCTAssertEqual(index.rejections.map(\.problem), [.mustEndWithWordCharacter])
    }

    func testDuplicateTriggerKeepsFirstOccurrence() {
        let first = makeCombo("add", replacement: "one")
        let second = makeCombo("add", replacement: "two")
        let index = TriggerIndex(combos: [first, second])

        XCTAssertEqual(index.accepted, [first])
        XCTAssertEqual(index.rejections.map(\.problem), [.duplicateTrigger])
        XCTAssertEqual(index.combo(for: "add"), first)
    }

    func testDisabledComboIsUnreachableAndCannotStartAMatch() {
        let off = makeCombo("add", enabled: false)
        let index = TriggerIndex(combos: [off])

        XCTAssertTrue(index.accepted.isEmpty)
        XCTAssertNil(index.combo(for: "add"))
        XCTAssertFalse(index.isPrefix("add"))
    }

    func testValidTriggersAreAcceptedInOrder() {
        let index = TriggerIndex(combos: [makeCombo("ad"), makeCombo("add"), makeCombo("addr")])
        XCTAssertEqual(index.accepted.count, 3)
        XCTAssertNotNil(index.combo(for: "ad"))
        XCTAssertNotNil(index.combo(for: "addr"))
    }
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `swift test --filter TriggerIndexTests`
Expected: BUILD FAIL -- `cannot find 'TriggerIndex' in scope` and `cannot find 'makeCombo' in scope`.

- [ ] **Step 4: Write the shared test helpers**

Create `Tests/UnfoldEngineTests/TestSupport.swift`:

```swift
import Foundation
@testable import UnfoldEngine

func makeCombo(
    _ trigger: String,
    replacement: String = "x",
    enabled: Bool = true
) -> Combo {
    Combo(
        id: UUID(),
        trigger: trigger,
        label: trigger,
        enabled: enabled,
        parts: [.text(replacement)],
        insertion: .paste
    )
}
```

- [ ] **Step 5: Write the trigger index**

Create `Sources/UnfoldEngine/TriggerIndex.swift`:

```swift
import Foundation

public struct TriggerIndex {
    public enum Problem: String, Equatable, CustomStringConvertible {
        case empty
        case containsWhitespace
        case mustEndWithWordCharacter
        case duplicateTrigger

        public var description: String {
            switch self {
            case .empty: return "trigger is empty"
            case .containsWhitespace: return "trigger contains whitespace"
            case .mustEndWithWordCharacter: return "trigger must end with a letter or digit"
            case .duplicateTrigger: return "another enabled combo already uses this trigger"
            }
        }
    }

    public struct Rejection: Equatable {
        public let combo: Combo
        public let problem: Problem
    }

    public private(set) var accepted: [Combo] = []
    public private(set) var rejections: [Rejection] = []

    private var exact: [String: Combo] = [:]
    private var prefixes: Set<String> = []

    public init(combos: [Combo]) {
        for combo in combos where combo.enabled {
            if let problem = TriggerIndex.problem(in: combo.trigger) {
                rejections.append(Rejection(combo: combo, problem: problem))
                continue
            }
            if exact[combo.trigger] != nil {
                rejections.append(Rejection(combo: combo, problem: .duplicateTrigger))
                continue
            }

            accepted.append(combo)
            exact[combo.trigger] = combo

            var consumed: [Character] = []
            for character in combo.trigger {
                consumed.append(character)
                prefixes.insert(String(consumed))
            }
        }
    }

    public func combo(for buffer: String) -> Combo? {
        exact[buffer]
    }

    public func isPrefix(_ candidate: String) -> Bool {
        !candidate.isEmpty && prefixes.contains(candidate)
    }

    private static func problem(in trigger: String) -> Problem? {
        if trigger.isEmpty { return .empty }
        if trigger.contains(where: { $0.isWhitespace }) { return .containsWhitespace }
        guard let last = trigger.last, isWordCharacter(last) else { return .mustEndWithWordCharacter }
        return nil
    }
}
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `swift test --filter TriggerIndexTests`
Expected: PASS, 7 tests, 0 failures. Fix the one malformed method name from Step 2 if you copied it verbatim.

- [ ] **Step 7: Commit**

```bash
cd "$REPO_ROOT"
git add Sources/UnfoldEngine/MatchAction.swift Sources/UnfoldEngine/TriggerIndex.swift Tests/UnfoldEngineTests/TriggerIndexTests.swift Tests/UnfoldEngineTests/TestSupport.swift
git commit -m "Add trigger validation and prefix lookup for matching"
```

---

### Task 3: The matcher state machine

**Files:**
- Create: `Sources/UnfoldEngine/Matcher.swift`
- Create: `Tests/UnfoldEngineTests/MatcherTests.swift`

**Interfaces:**
- Consumes: `TriggerIndex` (Task 2), `MatchAction` and `isWordCharacter` (Task 2), `Combo` (Task 1).
- Produces: `Matcher` with `init(index: TriggerIndex)`, `mutating func feed(_ character: Character) -> [MatchAction]`, `var buffer: String { get }`, `mutating func reset()`. Task 4 adds `releasePending()` to this type; Task 6 and Plan 2 consume it unchanged.

- [ ] **Step 1: Write the failing matcher tests**

Create `Tests/UnfoldEngineTests/MatcherTests.swift`:

```swift
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

    func testExpansionReopensTheBoundaryForTheNextTrigger() {
        let add = makeCombo("add", replacement: "address")
        var matcher = Matcher(index: TriggerIndex(combos: [add]))

        _ = matcher.feed("x")
        _ = matcher.feed(" ")
        XCTAssertEqual(matcher.feed("a"), [.swallow])
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

private func collect(_ text: String, from matcher: Matcher) -> [MatchAction] {
    var running = matcher
    var actions: [MatchAction] = []
    for character in text {
        actions.append(contentsOf: running.feed(character))
    }
    return actions
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter MatcherTests`
Expected: BUILD FAIL -- `cannot find 'Matcher' in scope`.

- [ ] **Step 3: Write the matcher**

Create `Sources/UnfoldEngine/Matcher.swift`:

```swift
import Foundation

public struct Matcher {
    private let index: TriggerIndex
    public private(set) var buffer: String = ""

    /// The last character known to have reached the target document. `nil` means
    /// nothing has been typed yet, which counts as a word boundary.
    private var lastEmitted: Character?

    public init(index: TriggerIndex) {
        self.index = index
    }

    public mutating func feed(_ character: Character) -> [MatchAction] {
        if isWordCharacter(character) {
            return feedWord(character)
        }
        return feedDelimiter(character)
    }

    public mutating func reset() {
        buffer = ""
        lastEmitted = nil
    }

    private var atBoundary: Bool {
        guard let lastEmitted else { return true }
        return !isWordCharacter(lastEmitted)
    }

    private mutating func feedWord(_ character: Character) -> [MatchAction] {
        let candidate = buffer + String(character)

        if buffer.isEmpty {
            guard atBoundary, index.isPrefix(candidate) else {
                lastEmitted = character
                return [.emit(character)]
            }
            buffer = candidate
            return [.swallow]
        }

        if index.isPrefix(candidate) {
            buffer = candidate
            return [.swallow]
        }

        return releaseBufferThenReconsider(character)
    }

    private mutating func feedDelimiter(_ character: Character) -> [MatchAction] {
        if let combo = index.combo(for: buffer) {
            buffer = ""
            lastEmitted = character
            return [.expand(combo), .emit(character)]
        }

        if buffer.isEmpty {
            lastEmitted = character
            return [.emit(character)]
        }

        return releaseBufferThenReconsider(character)
    }

    /// Emits the swallowed characters verbatim so nothing is lost, then decides the
    /// current character from an empty buffer. Because the released buffer ended in a
    /// word character, the boundary check makes `added` emit rather than expand.
    private mutating func releaseBufferThenReconsider(_ character: Character) -> [MatchAction] {
        let pending = buffer
        buffer = ""
        var actions = pending.map { MatchAction.emit($0) }
        if let last = pending.last { lastEmitted = last }
        actions.append(contentsOf: feed(character))
        return actions
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter MatcherTests`
Expected: PASS, 8 tests, 0 failures. `testLongerTriggerWinsWhenTypedInFull` and `testMatchCannotStartInTheMiddleOfAWord` are the two that catch real regressions -- if either fails, the bug is in `releaseBufferThenReconsider`, not in the tests.

- [ ] **Step 5: Run the whole suite**

Run: `swift test`
Expected: PASS across all four suites.

- [ ] **Step 6: Commit**

```bash
cd "$REPO_ROOT"
git add Sources/UnfoldEngine/Matcher.swift Tests/UnfoldEngineTests/MatcherTests.swift
git commit -m "Add delimiter-triggered matcher that never fires inside a word"
```

---

### Task 4: Never lose a keystroke

**Files:**
- Modify: `Sources/UnfoldEngine/Matcher.swift` (add one method, plus the `buffer` doc comment)
- Modify: `Tests/UnfoldEngineTests/MatcherTests.swift` (append cases to the existing class)

**Interfaces:**
- Consumes: `Matcher` (Task 3), `TriggerIndex` (Task 2).
- Produces: `mutating func releasePending() -> [MatchAction]`. Plan 2's adapter calls this from an idle timer and whenever the user switches apps, so a partial prefix can never sit swallowed forever.

- [ ] **Step 1: Write the failing tests for lost keystrokes**

Append these cases inside `final class MatcherTests` in `Tests/UnfoldEngineTests/MatcherTests.swift`:

```swift
    func testPartialPrefixReleasedOnDelimiter() {
        let actions = collect("add ", from: Matcher(index: TriggerIndex(combos: [makeCombo("address")])))

        XCTAssertEqual(actions, "add ".map { MatchAction.emit(Character($0)) })
    }

    func testTypingAddedNeverFiresTheAddTrigger() {
        let actions = collect("added ", from: Matcher(index: TriggerIndex(combos: [makeCombo("add", replacement: "address")])))

        XCTAssertEqual(actions, "added ".map { MatchAction.emit(Character($0)) })
    }

    func testIdleReleaseEmitsBufferedCharacters() {
        var matcher = Matcher(index: TriggerIndex(combos: [makeCombo("addr")]))
        _ = matcher.feed("a")
        _ = matcher.feed("d")
        XCTAssertEqual(matcher.buffer, "ad")

        XCTAssertEqual(matcher.releasePending(), [.emit("a"), .emit("d")])
        XCTAssertEqual(matcher.buffer, "")
    }

    func testIdleReleaseLeavesTheMatcherReadyForAFreshTrigger() {
        let add = makeCombo("add")
        var matcher = Matcher(index: TriggerIndex(combos: [add]))
        _ = matcher.feed("a")
        _ = matcher.releasePending()

        XCTAssertEqual(matcher.feed("a"), [.swallow])
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
```

Because `Combo` synthesizes `Equatable` across all its fields including `id`, every test that asserts `.expand(someCombo)` must reuse the *same instance* that was handed to `TriggerIndex` -- that is why each test binds a local `let add = makeCombo(...)` instead of calling `makeCombo` again inside the assertion.

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter MatcherTests`
Expected: BUILD FAIL -- `value of type 'Matcher' has no member 'releasePending'`.

- [ ] **Step 3: Implement the idle release**

Add this method to `Sources/UnfoldEngine/Matcher.swift`, immediately after `reset()`:

```swift
    /// Emits whatever is buffered without expanding. The adapter calls this when typing
    /// goes idle, when focus changes, and when the user pauses expansion, so a swallowed
    /// prefix can never be lost.
    public mutating func releasePending() -> [MatchAction] {
        let pending = buffer
        buffer = ""
        if let last = pending.last { lastEmitted = last }
        return pending.map { MatchAction.emit($0) }
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter MatcherTests`
Expected: PASS. All thirteen `MatcherTests` cases green, including the two that prove `added` emits rather than expands.

- [ ] **Step 5: Run the whole suite**

Run: `swift test`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
cd "$REPO_ROOT"
git add Sources/UnfoldEngine/Matcher.swift Tests/UnfoldEngineTests/MatcherTests.swift
git commit -m "Add idle buffer release so no swallowed keystroke is ever lost"
```

---

### Task 5: Load and save combos.json

**Files:**
- Create: `Sources/UnfoldEngine/Store.swift`
- Create: `Tests/UnfoldEngineTests/StoreTests.swift`

**Interfaces:**
- Consumes: `CombosFile`, `Combo`, `Part`, `Placeholder` from `Models.swift`.
- Produces: `Store` with `init(url: URL)`, `func load(fileManager:) throws -> CombosFile`, `func save(_ file: CombosFile, fileManager:) throws`, `static func defaultURL(appIdentifier:fileManager:) -> URL`; and `StoreError` with cases `unreadable(String)` and `formatVersionTooNew(found:Int, supported:Int)`. Plan 2 and Plan 3 both reach the file only through `Store`.

- [ ] **Step 1: Write the failing store tests**

Create `Tests/UnfoldEngineTests/StoreTests.swift`:

```swift
import XCTest
@testable import UnfoldEngine

final class StoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("unfold-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func store(in subpath: String? = nil) -> Store {
        let url = subpath.map { directory.appendingPathComponent($0) } ?? directory.appendingPathComponent("combos.json")
        return Store(url: url)
    }

    func testMissingFileLoadsAsAnEmptyLibrary() throws {
        let loaded = try store().load()
        XCTAssertEqual(loaded, CombosFile(formatVersion: CombosFile.currentFormatVersion, combos: []))
    }

    func testSaveThenLoadRoundTrips() throws {
        let file = CombosFile(
            formatVersion: CombosFile.currentFormatVersion,
            combos: [
                Combo(
                    id: UUID(uuidString: "6C9C0A1E-2D2B-4E37-9A6B-5C1F0D8E3A11")!,
                    trigger: "addr",
                    label: "Home address",
                    enabled: true,
                    parts: [
                        .text("I love "),
                        .placeholder(.init(id: "city", options: ["Shanghai", "Tokyo"])),
                        .text(" restaurant"),
                    ],
                    insertion: .paste
                )
            ]
        )

        try store().save(file)
        XCTAssertEqual(try store().load(), file)
    }

    func testSavedFileIsPrettyPrintedSoUsersCanDiffIt() throws {
        try store().save(CombosFile(formatVersion: 1, combos: [makeCombo("add")]))
        let text = try String(contentsOf: directory.appendingPathComponent("combos.json"), encoding: .utf8)

        XCTAssertTrue(text.contains("\n"), "a single-line file is not diffable")
        XCTAssertTrue(text.contains("\"trigger\""))
    }

    func testSaveCreatesTheApplicationSupportSubdirectory() throws {
        let nested = store(in: "Unfold/combos.json")
        try nested.save(CombosFile(formatVersion: 1, combos: []))

        XCTAssertTrue(FileManager.default.fileExists(atPath: nested.url.path))
    }

    func testCorruptFileThrowsWithoutDeletingIt() throws {
        let url = directory.appendingPathComponent("combos.json")
        try Data("this is not json".utf8).write(to: url)

        XCTAssertThrowsError(try store().load()) { error in
            guard case StoreError.unreadable = error else {
                return XCTFail("expected unreadable, got \(error)")
            }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "the user's file must survive a failed load")
    }

    func testFutureFormatVersionIsRefused() throws {
        try store().save(CombosFile(formatVersion: 99, combos: []))

        XCTAssertThrowsError(try store().load()) { error in
            XCTAssertEqual(
                error as? StoreError,
                .formatVersionTooNew(found: 99, supported: CombosFile.currentFormatVersion)
            )
        }
    }

    func testDefaultURLPointsAtTheDocumentedPath() {
        let url = Store.defaultURL()
        XCTAssertTrue(url.path.hasSuffix("io.github.raccoonpie314.unfold/combos.json"), url.path)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter StoreTests`
Expected: BUILD FAIL -- `cannot find 'Store' in scope`.

- [ ] **Step 3: Write the store**

Create `Sources/UnfoldEngine/Store.swift`:

```swift
import Foundation

public enum StoreError: Error, Equatable, CustomStringConvertible {
    case unreadable(String)
    case formatVersionTooNew(found: Int, supported: Int)

    public var description: String {
        switch self {
        case .unreadable(let reason):
            return "combos file could not be decoded: \(reason)"
        case .formatVersionTooNew(let found, let supported):
            return "combos file declares format \(found) but this build supports \(supported)"
        }
    }
}

public struct Store {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public static func defaultURL(
        appIdentifier: String = "io.github.raccoonpie314.unfold",
        fileManager: FileManager = .default
    ) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base
            .appendingPathComponent(appIdentifier)
            .appendingPathComponent("combos.json")
    }

    /// A missing file is a normal first run, not an error. A file that exists but cannot
    /// be decoded throws, and is never overwritten from here.
    public func load(fileManager: FileManager = .default) throws -> CombosFile {
        guard fileManager.fileExists(atPath: url.path) else {
            return CombosFile(formatVersion: CombosFile.currentFormatVersion, combos: [])
        }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw StoreError.unreadable(error.localizedDescription)
        }

        let decoded: CombosFile
        do {
            decoded = try JSONDecoder().decode(CombosFile.self, from: data)
        } catch {
            throw StoreError.unreadable(String(describing: error))
        }

        guard decoded.formatVersion <= CombosFile.currentFormatVersion else {
            throw StoreError.formatVersionTooNew(
                found: decoded.formatVersion,
                supported: CombosFile.currentFormatVersion
            )
        }
        return decoded
    }

    public func save(_ file: CombosFile, fileManager: FileManager = .default) throws {
        let directory = url.deletingLastPathComponent()
        if !fileManager.fileExists(atPath: directory.path) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(file)
        try data.write(to: url, options: .atomic)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter StoreTests`
Expected: PASS, 7 tests, 0 failures.

- [ ] **Step 5: Run the whole suite**

Run: `swift test`
Expected: PASS across `CombosFileTests`, `TemplateTests`, `TriggerIndexTests`, `MatcherTests`, `StoreTests`.

- [ ] **Step 6: Commit**

```bash
cd "$REPO_ROOT"
git add Sources/UnfoldEngine/Store.swift Tests/UnfoldEngineTests/StoreTests.swift
git commit -m "Add atomic JSON store with format version guard"
```

---

### Task 6: Demonstrate the engine from a terminal

**Files:**
- Modify: `Package.swift` (add one target)
- Create: `Sources/UnfoldCTL/main.swift`

**Interfaces:**
- Consumes: `Store`, `TriggerIndex`, `Matcher`, `Template`, `MatchAction`, `CombosFile`.
- Produces: an `unfoldctl` executable with two subcommands, `check` and `match`, both accepting `--combos <path>`. It is the only way to watch the engine work before Plan 2 ships the keyboard adapter, and it becomes the project's regression harness.

- [ ] **Step 1: Add the executable target**

In `Package.swift`, insert this target immediately before `.testTarget`:

```swift
        .executableTarget(
            name: "UnfoldCTL",
            dependencies: ["UnfoldEngine"]
        ),
```

- [ ] **Step 2: Write the tool**

Create `Sources/UnfoldCTL/main.swift`:

```swift
import Foundation
import UnfoldEngine

func expandTilde(_ path: String) -> String {
    if path.hasPrefix("~/") {
        return NSHomeDirectory() + String(path.dropFirst(1))
    }
    return path
}

func combosURL(from arguments: [String]) -> URL {
    if let flag = arguments.firstIndex(of: "--combos"), flag + 1 < arguments.count {
        return URL(fileURLWithPath: expandTilde(arguments[flag + 1]))
    }
    return Store.defaultURL()
}

func describe(_ action: MatchAction, for character: Character) -> String {
    switch action {
    case .emit(let emitted):
        return "  emit    `\(emitted)`"
    case .swallow:
        return "  swallow `\(character)`"
    case .expand(let combo):
        return "  EXPAND  `\(combo.trigger)` -> \(Template.serialize(combo.parts))"
    }
}

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data("unfoldctl: \(message)\n".utf8))
    exit(code)
}

guard CommandLine.arguments.count >= 3 else {
    fail("usage: unfoldctl <check|match> <argument> [--combos <path>]", code: 64)
}

let command = CommandLine.arguments[1]
let argument = CommandLine.arguments[2]
let store = Store(url: combosURL(from: CommandLine.arguments))

let file: CombosFile
do {
    file = try store.load()
} catch {
    fail("cannot read \(store.url.path): \(error)", code: 66)
}

let index = TriggerIndex(combos: file.combos)

switch command {
case "check":
    for rejection in index.rejections {
        print("rejected `\(rejection.combo.trigger)`: \(rejection.problem)")
    }
    print("\(index.accepted.count) trigger(s) active, \(index.rejections.count) rejected")
    if !index.rejections.isEmpty { exit(1) }

case "match":
    var matcher = Matcher(index: index)
    for character in argument {
        for action in matcher.feed(character) {
            print(describe(action, for: character))
        }
    }
    for action in matcher.releasePending() {
        print(describe(action, for: " "))
    }
    print("buffer after input: `\(matcher.buffer)`")

default:
    fail("unknown command `\(command)`; expected check or match", code: 64)
}
```

- [ ] **Step 3: Build it**

Run: `swift build --product UnfoldCTL`
Expected: `Build complete!`

- [ ] **Step 4: Verify `check` against a deliberately broken library**

Create the fixture and run it in one go:

```bash
cd "$REPO_ROOT"
mkdir -p /tmp/unfold-demo
cat > /tmp/unfold-demo/combos.json <<'JSON'
{
  "formatVersion": 1,
  "combos": [
    {
      "id": "6C9C0A1E-2D2B-4E37-9A6B-5C1F0D8E3A11",
      "trigger": "addr",
      "label": "Home address",
      "enabled": true,
      "parts": [
        { "text": "I live at " },
        { "placeholder": { "id": "street", "options": [] } },
        { "text": ", " },
        { "placeholder": { "id": "city", "options": ["Shanghai", "Tokyo"] } }
      ],
      "insertion": "paste"
    },
    {
      "id": "11111111-2222-3333-4444-555555555555",
      "trigger": "my trigger",
      "label": "Bad",
      "enabled": true,
      "parts": [ { "text": "nope" } ],
      "insertion": "paste"
    }
  ]
}
JSON
swift run UnfoldCTL check --combos /tmp/unfold-demo/combos.json; echo "exit code: $?"
```

Expected:

```
rejected `my trigger`: trigger contains whitespace
1 trigger(s) active, 1 rejected
exit code: 1
```

- [ ] **Step 5: Verify `match` reproduces the word-boundary rules**

```bash
cd "$REPO_ROOT"
echo "--- addr<space> should expand ---"
swift run UnfoldCTL match "addr " --combos /tmp/unfold-demo/combos.json
echo "--- added must NOT expand ---"
swift run UnfoldCTL match "added " --combos /tmp/unfold-demo/combos.json
```

Expected for `addr `: four `swallow` lines, then `EXPAND \`addr\` -> I live at {{street}}, {{city:Shanghai,Tokyo}}`, then `emit \` \``.
Expected for `added `: six `emit` lines for `a d d e d` plus the space, and no `EXPAND` anywhere. If `added` expands, stop and fix Task 3's `releaseBufferThenReconsider` -- do not weaken the expectation.

- [ ] **Step 6: Run the whole suite once more**

Run: `swift test`
Expected: PASS. Adding a target must not disturb the engine tests.

- [ ] **Step 7: Commit**

```bash
cd "$REPO_ROOT"
git add Package.swift Sources/UnfoldCTL/main.swift
git commit -m "Add unfoldctl to exercise the matcher from a terminal"
```

---

## Verification

The plan is complete when all of these are true from a clean checkout:

```bash
cd "$REPO_ROOT"
swift build            # Build complete!
swift test             # 0 failures across CombosFile, Template, TriggerIndex, Matcher, Store
grep -rn "AppKit\|UIKit" Sources/UnfoldEngine/ && echo "VIOLATION: engine imports UI frameworks" || echo "engine stays pure"
```

That last line is the architectural invariant of the whole project: `UnfoldEngine` must never import a UI framework, because that is what keeps every test here runnable without granting an accessibility permission.

## Known gaps this plan does not close

- Nothing is wired to the keyboard yet. Unfold does not expand anything outside `unfoldctl` until Plan 2 adds `KeystrokeSource` and `Injector`.
- The combobox prompt UI does not exist; `Placeholder.options` is stored, parsed, and printed, but never prompted.
- `Store.defaultURL()` returns a path but nothing creates it on first run yet -- the app does that in Plan 3.
- `Template.serialize` is lossy for an option containing a comma. The parse side cannot express it either, so the pair is consistent; a snippet needing a comma in an option is a v1 limitation worth documenting in the README later.
