# Unfold Keyboard Layer Implementation Plan (Plan 2)

**Goal:** Make Unfold actually expand text while the user types in any application, by adding the macOS keyboard-capture layer and the paste/type injection layer on top of the finished engine from Plan 1.

**Architecture:** A `CGEventTap` in `.defaultTap` mode feeds decoded characters to the existing pure `Matcher`. The tap callback never contains product logic: it asks a `Decision`-returning router, then executes whatever the router says -- swallow, re-post an event it is holding, or expand. Because macOS will not let Swift capture a tap callback closure, the adapter keeps its own FIFO (`SwallowLedger`) of the exact `CGEvent`s it swallowed, so a released prefix is re-posted as the original key events rather than as synthesized characters. A second library target makes all of that testable without granting an accessibility permission.

**Tech Stack:** Swift 6.4, SwiftPM, XCTest, CoreGraphics, AppKit (`NSStatusItem`, `NSWorkspace`, `NSPasteboard`), Foundation. No third-party dependencies except Sparkle, which is explicitly out of scope here.

**Spec:** `docs/specs/2026-10-23-macos-text-expander-design.md` -- sections "Architecture", "Matching", "Insertion and the placeholder prompt", "Failure modes". Plan 1's spec lives with it; this plan implements the two OS adapters the spec named but did not detail.

**Predecessor:** Plan 1 is complete on branch `task/unfold-engine` -- `docs/plans/2026-10-23-unfold-engine.md`. **R3, R4 and F3** are obligations this plan must discharge, not optional polish.

## Global Constraints

- `UnfoldEngine` continues to import **Foundation only**. Anything touching CoreGraphics or AppKit goes in the new `UnfoldMac` target.
- No third-party dependencies.
- `swiftLanguageModes: [.v5]`, platform floor `.macOS(.v14)`. v5 is load-bearing here: tap callbacks are `@convention(c)` function pointers.
- **The tap must never swallow a keystroke it is not certain about.** Every path that is not an unambiguous trigger continuation passes the event through untouched.
- **Modifier rule:** an event with Command, Control, or Option held is never considered for expansion and immediately releases any buffered prefix. Shift and Caps Lock are allowed, because they change only the character produced.
- **`CGEventFlags` spelling:** use the real member names -- `.maskCommand`, `.maskControl`, `.maskAlternate`, `.maskShift`, `.maskAlphaShift` (Caps Lock). The shorter `.command` / `.shift` / `.capsLock` forms do not exist on this SDK and will not compile; discovered in Task 2 and corrected there, so every later task uses the mask names.
- The app must refuse to create a tap when it is not trusted, and must keep working -- visibly, with an explanation -- when permission is absent or revoked.
- Expansion is limited in this plan to combos whose `parts` are all `.text`. A combo containing a placeholder needs the prompt panel (Plan 4) and is reported as inactive rather than being inserted raw.
- Released prefixes are re-posted as the **original** `CGEvent` objects, oldest first, before the event in hand is passed on.
- Nothing in this plan may `git push`. Pushing is a manual step.
- Commit messages: plain imperative sentences, no `feat:` prefixes.
- The project path contains a space. Quote it in every command.

## Rulings made while planning

The spec is silent on the points below. Each is decided here so that no pass has to guess.

- **R-P2-1 -- decode with `CGEvent.keyboardGetUnicodeString`, not `UCKeyTranslate`.** The system already translated the keystroke through the active layout, including the user's own layout choice, so re-translating risks disagreement with what the target app will receive. Consequence: a dead-key composition (typing `cafe´` to get `é`) yields the dead key as its own character, so a `café` trigger misfires instead of firing. That is Plan 1's residual finding F5 already characterized as a misfire and never a loss. Cost if wrong: accented triggers behave oddly in some layouts; a layout-following tap would have to be re-architected.
- **R-P2-2 -- placeholder combos are registered but inactive in this plan.** Filtering them out of `TriggerIndex` entirely would silently discard user data; inserting `{{city}}` literally would corrupt it. They are excluded from the index and counted, and the status menu prints the count. Cost if wrong: a small refactor when Plan 4 lands.
- **R-P2-3 -- no private API to detect Secure Input.** `CGSIsSecureEventInputEnabled` is private. Instead the coordinator watches for the tap being disabled by the system and for a "trusted, resumed, but receiving nothing" timeout, and reports "not receiving keystrokes" in the menu. Cost if wrong: a password-focused field looks paused when it is merely blocked, which is the honest answer anyway.
- **R-P2-4 -- clipboard restore is delayed and change-count-guarded.** Restoring synchronously after posting Cmd+V races with the target app's read. Save all pasteboard items, write the replacement, post Cmd+V, then restore only if `changeCount` is still ours. Cost if wrong: an app that pastes slowly gets the old clipboard back too early or too late; a race here loses the user's clipboard, which is a data-loss bug and takes priority over tidiness.
- **R-P2-5 -- the tap callback holds no state; the router does.** State lives in an `ExpansionCoordinator` reached through `refcon` as an unmanaged pointer. The callback is `@convention(c)` because Swift cannot pass a capturing closure to CoreGraphics.
- **R-P2-6 -- ad-hoc signing means the accessibility grant does not survive a rebuild.** Accepted for development: the plan's verification task documents re-granting, and stable signing is a Plan 5 concern. Do not "fix" this with a self-signed certificate inside a task; it is a release-engineering decision.

## File Structure

| File | Responsibility |
|---|---|
| `Package.swift` | Adds `UnfoldMac` library, `UnfoldMacTests` test target, and rewires `Unfold` to depend on both. Task 1. |
| `Sources/UnfoldMac/Platform/SwallowLedger.swift` | FIFO of the exact events swallowed, plus the keycodes still awaiting keyup. Pure and generic -- the whole reason the tap logic can be tested. |
| `Sources/UnfoldMac/Platform/ModifierGate.swift` | Decides whether a `CGEventFlags` value is eligible for expansion at all. |
| `Sources/UnfoldMac/Platform/KeyboardDecoder.swift` | `CGEvent` → `Character?` via `keyboardGetUnicodeString`, plus keycode extraction. |
| `Sources/UnfoldMac/Platform/EventRouter.swift` | The decision function: an observed keystroke in, a `RoutingDecision` out. All product logic lives here and nowhere else in the adapter. |
| `Sources/UnfoldMac/Platform/KeystrokeSource.swift` | Owns the tap: create, enable, disable, `@convention(c)` callback, disabled-by-system recovery with a bounded retry count. |
| `Sources/UnfoldMac/Platform/Injector.swift` | Pasteboard save/write/paste/restore, and the synthesized-keystroke fallback. |
| `Sources/UnfoldMac/Platform/ExpansionCoordinator.swift` | Wires engine to adapters: matcher, ledger, injection, idle drain, focus-change teardown, pause. Discharges R3/R4/F3. |
| `Sources/Unfold/AppShell/StatusItemController.swift` | `NSStatusItem` menu: active/paused, counts, inactive-placeholder count, permission state, Quit. |
| `Sources/Unfold/AppShell/PermissionFlow.swift` | Trust check, prompt, polling, deep link to the right System Settings pane. |
| `Sources/Unfold/main.swift` | Becomes the composition root; the current four-line skeleton is replaced. |
| `Tests/UnfoldMacTests/*` | One suite per testable file above. |

`Sources/UnfoldEngine` is **not** modified by this plan except where a task says otherwise. If a task finds it must, that is a signal the boundary moved and the task should stop and flag it.

## Deferred to later plans

Combo editor UI, placeholder prompt, signing/notarization/Sparkle, per-app filters, and the `unfoldctl` additions that make the tap inspectable from CI.

---

### Task 1: Split a testable platform target out of the executable

An executable target's internals cannot be imported by a test target, so every testable adapter in this plan needs a library target. This task also proves the new target really is testable, which is the acceptance criterion.

**Files:**
- Modify: `Package.swift`
- Create: `Sources/UnfoldMac/UnfoldMac.swift` (placeholder that Task 2 replaces)
- Create: `Tests/UnfoldMacTests/TargetWiringTests.swift`

**Interfaces:**
- Consumes: `UnfoldEngine` target.
- Produces: an `UnfoldMac` module usable from both `Unfold` and `UnfoldMacTests`. Task 2 replaces the placeholder file with `SwallowLedger` and `ModifierGate`.

- [ ] **Step 1: Rewrite the manifest**

Replace `Package.swift` with:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Unfold",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "UnfoldEngine"),
        .target(
            name: "UnfoldMac",
            dependencies: ["UnfoldEngine"]
        ),
        .executableTarget(
            name: "Unfold",
            dependencies: ["UnfoldEngine", "UnfoldMac"]
        ),
        .executableTarget(
            name: "UnfoldCTL",
            dependencies: ["UnfoldEngine"]
        ),
        .testTarget(
            name: "UnfoldEngineTests",
            dependencies: ["UnfoldEngine"]
        ),
        .testTarget(
            name: "UnfoldMacTests",
            dependencies: ["UnfoldMac", "UnfoldEngine"]
        ),
    ],
    // Language mode 5 is deliberate: CGEventTap callbacks are C function pointers and
    // would need @convention(c) isolation work under Swift 6 strict concurrency.
    swiftLanguageModes: [.v5]
)
```

- [ ] **Step 2: Create the placeholder so the target builds**

Create `Sources/UnfoldMac/UnfoldMac.swift`:

```swift
import Foundation

enum UnfoldMacModuleMarker {
    static let name = "UnfoldMac"
}
```

- [ ] **Step 3: Write the test that proves the target is reachable**

Create `Tests/UnfoldMacTests/TargetWiringTests.swift`:

```swift
import XCTest
@testable import UnfoldMac

final class TargetWiringTests: XCTestCase {
    func testPlatformTargetIsImportableFromTests() {
        XCTAssertEqual(UnfoldMacModuleMarker.name, "UnfoldMac")
    }
}
```

`@testable import` is the thing being verified: if a test target cannot reach an executable's internals, this structure is the only way the rest of the plan can be tested at all.

- [ ] **Step 4: Delete the placeholder in Task 2, not here**

Run: `swift build && swift test`
Expected: PASS -- 67 existing tests plus `TargetWiringTests`, 68 total. If `UnfoldMac` fails to link into `Unfold`, the manifest edit is wrong, not the code.

- [ ] **Step 5: Prove the purity rule still holds, now across two targets**

Run:
```bash
grep -rn "^import " Sources/UnfoldEngine/ | grep -v "Foundation" && echo "VIOLATION" || echo "engine still Foundation-only"
```
Anchor the pattern to the start of the line. A bare `grep "import"` also matches the words
"importable" and "Beeftext-imported" in comments and reports a false violation -- which is exactly what
happened on the first run of this step.

Expected: `engine still Foundation-only`.

- [ ] **Step 6: Commit**

```bash
cd "$REPO_ROOT"
git add Package.swift Sources/UnfoldMac Tests/UnfoldMacTests
git commit -m "Split platform code into a testable UnfoldMac target"
```

---

### Task 2: Swallow ledger and modifier gate

The two decisions that decide whether a keyboard sink is safe: which events may be eaten, and how eaten ones get handed back.

**Files:**
- Create: `Sources/UnfoldMac/Platform/SwallowLedger.swift`
- Create: `Sources/UnfoldMac/Platform/ModifierGate.swift`
- Delete: `Sources/UnfoldMac/UnfoldMac.swift`
- Create: `Tests/UnfoldMacTests/SwallowLedgerTests.swift`
- Create: `Tests/UnfoldMacTests/ModifierGateTests.swift`

**Interfaces:**
- Consumes: `CoreGraphics` for `CGEventFlags`.
- Produces:
  - `struct SwallowLedger<Element>` with `mutating func swallow(_ element: Element)`, `mutating func expectKeyUp(for element: Element) -> Bool`, `var pendingCount: Int`, `mutating func release(_ count: Int) -> [Element]`, `mutating func releaseAll() -> [Element]`, `mutating func clear()`. Element is `Hashable`.
  - `enum ModifierGate` with `static func mayConsiderExpansion(_ flags: CGEventFlags) -> Bool` and `static func isCharacterProducing(flags: CGEventFlags, type: CGEventType) -> Bool`.
  - Task 5 consumes both; Task 3's tap callback uses `expectKeyUp` to decide whether a keyup is also swallowed.

- [ ] **Step 1: Write the failing ledger tests**

Create `Tests/UnfoldMacTests/SwallowLedgerTests.swift`:

```swift
import XCTest
@testable import UnfoldMac

final class SwallowLedgerTests: XCTestCase {
    func testReleaseReturnsElementsOldestFirst() {
        var ledger = SwallowLedger<Int>()
        ledger.swallow(11)
        ledger.swallow(12)
        ledger.swallow(13)

        XCTAssertEqual(ledger.release(2), [11, 12])
        XCTAssertEqual(ledger.pendingCount, 1)
        XCTAssertEqual(ledger.release(1), [13])
        XCTAssertEqual(ledger.pendingCount, 0)
    }

    func testReleaseAsksForMoreThanExistAndReturnsWhatItCan() {
        var ledger = SwallowLedger<Int>()
        ledger.swallow(7)

        XCTAssertEqual(ledger.release(3), [7])
        XCTAssertEqual(ledger.pendingCount, 0)
    }

    func testReleaseFromEmptyLedgerIsEmpty() {
        var ledger = SwallowLedger<Int>()
        XCTAssertEqual(ledger.release(4), [])
        XCTAssertEqual(ledger.releaseAll(), [])
    }

    func testKeyUpIsExpectedOnlyOncePerSwallowedElement() {
        var ledger = SwallowLedger<Int>()
        ledger.swallow(5)

        XCTAssertTrue(ledger.expectKeyUp(for: 5))
        XCTAssertFalse(ledger.expectKeyUp(for: 5), "a second keyup for the same element must pass through")
    }

    func testKeyUpForSomethingNeverSwallowedPassesThrough() {
        var ledger = SwallowLedger<Int>()
        XCTAssertFalse(ledger.expectKeyUp(for: 99))
    }

    func testReleaseAllDrainsEverythingAndLeavesItEmpty() {
        var ledger = SwallowLedger<String>()
        ledger.swallow("a")
        ledger.swallow("b")

        XCTAssertEqual(ledger.releaseAll(), ["a", "b"])
        XCTAssertEqual(ledger.pendingCount, 0)
        XCTAssertFalse(ledger.expectKeyUp(for: "a"))
    }

    func testReleaseZeroClaimsNothing() {
        var ledger = SwallowLedger<Int>()
        ledger.swallow(1)

        XCTAssertEqual(ledger.release(0), [])
        XCTAssertEqual(ledger.pendingCount, 1)
    }

    func testClearDiscardsWithoutReturning() {
        var ledger = SwallowLedger<Int>()
        ledger.swallow(1)
        ledger.swallow(2)
        ledger.clear()

        XCTAssertEqual(ledger.pendingCount, 0)
        XCTAssertEqual(ledger.release(2), [])
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter SwallowLedgerTests`
Expected: BUILD FAIL -- `cannot find 'SwallowLedger' in scope`.

- [ ] **Step 3: Write the ledger**

Create `Sources/UnfoldMac/Platform/SwallowLedger.swift`:

```swift
import Foundation

/// Tracks events the tap swallowed, so they can be handed back in the original form.
///
/// Two separate concerns, deliberately: the FIFO of swallowed keydowns awaiting re-post, and the
/// set of keycodes whose matching keyup must also be swallowed. A released prefix is only
/// re-inserted correctly if the keyups are eaten too -- otherwise the target app sees "press A,
/// release B" and typing desynchronizes.
public struct SwallowLedger<Element: Hashable> {
    private var queue: [Element] = []
    /// One pending keyup per swallowed keydown, counted. A `Set<Element>` cannot represent two
    /// swallowed keydowns of the same keycode, so auto-repeat and the double `d` in `addr` would eat
    /// one keyup and leak the rest -- the stuck-key failure this type exists to prevent.
    private var awaitingKeyUp: [Element: Int] = [:]

    public init() {}

    public var pendingCount: Int { queue.count }

    public mutating func swallow(_ element: Element) {
        queue.append(element)
        awaitingKeyUp[element, default: 0] += 1
    }

    /// True when this keyup belongs to a swallowed keydown and must be swallowed as well. Consumes
    /// exactly one expectation per call.
    public mutating func expectKeyUp(for element: Element) -> Bool {
        consumeKeyUpExpectation(for: element)
    }

    public mutating func release(_ count: Int) -> [Element] {
        guard count > 0, !queue.isEmpty else { return [] }
        let take = min(count, queue.count)
        let drained = Array(queue[0..<take])
        queue.removeFirst(take)
        // A re-posted keydown's keyup must reach the target app, or the app sees a press that never
        // ends. Consume exactly one keyup expectation per drained keydown, leaving the still-
        // buffered duplicates' expectations intact.
        drained.forEach { _ = consumeKeyUpExpectation(for: $0) }
        return drained
    }

    public mutating func releaseAll() -> [Element] {
        let drained = queue
        queue.removeAll()
        awaitingKeyUp.removeAll()
        return drained
    }

    /// Drops everything without returning it. Only valid when the keystrokes are known to be
    /// meaningless -- the user pressed Escape, or the app lost focus mid-trigger.
    public mutating func clear() {
        queue.removeAll()
        awaitingKeyUp.removeAll()
    }

    /// Removes exactly one pending keyup, dropping the key entirely once none are left. Returns
    /// whether an expectation existed to consume -- true even for the last one, since that keyup is
    /// still ours. Only `expectKeyUp` reads the answer; `release` drains one per keydown.
    @discardableResult
    private mutating func consumeKeyUpExpectation(for element: Element) -> Bool {
        guard let waiting = awaitingKeyUp[element], waiting > 0 else { return false }
        if waiting > 1 {
            awaitingKeyUp[element] = waiting - 1
        } else {
            awaitingKeyUp[element] = nil
        }
        return true
    }
}
```

`release(_:)` clamps to what exists rather than trapping, because the router asks it for the number of
leading `.emit` actions and an off-by-one there must degrade into a visibly wrong keystroke, not a
crash inside a system-wide tap callback.

Add the keyup test to `SwallowLedgerTests`:

```swift
    func testReleasingAnElementClearsItsPendingKeyUp() {
        var ledger = SwallowLedger<Int>()
        ledger.swallow(1)
        ledger.swallow(2)

        XCTAssertEqual(ledger.release(1), [1])
        XCTAssertFalse(ledger.expectKeyUp(for: 1), "its keydown went back, so its keyup must too")
        XCTAssertTrue(ledger.expectKeyUp(for: 2), "still buffered, still swallowed")
    }
```

- [ ] **Step 4: Write the failing modifier-gate tests**

Create `Tests/UnfoldMacTests/ModifierGateTests.swift`:

```swift
import CoreGraphics
import XCTest
@testable import UnfoldMac

final class ModifierGateTests: XCTestCase {
    func testNoModifiersIsEligible() {
        XCTAssertTrue(ModifierGate.mayConsiderExpansion([]))
    }

    func testShiftAndCapsLockAreEligibleBecauseTheyOnlyChangeTheCharacter() {
        XCTAssertTrue(ModifierGate.mayConsiderExpansion(.shift))
        XCTAssertTrue(ModifierGate.mayConsiderExpansion(.capsLock))
        XCTAssertTrue(ModifierGate.mayConsiderExpansion([.shift, .capsLock]))
    }

    func testCommandControlAndOptionAreNeverEligible() {
        XCTAssertFalse(ModifierGate.mayConsiderExpansion(.command))
        XCTAssertFalse(ModifierGate.mayConsiderExpansion(.control))
        XCTAssertFalse(ModifierGate.mayConsiderExpansion(.option))
        XCTAssertFalse(ModifierGate.mayConsiderExpansion([.command, .shift]),
                       "Cmd+Shift+A is a shortcut, not a trigger")
    }

    func testCharacterProducingRequiresAKeyDownWithoutBlockingModifiers() {
        XCTAssertTrue(ModifierGate.isCharacterProducing(flags: .shift, type: .keyDown))
        XCTAssertFalse(ModifierGate.isCharacterProducing(flags: .shift, type: .keyUp))
        XCTAssertFalse(ModifierGate.isCharacterProducing(flags: .maskCommand, type: .keyDown))
        XCTAssertFalse(ModifierGate.isCharacterProducing(flags: [], type: .flagsChanged))
        XCTAssertFalse(ModifierGate.isCharacterProducing(flags: [], type: .leftMouseDown))
    }
}
```

- [ ] **Step 5: Run them to verify they fail**

Run: `swift test --filter ModifierGateTests`
Expected: BUILD FAIL -- `cannot find 'ModifierGate' in scope`.

- [ ] **Step 6: Write the modifier gate**

Create `Sources/UnfoldMac/Platform/ModifierGate.swift`:

```swift
import CoreGraphics
import Foundation

public enum ModifierGate {
    /// Blocking modifiers mean the user is invoking a shortcut, not typing prose, so nothing in
    /// the sequence may be swallowed.
    private static let blocking: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate]

    public static func mayConsiderExpansion(_ flags: CGEventFlags) -> Bool {
        flags.isDisjoint(with: blocking)
    }

    /// The only events that carry a character worth feeding to the matcher.
    public static func isCharacterProducing(flags: CGEventFlags, type: CGEventType) -> Bool {
        type == .keyDown && mayConsiderExpansion(flags)
    }
}
```

- [ ] **Step 7: Run both suites, then the whole one**

Run: `swift test --filter SwallowLedgerTests && swift test --filter ModifierGateTests && swift test`
Expected: PASS -- 83 total: the 67 engine tests, the ledger's 12, and the gate's 4. Task 1's
`TargetWiringTests` placeholder is deleted in this task, so the starting count is 67, not 68. Of the
ledger's 12, three exist to pin keyup multiplicity -- two swallows of the same keycode must produce two
swallowed keyups, a partial release must keep the remaining duplicate's expectation, and `clear()` must
drop expectations as well as the queue.

- [ ] **Step 8: Commit**

```bash
cd "$REPO_ROOT"
git add Sources/UnfoldMac Tests/UnfoldMacTests
git commit -m "Add swallow ledger and modifier gate for keyboard capture"
```

---

### Task 3: Decode a keystroke into the character the system produced

**Files:**
- Create: `Sources/UnfoldMac/Platform/KeyboardDecoder.swift`
- Create: `Tests/UnfoldMacTests/KeyboardDecoderTests.swift`

**Interfaces:**
- Consumes: `CoreGraphics`.
- Produces: `enum KeyboardDecoder` with `static func character(from event: CGEvent) -> Character?`, `static func characters(from event: CGEvent) -> String?`, `static func keyCode(from event: CGEvent) -> Int`. Task 5's router takes those as inputs so it can be driven by synthetic events in tests.
- Implements ruling R-P2-1: the system's own translation is authoritative; there is no `UCKeyTranslate` call in this file, deliberately.

- [ ] **Step 1: Write the failing decoder tests**

Create `Tests/UnfoldMacTests/KeyboardDecoderTests.swift`:

```swift
import CoreGraphics
import XCTest
@testable import UnfoldMac

final class KeyboardDecoderTests: XCTestCase {
    private func keyDown(_ unicode: [UniChar]) -> CGEvent {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)!
        event.keyboardSetUnicodeString(maxLength: unicode.count, unicodeString: unicode)
        return event
    }

    func testDecodesASingleCharacter() {
        XCTAssertEqual(KeyboardDecoder.character(from: keyDown(Array("a".utf16))), "a")
    }

    func testDecodesACombinedGraphemeAsOneCharacter() {
        // "é" as a single precomposed scalar, which is what a layout hands over.
        XCTAssertEqual(KeyboardDecoder.character(from: keyDown(Array("é".utf16))), "é")
    }

    func testDecodesAStringWhoseLengthExceedsOneScalar() {
        // Some layouts produce multi-scalar sequences (Thai marks, ZWJ emoji). The router needs
        // the whole string to keep its ledger consistent with what the app will receive.
        let family = Array("👨‍👩‍👧".utf16)
        XCTAssertEqual(KeyboardDecoder.characters(from: keyDown(family)), "👨‍👩‍👧")
    }

    func testCharacterIsNilWhenTheStringHasMoreThanOneCharacter() {
        let two = Array("ab".utf16)
        XCTAssertNil(KeyboardDecoder.character(from: keyDown(two)))
        XCTAssertEqual(KeyboardDecoder.characters(from: keyDown(two)), "ab")
    }

    func testCharacterIsNilForAnEmptyPayload() {
        XCTAssertNil(KeyboardDecoder.character(from: keyDown([])))
        XCTAssertNil(KeyboardDecoder.characters(from: keyDown([])))
    }

    func testKeyCodeReadsTheVirtualKey() {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: 42, keyDown: true)!
        XCTAssertEqual(KeyboardDecoder.keyCode(from: event), 42)
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter KeyboardDecoderTests`
Expected: BUILD FAIL -- `cannot find 'KeyboardDecoder' in scope`.

- [ ] **Step 3: Write the decoder**

Create `Sources/UnfoldMac/Platform/KeyboardDecoder.swift`:

```swift
import CoreGraphics
import Foundation

public enum KeyboardDecoder {
    private static let bufferLimit = 16

    /// The full payload the target app will receive. Layouts can produce more than one scalar per
    /// keystroke, so this is the primitive that must not lose information.
    public static func characters(from event: CGEvent) -> String? {
        var length = 0
        var buffer = [UniChar](repeating: 0, count: bufferLimit)
        event.keyboardGetUnicodeString(maxStringLength: bufferLimit, actualLength: &length,
                                      unicodeString: &buffer)
        guard length > 0 else { return nil }
        return String(utf16CodeUnits: buffer, count: min(Int(length), bufferLimit))
    }

    /// The single-character case, which is all the matcher's `Character`-based vocabulary accepts.
    public static func character(from event: CGEvent) -> Character? {
        characters(from: event).flatMap { $0.count == 1 ? $0.first : nil }
    }

    public static func keyCode(from event: CGEvent) -> Int {
        Int(event.getIntegerValueField(.keyboardEventKeycode))
    }
}
```

If the compiler disagrees with the exact spelling of `keyboardGetUnicodeString` or the `inout Int`
versus `UnsafeMutablePointer<UniChar>` signature, **the compiler is authoritative** -- adjust and note it in the
plan. Do not switch to `UCKeyTranslate` to work around a signature problem; that would
overturn R-P2-1 silently.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter KeyboardDecoderTests`
Expected: PASS, 6 tests. These run without any accessibility permission because they construct events rather than intercept them -- that is the property that makes this layer testable.

- [ ] **Step 5: Run the whole suite and commit**

```bash
cd "$REPO_ROOT"
swift test
git add Sources/UnfoldMac/Platform/KeyboardDecoder.swift Tests/UnfoldMacTests/KeyboardDecoderTests.swift
git commit -m "Decode keystrokes with the system keyboard layout"
```

---

### Task 4: The event router -- all product logic in one testable function

**Files:**
- Create: `Sources/UnfoldMac/Platform/EventRouter.swift`
- Create: `Tests/UnfoldMacTests/EventRouterTests.swift`

**Interfaces:**
- Consumes: `Matcher`, `MatchAction`, `Combo` from `UnfoldEngine`; `SwallowLedger` and `ModifierGate` from Task 2; `KeyboardDecoder` from Task 3.
- Produces: `enum RoutedEvent { case keyDown(Character, Int), keyUp(Int), other }` and `enum RoutingDecision { case passThrough; case swallowAndRecord; case releaseThenPass([Int]); case expandThenPass(Combo, [Int]) }` and `struct EventRouter` with `init(matcher: Matcher)`, `mutating func route(_ event: RoutedEvent, flags: CGEventFlags) -> RoutingDecision`, `mutating func drainForIdle() -> [Int]`, `mutating func drainForFocusChange() -> [Int]`, `mutating func reset()`, `var bufferedCount: Int`. Task 5 maps decisions onto real `CGEvent` objects; the router deals only in keycodes so it can be tested without CoreGraphics state.

- [ ] **Step 1: Write the failing router tests**

Create `Tests/UnfoldMacTests/EventRouterTests.swift`:

```swift
import CoreGraphics
import UnfoldEngine
import XCTest
@testable import UnfoldMac

private func combo(_ trigger: String, _ replacement: String) -> Combo {
    Combo(id: UUID(), trigger: trigger, label: trigger, enabled: true,
          parts: [.text(replacement)], insertion: .paste)
}

final class EventRouterTests: XCTestCase {
    private func router(_ combos: [Combo]) -> EventRouter {
        EventRouter(matcher: Matcher(index: TriggerIndex(combos: combos)))
    }

    func testAnUnrelatedKeyPassesThrough() {
        var subject = router([combo("addr", "123 Main St")])
        XCTAssertEqual(subject.route(.keyDown("z", 44), flags: []), .passThrough)
        XCTAssertEqual(subject.bufferedCount, 0)
    }

    func testATriggerPrefixIsSwallowedAndRecorded() {
        var subject = router([combo("addr", "123 Main St")])
        XCTAssertEqual(subject.route(.keyDown("a", 0), flags: []), .swallowAndRecord)
        XCTAssertEqual(subject.bufferedCount, 1)
    }

    func testACompleteTriggerStillWaitsForADelimiter() {
        var subject = router([combo("add", "address")])
        _ = subject.route(.keyDown("a", 0), flags: [])
        _ = subject.route(.keyDown("d", 2), flags: [])
        XCTAssertEqual(subject.route(.keyDown("d", 2), flags: []), .swallowAndRecord)
    }

    func testADelimiterExpandsAndPassesItselfThrough() {
        let add = combo("add", "address")
        var subject = router([add])
        _ = subject.route(.keyDown("a", 0), flags: [])
        _ = subject.route(.keyDown("d", 2), flags: [])
        _ = subject.route(.keyDown("d", 2), flags: [])

        XCTAssertEqual(subject.route(.keyDown(" ", 49), flags: []), .expandThenPass(add, []))
        XCTAssertEqual(subject.bufferedCount, 0)
    }

    func testABrokenPrefixReleasesWhatItAteBeforePassingTheCurrentKey() {
        var subject = router([combo("addr", "123 Main St")])
        _ = subject.route(.keyDown("a", 0), flags: [])
        _ = subject.route(.keyDown("d", 2), flags: [])

        XCTAssertEqual(subject.route(.keyDown("z", 44), flags: []), .releaseThenPass([0, 2]))
        XCTAssertEqual(subject.bufferedCount, 0)
    }

    func testABlockingModifierReleasesTheBufferAndPassesTheEvent() {
        var subject = router([combo("addr", "123 Main St")])
        _ = subject.route(.keyDown("a", 0), flags: [])

        XCTAssertEqual(subject.route(.keyDown("d", 2), flags: .maskCommand), .releaseThenPass([0]))
    }

    func testKeyUpForASwallowedKeyIsSwallowedTooButUnrelatedKeyUpPasses() {
        var subject = router([combo("addr", "123 Main St")])
        _ = subject.route(.keyDown("a", 0), flags: [])

        XCTAssertEqual(subject.route(.keyUp(0), flags: []), .swallowAndRecord)
        XCTAssertEqual(subject.route(.keyUp(6), flags: []), .passThrough)
    }

    func testIdleDrainReturnsTheBufferInOrderAndClearsIt() {
        var subject = router([combo("addr", "123 Main St")])
        _ = subject.route(.keyDown("a", 0), flags: [])
        _ = subject.route(.keyDown("d", 2), flags: [])

        XCTAssertEqual(subject.drainForIdle(), [0, 2])
        XCTAssertEqual(subject.bufferedCount, 0)
        XCTAssertEqual(subject.drainForIdle(), [])
    }

    func testFocusChangeDrainBehavesLikeIdleDrain() {
        var subject = router([combo("addr", "123 Main St")])
        _ = subject.route(.keyDown("a", 0), flags: [])

        XCTAssertEqual(subject.drainForFocusChange(), [0])
        XCTAssertEqual(subject.bufferedCount, 0)
    }

    func testExpansionCarriesNoReleaseBecauseTheTriggerWasConsumed() {
        let add = combo("add", "address")
        var subject = router([add])
        _ = subject.route(.keyDown("a", 0), flags: [])
        _ = subject.route(.keyDown("d", 2), flags: [])
        _ = subject.route(.keyDown("d", 2), flags: [])
        XCTAssertEqual(subject.route(.keyDown(" ", 49), flags: []), .expandThenPass(add, []))
    }

    func testNonKeyEventsPassThrough() {
        var subject = router([combo("addr", "123 Main St")])
        XCTAssertEqual(subject.route(.other, flags: []), .passThrough)
    }

    func testAnUninterpretableKeyReleasesTheBufferRatherThanStrandingIt() {
        var subject = router([combo("addr", "123 Main St")])
        _ = subject.route(.keyDown("a", 0), flags: [])
        _ = subject.route(.keyDown("d", 2), flags: [])

        XCTAssertEqual(subject.route(.other, flags: []), .releaseThenPass([0, 2]))
        XCTAssertEqual(subject.bufferedCount, 0)
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter EventRouterTests`
Expected: BUILD FAIL -- `cannot find 'EventRouter' in scope`.

- [ ] **Step 3: Write the router**

Create `Sources/UnfoldMac/Platform/EventRouter.swift`:

```swift
import CoreGraphics
import Foundation
import UnfoldEngine

public enum RoutedEvent: Equatable {
    case keyDown(Character, Int)
    case keyUp(Int)
    case other
}

public enum RoutingDecision: Equatable {
    case passThrough
    case swallowAndRecord
    case releaseThenPass([Int])
    case expandThenPass(Combo, [Int])
}

public struct EventRouter {
    private var matcher: Matcher
    private var ledger = SwallowLedger<Int>()

    public init(matcher: Matcher) {
        self.matcher = matcher
    }

    public var bufferedCount: Int { ledger.pendingCount }

    public mutating func route(_ event: RoutedEvent, flags: CGEventFlags) -> RoutingDecision {
        switch event {
        case .other:
            // Added during Task 3's review. A key the decoder could not reduce to one character --
            // a multi-grapheme payload, a refused oversize payload, anything undecoded -- is a break
            // in the typing sequence. Passing it through while a partial prefix stays buffered
            // strands those characters: the app receives this key first and the old prefix re-posted
            // after it. Release in order, then let this one through.
            let stranded = ledger.releaseAll()
            return stranded.isEmpty ? .passThrough : .releaseThenPass(stranded)
        case .keyUp(let code):
            return ledger.expectKeyUp(for: code) ? .swallowAndRecord : .passThrough
        case .keyDown(let character, let code):
            return routeKeyDown(character: character, code: code, flags: flags)
        }
    }

    /// Release everything the ledger is holding so the caller can re-post it, then discard the
    /// matcher's copy of the same prefix. Both steps are required: releasing the ledger without
    /// resetting the matcher leaves `buffer` holding characters the app has already been given, so
    /// continuing to type expands a trigger out of text that is already on screen -- the reviewer
    /// reproduced `ad` + drain + `d space` producing "address" on top of the released "ad".
    public mutating func drainForIdle() -> [Int] {
        let codes = ledger.releaseAll()
        matcher.reset()
        return codes
    }

    public mutating func drainForFocusChange() -> [Int] {
        let codes = ledger.releaseAll()
        matcher.reset()
        return codes
    }

    /// Forgets the half-typed trigger and the word boundary together. The coordinator drains and
    /// re-posts before calling this (Plan 1 residuals R3 and R4), so nothing is lost here -- but the
    /// next field genuinely starts clean, which is why a trigger typed as the very first keystroke
    /// after a focus change needs one more character before it expands.
    public mutating func reset() {
        matcher.reset()
        ledger.clear()
    }

    private mutating func routeKeyDown(character: Character, code: Int,
                                       flags: CGEventFlags) -> RoutingDecision {
        // A blocking modifier means this is a shortcut, not prose. Hand back everything we were
        // holding before deciding anything else, so Cmd+anything is never assembled from eaten keys.
        guard ModifierGate.mayConsiderExpansion(flags) else {
            let released = ledger.releaseAll()
            return released.isEmpty ? .passThrough : .releaseThenPass(released)
        }

        let actions = matcher.feed(character)

        // Plan 1's F3 invariant, relied on here: the LAST action concerns the event in hand, and
        // every LEADING `.emit` is a re-post of a character eaten earlier, in order.
        var expanded: Combo?
        var releasedCodes: [Int] = []
        for action in actions.dropLast() {
            switch action {
            case .expand(let combo): expanded = combo
            case .emit: if let next = ledger.release(1).first { releasedCodes.append(next) }
            case .swallow: break
            }
        }

        if let combo = expanded {
            // The trigger's own events are consumed by the expansion, and its keyups must be
            // allowed through afterwards.
            ledger.clear()
            return .expandThenPass(combo, releasedCodes)
        }

        if actions.last == .swallow {
            ledger.swallow(code)
            return .swallowAndRecord
        }

        return releasedCodes.isEmpty ? .passThrough : .releaseThenPass(releasedCodes)
    }
}
```

`ledger.clear()` on the expansion path also forgets outstanding keyups for any *other* key held down
at the same moment. That is a deliberate v1 simplification -- the matcher assumes sequential typing --
and it is the reason Task 7's checklist includes a Ctrl-C-in-Terminal case rather than trusting this.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter EventRouterTests`
Expected: PASS, 12 tests. `testKeyUpForASwallowedKeyIsSwallowedTooButUnrelatedKeyUpPasses` and `testABrokenPrefixReleasesWhatItAteBeforePassingTheCurrentKey` are the two that keep this keyboard sink from eating the user's writing; if they fail, the ledger and the positional rule are being conflated.

- [ ] **Step 5: Verify the ledger and buffer agree after every case**

Add, inside `EventRouterTests`:

```swift
    func testAnExpandedTriggerLeavesNothingAwaitingKeyUp() {
        var subject = router([combo("add", "address")])
        _ = subject.route(.keyDown("a", 0), flags: [])
        _ = subject.route(.keyDown("d", 2), flags: [])
        _ = subject.route(.keyDown("d", 2), flags: [])
        _ = subject.route(.keyDown(" ", 49), flags: [])

        XCTAssertEqual(subject.route(.keyUp(2), flags: []), .passThrough,
                       "the keyup of an expanded trigger must not be swallowed")
    }
```

Run: `swift test --filter EventRouterTests`
Expected: PASS, 14 tests. If it fails, `ledger.clear()` is not being reached on the expansion path.

Also pin the reset contract, which Task 6's focus-change path depends on:

```swift
    func testResetForgetsTheBufferAndThePendingKeyups() {
        var subject = router([combo("addr", "123 Main St")])
        _ = subject.route(.keyDown("a", 0), flags: [])
        subject.reset()

        XCTAssertEqual(subject.bufferedCount, 0)
        XCTAssertEqual(subject.route(.keyUp(0), flags: []), .passThrough,
                       "a keyup for an event the new field never started must not be eaten")
    }
```

- [ ] **Step 6: Run the whole suite, then commit**

```bash
cd "$REPO_ROOT"
swift test
git add Sources/UnfoldMac/Platform/EventRouter.swift Tests/UnfoldMacTests/EventRouterTests.swift
git commit -m "Route keystrokes through the matcher in one testable decision"
```

---

### Task 5: Own the event tap

This is the first task that can affect the machine outside this repository. It must not be **run** until turning a system-wide tap on has been approved, and it must be reviewed as though a bug here silences the user's keyboard.

**Files:**
- Create: `Sources/UnfoldMac/Platform/KeystrokeSource.swift`
- Create: `Tests/UnfoldMacTests/KeystrokeSourceTests.swift`

**Interfaces:**
- Consumes: `EventRouter`, `KeyboardDecoder`, `ModifierGate` from Tasks 2-4.
- Produces: `enum TapOutcome { case pass(CGEvent), swallow, repost([CGEvent], thenPass: CGEvent?) }`; `final class KeystrokeSource` with `init(handler: @escaping (RoutedEvent, CGEventFlags, CGEvent) -> TapOutcome)`, `@discardableResult func start() -> Bool`, `func stop()`, `var isActive: Bool`; and the statics `interestedMask: CGEventMask` and `route(into:type:) -> RoutedEvent` that the tests exercise. Task 6's coordinator supplies `handler`.

- [ ] **Step 1: Write the tests that do not need a real tap**

Create `Tests/UnfoldMacTests/KeystrokeSourceTests.swift`:

```swift
import CoreGraphics
import XCTest
@testable import UnfoldMac

final class KeystrokeSourceTests: XCTestCase {
    func testEventMaskCoversKeyDownKeyUpAndFlagsChanged() {
        let mask = KeystrokeSource.interestedMask
        XCTAssertTrue(mask.contains(.keyDown))
        XCTAssertTrue(mask.contains(.keyUp))
        XCTAssertTrue(mask.contains(.flagsChanged))
        XCTAssertFalse(mask.contains(.leftMouseDown),
                       "a keyboard sink must not be asked about the mouse")
    }

    func testKeyDownMapsThroughTheDecoder() {
        let down = CGEvent(keyboardEventSource: nil, virtualKey: 6, keyDown: true)!
        let payload = Array("b".utf16)
        down.keyboardSetUnicodeString(maxLength: payload.count, unicodeString: payload)

        if case .keyDown(let character, let code) = KeystrokeSource.route(into: down, type: .keyDown) {
            XCTAssertEqual(character, "b")
            XCTAssertEqual(code, 6)
        } else {
            XCTFail("a decoded keyDown must map to .keyDown")
        }
    }

    func testKeyUpMapsToKeyUpWithoutDecoding() {
        let up = CGEvent(keyboardEventSource: nil, virtualKey: 6, keyDown: false)!
        if case .keyUp(let code) = KeystrokeSource.route(into: up, type: .keyUp) {
            XCTAssertEqual(code, 6)
        } else {
            XCTFail("a keyUp must map to .keyUp")
        }
    }

    func testAKeyDownWithNoDecodableCharacterIsNotConsidered() {
        // Arrow and function keys arrive with an empty payload. Guessing at them would let the
        // matcher swallow a keystroke it cannot name, so they must map to .other and pass through.
        let arrow = CGEvent(keyboardEventSource: nil, virtualKey: 123, keyDown: true)!
        XCTAssertEqual(KeystrokeSource.route(into: arrow, type: .keyDown), .other)
    }

    func testFlagsChangedAndUnrelatedTypesMapToOther() {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: 56, keyDown: true)!
        XCTAssertEqual(KeystrokeSource.route(into: event, type: .flagsChanged), .other)
        XCTAssertEqual(KeystrokeSource.route(into: event, type: .leftMouseDown), .other)
    }

    func testAnAutoRepeatedKeydownIsNotANewKeystroke() {
        // Flag 0x400 marks a repeat. One burst produces many keydowns and a single keyup, which the
        // ledger cannot reconcile, and holding a key should never build or fire a trigger.
        let repeated = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)!
        let payload = Array("a".utf16)
        repeated.keyboardSetUnicodeString(stringLength: payload.count, unicodeString: payload)
        repeated.flags.insert(CGEventFlags(rawValue: 0x400))

        XCTAssertEqual(KeystrokeSource.route(into: repeated, type: .keyDown), .other)
    }

    func testReleaseEventMatchesTheSwallowedKeycode() {
        let down = CGEvent(keyboardEventSource: nil, virtualKey: 6, keyDown: true)!
        guard let up = KeystrokeSource.releaseEvent(matching: down) else {
            return XCTFail("a swallowed keydown must have a synthesizable release")
        }
        XCTAssertEqual(KeyboardDecoder.keyCode(from: up), 6)
        XCTAssertFalse(up.type == .keyDown, "the synthesized companion must be a keyUp")
    }
}
```

`interestedMask` is a `CGEventMask`, which is a `UInt64` bit set, so `mask.contains(.keyDown)` works
directly. If your toolchain wants `CGEventMask(eventMask:)` around it, that is the same assertion --
the compiler decides the spelling, not this document.

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter KeystrokeSourceTests`
Expected: BUILD FAIL -- `cannot find 'KeystrokeSource' in scope`.

- [ ] **Step 3: Write the tap owner**

Create `Sources/UnfoldMac/Platform/KeystrokeSource.swift`:

```swift
import CoreGraphics
import Foundation

public enum TapOutcome {
    case pass(CGEvent)
    case swallow
    case repost([CGEvent], thenPass: CGEvent?)
}

public final class KeystrokeSource {
    /// keyDown for characters, keyUp so swallowed presses do not leave keys stuck down in the
    /// target app, flagsChanged so a modifier press can drop a half-typed trigger.
    static let interestedMask: CGEventMask =
        (1 << CGEventType.keyDown.rawValue) |
        (1 << CGEventType.keyUp.rawValue) |
        (1 << CGEventType.flagsChanged.rawValue)

    static func route(into event: CGEvent, type: CGEventType) -> RoutedEvent {
        switch type {
        case .keyDown:
            // Auto-repeat carries flag bit 0x400, which has no named member in CGEventFlags. A
            // repeated keydown is not a new keystroke: a trigger is a sequence of distinct presses,
            // and one burst produces a single keyup for many keydowns, which is exactly the shape
            // the ledger cannot reconcile. Treat repeats as uninterpretable so the buffer releases.
            if event.flags.contains(CGEventFlags(rawValue: 0x400)) { return .other }
            guard let character = KeyboardDecoder.character(from: event) else { return .other }
            return .keyDown(character, KeyboardDecoder.keyCode(from: event))
        case .keyUp:
            return .keyUp(KeyboardDecoder.keyCode(from: event))
        default:
            return .other
        }
    }

    /// The release half of a swallowed keydown, synthesized for re-posting. See the repost arm of the
    /// tap callback for why a bare re-posted press is not enough.
    static func releaseEvent(matching event: CGEvent) -> CGEvent? {
        CGEvent(keyboardEventSource: nil,
                virtualKey: CGKeyCode(KeyboardDecoder.keyCode(from: event)),
                keyDown: false)
    }

    private let handler: (RoutedEvent, CGEventFlags, CGEvent) -> TapOutcome
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private(set) var isActive = false

    /// Bounded so a hostile environment cannot make us respawn taps in a loop.
    private var reEnableAttempts = 0
    static let maximumReEnableAttempts = 3

    init(handler: @escaping (RoutedEvent, CGEventFlags, CGEvent) -> TapOutcome) {
        self.handler = handler
    }

    /// The callback must be a C function pointer, so state arrives through `refcon`. Nothing here
    /// may throw, allocate unboundedly, or block: a slow callback gets the tap disabled by macOS.
    private static let callback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon else { return Unmanaged.passUnretained(event) }
        let source = Unmanaged<KeystrokeSource>.fromOpaque(refcon).takeUnretainedValue()

        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            source.enableAgain()
            return Unmanaged.passUnretained(event)
        case .keyDown, .keyUp, .flagsChanged:
            return source.handle(type: type, event: event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch handler(Self.route(into: event, type: type), event.flags, event) {
        case .pass(let forwarded):
            return Unmanaged.passUnretained(forwarded)
        case .swallow:
            return nil
        case .repost(let earlier, thenPass: let current):
            // Released keystrokes go back first, in the order they were eaten, so the re-posted
            // prefix cannot land after the character that broke it. Each one gets a synthesized
            // release too: its real keyup almost certainly arrived while the keydown was still
            // buffered and was eaten by the ledger, and re-posting a press with no release leaves
            // the target app believing the key is still held down.
            for original in earlier {
                original.post(tap: .cgSessionEventTap)
                Self.releaseEvent(matching: original)?.post(tap: .cgSessionEventTap)
            }
            return current.map { Unmanaged.passRetained($0) } ?? nil
        }
    }

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return isActive }
        let mask = KeystrokeSource.interestedMask
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: KeystrokeSource.callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        tap = port
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        isActive = true
        reEnableAttempts = 0
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes) }
        tap = nil
        runLoopSource = nil
        isActive = false
    }

    private func enableAgain() {
        guard reEnableAttempts < KeystrokeSource.maximumReEnableAttempts, let tap else { return }
        reEnableAttempts += 1
        CGEvent.tapEnable(tap: tap, enable: true)
    }
}
```

Retention rules, because a wrong choice here leaks once per keystroke: `passUnretained` is correct
for the event CoreGraphics handed in and for a `.pass` of that same event, since the callback does not
own them. `passRetained` is only correct for a *different* event object being substituted. A
`flagsChanged` event must never be swallowed -- the coordinator uses it only to release the buffer --
because a modifier press that vanishes leaves the user's keyboard in the wrong state.

- [ ] **Step 4: Run the tests**

Run: `swift test --filter KeystrokeSourceTests && swift test`
Expected: PASS. The mask test is the only real gate here: it asserts the tap subscribes to
`keyDown`, `keyUp`, and `flagsChanged` and **nothing else**, which is what keeps a keystroke sink
from ever touching mouse traffic.

- [ ] **Step 5: Do not attach a live tap in this task**

No step here starts a tap. Attaching one requires an explicit go-ahead and an accessibility
grant; that is Task 7.

- [ ] **Step 6: Commit**

```bash
cd "$REPO_ROOT"
git add Sources/UnfoldMac/Platform/KeystrokeSource.swift Tests/UnfoldMacTests/KeystrokeSourceTests.swift
git commit -m "Add the event tap owner with bounded disable recovery"
```

---

### Task 6: Inject the replacement, and pause without losing keystrokes

**Files:**
- Create: `Sources/UnfoldMac/Platform/Injector.swift`
- Create: `Sources/UnfoldMac/Platform/ExpansionCoordinator.swift`
- Create: `Tests/UnfoldMacTests/ExpansionCoordinatorTests.swift`

**Interfaces:**
- Consumes: `Combo`, `InsertionMode`, `Part`, `Template` from `UnfoldEngine`; everything from Tasks 2-5.
- Produces: `Injector` with `func insert(_ text: String, mode: InsertionMode)`; `ExpansionCoordinator` with `init(source:store:...)`, `func resume()`, `func pause(repostingBuffered: Bool)`, `func handleIdle()`, `func handleFocusChange()`, `var isPaused: Bool`, `var inactivePlaceholderCount: Int`. Discharges Plan 1 residuals **R3** (focus teardown must drain, not discard) and **R4** (drained keystrokes must be re-posted, and the API must not let a caller ignore them).

- [ ] **Step 1: Write the failing coordinator tests**

Create `Tests/UnfoldMacTests/ExpansionCoordinatorTests.swift`. There are no test seams: the
coordinator's real `handle(_:flags:original:)` is driven with synthetic `CGEvent`s, and both the
injector and the re-post sink are injected fakes. A production API shaped by test convenience is the
smell this file is written to avoid.

```swift
import CoreGraphics
import UnfoldEngine
import XCTest
@testable import UnfoldMac

private final class FakeInjector: TextInjecting {
    var insertions: [(String, InsertionMode)] = []
    func insert(_ text: String, mode: InsertionMode) { insertions.append((text, mode)) }
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

// CGEvent is a CF type with no Equatable conformance, so outcomes are inspected structurally and
// events are compared by identity. Do not add `==` to TapOutcome to make assertions shorter.
private func swallowed(_ outcome: TapOutcome) -> Bool {
    if case .swallow = outcome { return true }
    return false
}

private func repostedEvents(_ outcome: TapOutcome) -> [CGEvent] {
    if case .repost(let events, thenPass: _) = outcome { return events }
    return []
}

private func forwardedEvent(_ outcome: TapOutcome) -> CGEvent? {
    switch outcome {
    case .pass(let event): return event
    case .repost(_, thenPass: let event): return event
    case .swallow: return nil
    }
}

final class ExpansionCoordinatorTests: XCTestCase {
    private func subject(_ combos: [Combo])
        -> (ExpansionCoordinator, FakeInjector, RepostRecorder) {
        let injector = FakeInjector()
        let recorder = RepostRecorder()
        let coordinator = ExpansionCoordinator(
            combos: combos,
            injector: injector,
            repost: { recorder.posted.append($0) }
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

    func testATriggerPrefixIsSwallowed() {
        let (coordinator, _, _) = subject([combo("addr", parts: [textPart("123 Main St")])])

        XCTAssertTrue(swallowed(coordinator.handle(.keyDown("a", 0), flags: [],
                                                  original: keyEvent(0, down: true))))
        XCTAssertEqual(coordinator.bufferedCount, 1)
    }

    func testCompletingATriggerInjectsAndForwardsTheDelimiter() {
        let (coordinator, injector, recorder) = subject([combo("add", parts: [textPart("address")])])
        _ = coordinator.handle(.keyDown("a", 0), flags: [], original: keyEvent(0, down: true))
        _ = coordinator.handle(.keyDown("d", 2), flags: [], original: keyEvent(2, down: true))
        _ = coordinator.handle(.keyDown("d", 2), flags: [], original: keyEvent(2, down: true))

        let space = keyEvent(49, down: true)
        XCTAssertTrue(forwardedEvent(coordinator.handle(.keyDown(" ", 49), flags: [],
                                                       original: space)) === space)
        XCTAssertEqual(injector.insertions, [("address", .paste)])
        XCTAssertEqual(recorder.posted.count, 0, "a consumed trigger re-posts nothing")
        XCTAssertEqual(coordinator.bufferedCount, 0)
    }

    func testABrokenPrefixRepostsTheOriginalEventsInOrder() {
        let (coordinator, injector, _) = subject([combo("addr", parts: [textPart("123 Main St")])])
        let first = keyEvent(0, down: true)
        let second = keyEvent(2, down: true)
        _ = coordinator.handle(.keyDown("a", 0), flags: [], original: first)
        _ = coordinator.handle(.keyDown("d", 2), flags: [], original: second)

        let z = keyEvent(44, down: true)
        let outcome = coordinator.handle(.keyDown("z", 44), flags: [], original: z)
        let released = repostedEvents(outcome)
        XCTAssertEqual(released.count, 2)
        XCTAssertTrue(released.first === first, "the oldest swallowed event must go back first")
        XCTAssertTrue(released.last === second)
        XCTAssertTrue(forwardedEvent(outcome) === z)
        XCTAssertTrue(injector.insertions.isEmpty)
    }

    func testABlockingModifierReleasesTheBufferAndPassesTheEvent() {
        let (coordinator, _, _) = subject([combo("addr", parts: [textPart("123 Main St")])])
        let first = keyEvent(0, down: true)
        _ = coordinator.handle(.keyDown("a", 0), flags: [], original: first)

        let commandD = keyEvent(2, down: true)
        let outcome = coordinator.handle(.keyDown("d", 2), flags: .maskCommand, original: commandD)
        XCTAssertTrue(repostedEvents(outcome).first === first)
        XCTAssertTrue(forwardedEvent(outcome) === commandD)
    }

    func testPausedSwallowsNothingAndPassesEverything() {
        let (coordinator, _, _) = subject([combo("addr", parts: [textPart("123 Main St")])])
        let held = keyEvent(0, down: true)
        _ = coordinator.handle(.keyDown("a", 0), flags: [], original: held)

        let releasedByPause = coordinator.pause()
        XCTAssertEqual(releasedByPause.count, 1, "pause must hand back what it was holding")
        XCTAssertTrue(releasedByPause.first === held)
        XCTAssertTrue(coordinator.isPaused)

        let event = keyEvent(2, down: true)
        XCTAssertTrue(forwardedEvent(coordinator.handle(.keyDown("d", 2), flags: [],
                                                       original: event)) === event)
        XCTAssertEqual(coordinator.bufferedCount, 0)
    }

    func testIdleAndFocusChangeBothRepostTheBuffer() {
        let (idleCoordinator, _, _) = subject([combo("addr", parts: [textPart("123 Main St")])])
        let held = keyEvent(0, down: true)
        _ = idleCoordinator.handle(.keyDown("a", 0), flags: [], original: held)
        let released = idleCoordinator.handleIdle()
        XCTAssertTrue(released.first === held)
        XCTAssertEqual(idleCoordinator.bufferedCount, 0)

        let (focusCoordinator, _, _) = subject([combo("addr", parts: [textPart("123 Main St")])])
        let heldToo = keyEvent(0, down: true)
        _ = focusCoordinator.handle(.keyDown("a", 0), flags: [], original: heldToo)
        XCTAssertTrue(focusCoordinator.handleFocusChange().first === heldToo)
    }

    func testComposedTextJoinsLiteralParts() {
        let signature = combo("sig", parts: [textPart("Best, "), textPart("Robin")])
        let (coordinator, _, _) = subject([signature])
        XCTAssertEqual(coordinator.composedText(for: signature), "Best, Robin")
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter ExpansionCoordinatorTests`
Expected: BUILD FAIL -- `cannot find 'ExpansionCoordinator' in scope`.

- [ ] **Step 3: Write the injector**

Create `Sources/UnfoldMac/Platform/Injector.swift`:

```swift
import AppKit
import CoreGraphics
import UnfoldEngine

public protocol TextInjecting {
    func insert(_ text: String, mode: InsertionMode)
}

public final class Injector: TextInjecting {
    private let pasteboard = NSPasteboard.general
    /// Restoring synchronously races the target app's read, so the restore is deferred and
    /// guarded by changeCount (ruling R-P2-4).
    private static let restoreDelay = 0.25
    private static let vKeyCode = 9

    public init() {}

    public func insert(_ text: String, mode: InsertionMode) {
        switch mode {
        case .paste: paste(text)
        case .keys: type(text)
        }
    }

    private func paste(_ text: String) {
        let saved = capture()
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        let ourCount = pasteboard.changeCount
        postCmdV()

        DispatchQueue.main.asyncAfter(deadline: .now() + Injector.restoreDelay) { [pasteboard] in
            guard pasteboard.changeCount == ourCount else { return }
            restore(saved, to: pasteboard)
        }
    }

    private func capture() -> [(NSPasteboard.PasteboardType, Data)] {
        pasteboard.types?.compactMap { type in
            pasteboard.data(forType: type).map { (type, $0) }
        } ?? []
    }

    private static func restore(_ items: [(NSPasteboard.PasteboardType, Data)],
                                to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        for (type, data) in items { pasteboard.setData(data, forType: type) }
    }

    private func postCmdV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(Injector.vKeyCode), keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(Injector.vKeyCode), keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cgSessionEventTap)
        up?.post(tap: .cgSessionEventTap)
    }

    /// For apps that reject synthetic paste. Setting the unicode string directly sidesteps layout.
    private func type(_ text: String) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for scalar in text.unicodeScalars {
            var utf16 = Array(String(scalar).utf16)
            let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
            down?.keyboardSetUnicodeString(maxLength: utf16.count, unicodeString: &utf16)
            down?.post(tap: .cgSessionEventTap)
            CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)?.post(tap: .cgSessionEventTap)
        }
    }
}
```

`capture()` snapshots every pasteboard type, not just `.string`, because a user copying an image and
then expanding a snippet must get the image back. `type(_:)` declares `utf16` as `var` only because
`keyboardSetUnicodeString` takes an `inout` array; `let` will not compile.

- [ ] **Step 4: Write the coordinator**

Create `Sources/UnfoldMac/Platform/ExpansionCoordinator.swift`:

```swift
import CoreGraphics
import Foundation
import UnfoldEngine

public final class ExpansionCoordinator {
    public let combos: [Combo]
    public let active: [Combo]
    public let inactivePlaceholderCount: Int

    private var router: EventRouter
    private let injector: TextInjecting
    private let repost: (CGEvent) -> Void

    /// The exact events behind the router's ledger, in the same order. The two are popped in
    /// lockstep; every transition below keeps `heldEvents.count == router.bufferedCount` or
    /// restores it, and a divergence is a bug in this file rather than a condition to tolerate.
    private var heldEvents: [CGEvent] = []

    private var source: KeystrokeSource?
    public private(set) var isPaused = true

    public init(combos: [Combo], injector: TextInjecting = Injector(),
                repost: @escaping (CGEvent) -> Void = { $0.post(tap: .cgSessionEventTap) }) {
        let live = combos.filter(\.enabled)
        let promptable = live.filter { combo in
            combo.parts.allSatisfy { if case .text = $0 { return true }; return false }
        }
        self.combos = combos
        self.active = promptable
        self.inactivePlaceholderCount = live.count - promptable.count
        self.injector = injector
        self.repost = repost
        self.router = EventRouter(matcher: Matcher(index: TriggerIndex(combos: promptable)))
    }

    public var activeCount: Int { active.count }
    public var registeredTriggers: Set<String> { Set(active.map(\.trigger)) }
    public var bufferedCount: Int { heldEvents.count }

    public func handle(_ event: RoutedEvent, flags: CGEventFlags, original: CGEvent) -> TapOutcome {
        guard !isPaused else { return .pass(original) }

        switch router.route(event, flags: flags) {
        case .passThrough:
            return .pass(original)

        case .swallowAndRecord:
            // Only the keydown is held. A keyup is swallowed to keep the target app from seeing a
            // press it never saw the start of, and it must not be re-posted on its own.
            if case .keyDown = event { heldEvents.append(original) }
            return .swallow

        case .releaseThenPass(let codes):
            let events = take(count: codes.count)
            events.forEach(repost)
            return .repost(events, thenPass: original)

        case .expandThenPass(let combo, let codes):
            precondition(codes.isEmpty,
                         "the matcher never emits a release before an expansion; see Plan 1 rule 3")
            _ = take(count: codes.count)
            // Everything still buffered belongs to the trigger being replaced, so it is dropped,
            // not reposted. This is the one place the buffer is discarded rather than returned.
            heldEvents.removeAll()
            injector.insert(composedText(for: combo), mode: combo.insertion)
            return .repost([], thenPass: original)
        }
    }

    @discardableResult
    public func pause() -> [CGEvent] {
        isPaused = true
        return drainRouter()
    }

    public func resume() {
        isPaused = false
    }

    @discardableResult
    public func handleIdle() -> [CGEvent] { drainRouter() }

    /// Plan 1 residual R3: focus changes must release the buffer, never discard it, and R4: the
    /// caller has to see what was released. Resetting the matcher afterwards closes the word
    /// boundary, so the first trigger typed into the newly focused field needs one more character
    /// after it -- accepted, fail-safe, and deliberately not hidden.
    @discardableResult
    public func handleFocusChange() -> [CGEvent] {
        let released = drainRouter()
        router.reset()
        return released
    }

    public func composedText(for combo: Combo) -> String {
        combo.parts.reduce(into: "") { result, part in
            if case .text(let value) = part { result += value }
        }
    }

    @discardableResult
    public func attachTap() -> Bool {
        if source == nil {
            source = KeystrokeSource { [weak self] event, flags, original in
                self?.handle(event, flags: flags, original: original) ?? .pass(original)
            }
        }
        return source?.start() ?? false
    }

    public func detachTap() {
        source?.stop()
        source = nil
    }

    private func drainRouter() -> [CGEvent] {
        let events = take(count: router.bufferedCount)
        _ = router.drainForIdle()
        // Drains that are not happening inside the tap callback have no one else to post them, so
        // this does. The `.releaseThenPass` path out of `handle` does NOT post -- the tap owner does,
        // and doing both would type the released characters twice.
        events.forEach(repost)
        return events
    }

    private func take(count: Int) -> [CGEvent] {
        guard count > 0, !heldEvents.isEmpty else { return [] }
        let take = min(count, heldEvents.count)
        let events = Array(heldEvents[0..<take])
        heldEvents.removeFirst(take)
        return events
    }
}
```

Both supporting changes are already specified in the tasks that own those files -- `SwallowLedger.release(_:)` clears the pending keyup in Task 2, and `EventRouter.reset()` is added in Task 4. If you reach Task 6 and either is missing, fix it in its own file and commit it separately rather than working around it here.

- [ ] **Step 5: Run the suite and prove the safety properties are pinned**

Run: `swift test`
Expected: PASS. Then verify by mutation, reporting exactly which tests fail for each:
- make `pause()` return an empty array while still swallowing → a test must fail
- make `handleFocusChange()` call `clear()` instead of releasing → a test must fail
- make `release(_:)` leave `awaitingKeyUp` untouched → the stuck-keyup test must fail

- [ ] **Step 6: Commit**

```bash
cd "$REPO_ROOT"
git add Sources/UnfoldMac Tests/UnfoldMacTests
git commit -m "Coordinate expansion, injection, and safe teardown on pause"
```

---

### Task 7: The menu-bar shell, the permission flow, and the first live tap

Nothing before this task touches a real keyboard. Everything in it does, so it ends with the decision to attach a tap, and the safety switch exists before the tap does.

**Files:**
- Create: `Sources/Unfold/AppShell/PermissionFlow.swift`
- Create: `Sources/Unfold/AppShell/StatusItemController.swift`
- Modify: `Sources/Unfold/main.swift`

**Interfaces:**
- Consumes: `UnfoldMac` (`KeystrokeSource`, `ExpansionCoordinator`, `Injector`), `UnfoldEngine` (`Store`, `CombosFile`).
- Produces: a menu-bar agent whose menu is, in order: status line (active / paused / not permitted), **Pause expansion / Resume expansion**, `N combos active`, `M combos inactive (need prompt UI)`, `Open combos file`, `Quit Unfold`.

- [ ] **Step 1: Write the permission flow**

Create `Sources/Unfold/AppShell/PermissionFlow.swift`:

```swift
import AppKit
import ApplicationServices

enum PermissionFlow {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Only called from an explicit user action, never on launch: prompting unasked trains people
    /// to click through permission dialogs.
    static func prompt() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
        AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    static func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    /// Polls rather than observing, because there is no public notification for the grant.
    /// The interval is deliberately loose: this stops once granted.
    static func waitUntilTrusted(interval: TimeInterval = 1.0, onChange: @escaping (Bool) -> Void) -> Timer {
        var last = isTrusted
        onChange(last)
        return Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { timer in
            let now = isTrusted
            if now != last {
                last = now
                onChange(now)
            }
        }
    }
}
```

- [ ] **Step 2: Write the status item**

Create `Sources/Unfold/AppShell/StatusItemController.swift`:

```swift
import AppKit
import UnfoldEngine
import UnfoldMac

final class StatusItemController {
    private let coordinator: ExpansionCoordinator
    private let statusItem: NSStatusItem

    init(coordinator: ExpansionCoordinator) {
        self.coordinator = coordinator
        self.statusItem = NSStatusBar.system.statusItem(withLength: .variableLength)
        statusItem.button?.title = "⌁"
        refresh()
    }

    func refresh() {
        let menu = NSMenu()

        let status = NSMenuItem(title: statusLine(), action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        menu.addItem(NSMenuItem(title: coordinator.isPaused ? "Resume Expansion" : "Pause Expansion",
                                action: #selector(togglePause), keyEquivalent: "p",
                                target: self))
        menu.addItem(NSMenuItem(title: "\(coordinator.activeCount) combos active",
                                action: nil, keyEquivalent: ""))

        let inactive = coordinator.inactivePlaceholderCount
        if inactive > 0 {
            let note = NSMenuItem(title: "\(inactive) inactive (need the prompt UI)",
                                  action: nil, keyEquivalent: "")
            note.isEnabled = false
            menu.addItem(note)
        }

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Open Combos File",
                                action: #selector(openCombosFile), keyEquivalent: "", target: self))
        menu.addItem(NSMenuItem(title: "Allow Keyboard Access...",
                                action: #selector(requestPermission), keyEquivalent: "", target: self))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Unfold",
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func statusLine() -> String {
        if !PermissionFlow.isTrusted {
            return "Not permitted -- allow Accessibility in Settings"
        }
        return coordinator.isPaused ? "Paused" : "Listening"
    }

    @objc private func togglePause() {
        if coordinator.isPaused {
            coordinator.resume()
            _ = coordinator.attachTap()
        } else {
            // pause() already re-posts what it released through the coordinator's sink; calling
            // post() again here would type the user's half-finished trigger a second time.
            coordinator.pause()
            coordinator.detachTap()
        }
        refresh()
    }

    @objc private func openCombosFile() {
        NSWorkspace.shared.activateFileViewerSelecting([Store.defaultURL()])
    }

    @objc private func requestPermission() {
        PermissionFlow.prompt()
        PermissionFlow.openAccessibilitySettings()
    }
}
```

Requirements this satisfies that are not cosmetic: the status line states **why** nothing is happening
rather than going quiet, `Allow Keyboard Access...` is the only path that prompts, and `Pause` detaches
the tap *after* releasing the buffer -- reversing those two eats whatever the user had half-typed.
The idle timer lives on the coordinator's owner: schedule `Timer.scheduledTimer(withTimeInterval: 2.5,
repeats: true)` in `AppDelegate` calling `coordinator.handleIdle()`, which reposts through the
injected sink and returns what it released for logging.

- [ ] **Step 3: Write the composition root**

Replace `Sources/Unfold/main.swift`:

```swift
import AppKit
import UnfoldEngine
import UnfoldMac

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: StatusItemController?
    private var permissionTimer: Timer?
    private var coordinator: ExpansionCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let file = (try? Store(url: Store.defaultURL()).load()) ?? CombosFile(
            formatVersion: CombosFile.currentFormatVersion, combos: [])
        let coordinator = ExpansionCoordinator(combos: file.combos)
        self.coordinator = coordinator
        statusItem = StatusItemController(coordinator: coordinator)

        permissionTimer = PermissionFlow.waitUntilTrusted { [weak self] trusted in
            guard let self else { return }
            if trusted {
                coordinator.resume()
                _ = coordinator.attachTap()
            } else {
                // pause() releases and re-posts whatever was buffered; detaching first would strand
                // the half-typed trigger inside a tap that is about to stop seeing events.
                coordinator.pause()
                coordinator.detachTap()
            }
            self.statusItem?.refresh()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.pause()
        coordinator?.detachTap()
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
```

`attachTap()` / `detachTap()` do not exist on `ExpansionCoordinator` yet -- add them in this task, and
make `attachTap()` refuse to create a tap when `PermissionFlow.isTrusted` is false. That refusal is
the difference between an app that quietly does nothing and one that silently swallows keystrokes
with no explanation.

- [ ] **Step 4: Run the suite and build the app bundle**

```bash
cd "$REPO_ROOT"
swift test
./Scripts/make-app-bundle.sh debug
```
Expected: suite green; bundle built. **Stop here.** Do not launch it attached to a tap.

- [ ] **Step 5: Get the go-ahead, then verify by hand**

The live verification is a checklist, and each item needs their permission grant:

1. Launch, open System Settings → Privacy & Security → Accessibility, enable Unfold. The menu status line must change without relaunching.
2. In **TextEdit**, type `addr ` and confirm expansion. Confirm the trigger characters never appear on screen.
3. Type `address` with a live `add` combo and confirm nothing fires.
4. Type `addr` then stop for three seconds; confirm `addr` appears (idle drain), and confirm it is not duplicated.
5. Press and hold Command mid-prefix: the prefix must reappear, not expand.
6. Click into a different app mid-prefix: same.
7. In a browser **password field**, confirm typing is untouched and the menu reports the Secure Input / no-keystrokes state rather than pretending to work.
8. With the clipboard holding something real, expand a combo and confirm the original clipboard content is back afterwards.
9. Pause from the menu, type `addr `, confirm no expansion and nothing lost. Resume.
10. In **Terminal**, confirm the tap still works, and confirm Ctrl-C is never swallowed.

Record each result with what actually happened, including anything that failed. A
keyboard sink verified only in TextEdit is not verified.

- [ ] **Step 6: Commit, and stop short of pushing**

```bash
cd "$REPO_ROOT"
git add Sources/Unfold Sources/UnfoldMac
git commit -m "Add menu-bar shell, permission flow, and live tap attach"
```

---

## Verification

```bash
cd "$REPO_ROOT"
swift build
swift test
grep -rn "^import " Sources/UnfoldEngine/ | grep -v "Foundation" || echo "engine still Foundation-only"
grep -rn "UCKeyTranslate(" Sources/ || echo "R-P2-1 intact: the system's own translation is used"
```

All four must pass, and Task 7 Step 5's checklist must be filled in with observed results, not
intentions.

## What this plan deliberately does not do

- No combo editor UI and no placeholder prompt. Placeholder combos stay inactive (R-P2-2).
- No per-app filters, no signing, no notarization, no Sparkle, no Linux.
- No automated test of the real tap. `CGEvent.tapCreate` needs a trusted process and a live session;
  the design puts every decision in `EventRouter` and `SwallowLedger` precisely so the risky part is
  the smallest part, and Task 7's checklist covers the rest.
