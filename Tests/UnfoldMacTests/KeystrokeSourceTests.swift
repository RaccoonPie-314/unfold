import CoreGraphics
import UnfoldEngine
import XCTest
@testable import UnfoldMac

final class KeystrokeSourceTests: XCTestCase {
    // This SDK spells membership as a bit test on CGEventMask (a UInt64); `mask.contains(.keyDown)`
    // does not compile. The plan says the compiler decides the spelling -- this is the same assertion.
    private func maskContains(_ mask: CGEventMask, _ type: CGEventType) -> Bool {
        mask & (CGEventMask(1) << type.rawValue) != 0
    }

    /// A keydown carrying exactly `scalar` in its Unicode payload, which is how a tapped keystroke
    /// reaches `route`. `String(Unicode.Scalar(_:)).utf16` is one unit for every BMP scalar used
    /// here, so the decoder always sees a single-character payload.
    private func keyDown(carrying scalar: UInt32, keycode: CGKeyCode = 123) -> CGEvent {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: keycode, keyDown: true)!
        let payload = Array(String(Unicode.Scalar(scalar)!).utf16)
        event.keyboardSetUnicodeString(stringLength: payload.count, unicodeString: payload)
        return event
    }

    private func name(_ scalar: UInt32) -> String { String(format: "U+%04X", scalar) }

    func testEventMaskCoversKeyDownKeyUpAndFlagsChanged() {
        let mask = KeystrokeSource.interestedMask
        XCTAssertTrue(maskContains(mask, .keyDown))
        XCTAssertTrue(maskContains(mask, .keyUp))
        XCTAssertTrue(maskContains(mask, .flagsChanged))
        XCTAssertFalse(maskContains(mask, .leftMouseDown),
                       "a keyboard sink must not be asked about the mouse")
    }

    func testKeyDownMapsThroughTheDecoder() {
        let down = CGEvent(keyboardEventSource: nil, virtualKey: 6, keyDown: true)!
        let payload = Array("b".utf16)
        down.keyboardSetUnicodeString(stringLength: payload.count, unicodeString: payload)

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
        // A key the decoder cannot reduce to one character must map to .other and pass through:
        // guessing at it would let the matcher swallow a keystroke it cannot name.
        //
        // This is the plan's own empty-payload fixture, restored. Task 5's note claimed a
        // zero-length payload was unconstructible on this SDK; that is disproven -- the earlier probe
        // passed `unicodeString: nil`, which the setter ignores, while `stringLength: 0` with a real
        // (empty) buffer does clear it. Read back after clearing: reportedLen == 0.
        let arrow = CGEvent(keyboardEventSource: nil, virtualKey: 123, keyDown: true)!
        var empty: [UniChar] = []
        arrow.keyboardSetUnicodeString(stringLength: 0, unicodeString: &empty)
        XCTAssertEqual(KeystrokeSource.route(into: arrow, type: .keyDown), .other)
    }

    func testAMultiScalarPayloadIsStillUndecodable() {
        // The other half of "cannot reduce to one character": what a ligature layout emits for one
        // keystroke. Pinned in KeyboardDecoderTests for the decoder; pinned here for the route.
        let ligature = CGEvent(keyboardEventSource: nil, virtualKey: 123, keyDown: true)!
        let payload = Array("fi".utf16)
        ligature.keyboardSetUnicodeString(stringLength: payload.count, unicodeString: payload)
        XCTAssertEqual(KeystrokeSource.route(into: ligature, type: .keyDown), .other)
    }

    func testControlAndPrivateUseStandinsNeverReachTheMatcher() {
        // Unmapped keys carry per-keycode stand-ins -- Backspace U+0008, Escape U+001B, the arrows
        // U+001C...U+001F, Home U+0001, End U+0004, F1 U+0010 -- and real arrow/function keys report
        // U+F700...U+F7FF. Every one of them is a single non-word `Character`, so before this rule they
        // acted as delimiters and FIRED an expansion: pressing Backspace or Escape mid-typing rewrote
        // the user's text. DEL (U+007F) is listed explicitly because it is not a C0 control and it is
        // the most destructive of the set. All must be .other, which makes the router release the
        // buffered prefix and pass the key through untouched.
        for scalar: UInt32 in [0xF703, 0x001B, 0x007F, 0x0008] {
            XCTAssertEqual(KeystrokeSource.route(into: keyDown(carrying: scalar), type: .keyDown), .other,
                           "\(name(scalar)) must never be offered to the matcher as a keystroke")
        }
    }

    func testTabLineFeedCarriageReturnAndSpaceStillDecodeAsKeystrokes() {
        // The four controls that really are part of typing: Tab and Return/Enter close a trigger the
        // same way they do in the app, Space is the word boundary. Excluding the inert set must not
        // sweep these up with it.
        for scalar: UInt32 in [0x0009, 0x000A, 0x000D, 0x0020] {
            if case .keyDown(let character, _) = KeystrokeSource.route(into: keyDown(carrying: scalar),
                                                                      type: .keyDown) {
                XCTAssertEqual(character, Character(Unicode.Scalar(scalar)!),
                               "\(name(scalar)) must still decode to itself")
            } else {
                XCTFail("\(name(scalar)) must still route as .keyDown so it can close a trigger")
            }
        }
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

    // MARK: - Re-entrancy: a re-posted prefix must not be eaten a second time

    func testAnEventMarkedAsRepostedIsForwardedAndNeverReachesTheHandler() throws {
        // The repost arm hands events back to `.cgSessionEventTap`, and `CGEventPost` documents that
        // a posted event "passes through" the taps at that location -- including the head-insert tap
        // that is running this very callback. Without the mark, the released prefix re-enters
        // `handle`, gets swallowed again and re-posted again: duplicated keystrokes, recursively.
        let marked = keyDown(carrying: 0x0061, keycode: 0)
        KeystrokeSource.markAsReposted(marked)

        var handlerSaw: [RoutedEvent] = []
        let source = KeystrokeSource { event, _, _ in
            handlerSaw.append(event)
            return .swallow  // wrong on purpose: reaching it at all is the failure
        }

        let forwarded = try XCTUnwrap(source.handle(type: .keyDown, event: marked),
                                      "a marked re-post must be forwarded, never swallowed")
        XCTAssertTrue(handlerSaw.isEmpty,
                      "the guard must short-circuit before the handler: a second swallow re-posts "
                        + "the prefix again")
        XCTAssertTrue(forwarded.toOpaque() == Unmanaged.passUnretained(marked).toOpaque(),
                      "the guard must forward the very event CoreGraphics handed in")
    }

    func testAnUnmarkedKeystrokeStillReachesTheHandler() {
        // The other side of the guard: it must only deflect what this type posted, or real typing
        // never reaches the matcher and nothing ever expands.
        let fresh = keyDown(carrying: 0x0061, keycode: 0)
        var handlerSaw: [RoutedEvent] = []
        let source = KeystrokeSource { event, _, _ in
            handlerSaw.append(event)
            return .swallow
        }

        XCTAssertFalse(KeystrokeSource.isReposted(fresh), "a keystroke starts unmarked")
        XCTAssertNil(source.handle(type: .keyDown, event: fresh))
        XCTAssertEqual(handlerSaw.count, 1, "an unmarked keydown must be routed to the handler")
    }

    func testEveryEventHandedToCoreGraphicsForARepostCarriesTheMark() {
        // Marking is what makes the guard work, and it must be on the way out for every event this
        // type posts -- the buffered press and its synthesized release both re-enter the tap.
        // `eventsToPost(forRepost:)` is the pure half of the repost arm: it is the exact list the arm
        // hands to `post(tap:)`, so the marking is testable without posting into the live session.
        let press = keyDown(carrying: 0x0061, keycode: 0)
        let outgoing = KeystrokeSource.eventsToPost(forRepost: [press])

        XCTAssertEqual(outgoing.count, 2, "a re-posted press goes out with its synthesized release")
        XCTAssertEqual(KeyboardDecoder.keyCode(from: outgoing[0]), 0)
        XCTAssertEqual(outgoing[0].type, .keyDown)
        XCTAssertEqual(KeyboardDecoder.keyCode(from: outgoing[1]), 0)
        XCTAssertNotEqual(outgoing[1].type, .keyDown, "the companion must be a release")
        for (index, event) in outgoing.enumerated() {
            XCTAssertTrue(KeystrokeSource.isReposted(event),
                          "outgoing event \(index) must be marked before it is posted")
        }
    }

    func testTheRepostMarkIsPerEventAndZeroIsTheUnmarkedDefault() {
        let first = keyDown(carrying: 0x0061, keycode: 0)
        let second = keyDown(carrying: 0x0062, keycode: 1)
        KeystrokeSource.markAsReposted(first)

        XCTAssertTrue(KeystrokeSource.isReposted(first))
        XCTAssertFalse(KeystrokeSource.isReposted(second),
                       "marking one event must not deflect the keystrokes around it")
    }

    // MARK: - Retention: identity decides, not the arm

    func testRetentionFollowsIdentityAndNotWhichArmProducedTheEvent() {
        // CoreGraphics owns the event it handed in and releases the reference it is given back, so
        // `passRetained` on that same object leaks one CGEvent per callback and `passUnretained` on a
        // substituted object over-releases it. The decision is "is this the object we were handed".
        let handedIn = keyDown(carrying: 0x0061, keycode: 0)
        let substituted = keyDown(carrying: 0x0062, keycode: 1)

        XCTAssertEqual(KeystrokeSource.ownership(of: handedIn, comparedTo: handedIn),
                       .coreGraphicsStillOwnsIt,
                       "forwarding the handed-in event must not claim ownership of it")
        XCTAssertEqual(KeystrokeSource.ownership(of: substituted, comparedTo: handedIn),
                       .callbackTookOwnership,
                       "a substituted event is the callback's to hand over")
    }

    // MARK: - The tap and the engine must agree about what a trigger can be

    /// The codepoints the two agreement sweeps visit -- 139,751 of the 1,114,112 the platform can name.
    ///
    /// The scope is **derived, not restated**: it is the union of the very range lists `isInertScalar`
    /// consults, plus the scalars it names outside every range, plus the surrogate plane. That makes it
    /// exact rather than an approximation, because refusal is
    /// `!isWordCharacter && unicodeScalars.contains(where: isInertScalar)` -- a character can only be
    /// refused if one of its scalars is inert, and every inert scalar is in this set. Add a range to the
    /// predicate and the sweep visits it automatically, which a hand-copied list of ranges in the test
    /// would not do.
    ///
    /// Left out is the ~974,000 codepoints the predicate calls prose: `refuses` is false for them by
    /// construction, so the exhaustive loop round 2 ran spent ~4.4 s of suite time proving that. Nothing
    /// is lost by narrowing and that is asserted, not assumed -- `unholdable == 2048` still proves the
    /// surrogates are the only unreachable part of the space, and `refused.count == 137_665` is the
    /// exhaustive sweep's own number, so a scope that started missing refusals fails loudly.
    private func sweptCodepoints() -> [UInt32] {
        var values: Set<UInt32> = []
        for ranges in [KeystrokeSource.controlRanges, KeystrokeSource.formatRanges,
                       KeystrokeSource.privateUseRanges, KeystrokeSource.appleFunctionRanges] {
            for range in ranges { values.formUnion(range) }
        }
        values.formUnion([0x007F, 0xFFFD])  // spelled out by the predicate outside every range
        values.formUnion(0xD800...0xDFFF)   // Cs: unholdable, and the only part of the space that is
        return values.sorted()
    }

    /// A whole trigger made of `trigger`, so `TriggerIndex` can be asked whether the engine would take
    /// the character at all.
    private func combo(_ trigger: String) -> Combo {
        Combo(id: UUID(), trigger: trigger, label: trigger, enabled: true,
              parts: [.text("x")], insertion: .paste)
    }

    /// The invariant, swept over every scalar the platform can hold: a character the tap refuses must
    /// also be a character `TriggerIndex` refuses as a trigger.
    ///
    /// The two sides used to answer this question from different definitions -- the tap from a list of
    /// Unicode general categories, the engine from `isWordCharacter` -- and 35 Apple private-use
    /// characters (`U+F882`, `U+F89A-F8A7`, `U+F8B8`, `U+F8C1-F8D6`) slipped between the answers: this
    /// machine's Unicode data classifies them as letters, so a trigger ending in one saved fine while
    /// the tap refused to deliver the keystroke that would have completed it. The user is left holding
    /// a combo that can never fire, which is the defect class `unfoldctl check` was written to reject.
    /// This sweep is what stops the disagreement from coming back silently, over the scope that can
    /// contain one (`sweptCodepoints`).
    func testEveryCharacterTheTapRefusesIsAlsoRejectedAsATrigger() {
        var refused: [Character] = []
        var unholdable = 0
        for value in sweptCodepoints() {
            // `Unicode.Scalar` refuses to hold U+D800...U+DFFF, so the surrogate block is the one part of
            // the space no sweep can visit -- and the one part no decoded keystroke can carry, because a
            // lone surrogate has already degraded to U+FFFD by the time the decoder returns a String.
            guard let scalar = Unicode.Scalar(value) else { unholdable += 1; continue }
            if KeystrokeSource.refuses(Character(scalar)) { refused.append(Character(scalar)) }
        }
        XCTAssertEqual(unholdable, 2048, "the surrogates are the only scalars a sweep cannot construct")
        XCTAssertFalse(refused.isEmpty, "the sweep refused nothing; the predicate is dead code")
        XCTAssertEqual(refused.count, 137_665,
                       "the scoped sweep must refuse exactly the set the exhaustive one found; a "
                         + "different total means the scope fell behind the predicate's own ranges")

        let index = TriggerIndex(combos: refused.map { combo(String($0)) })
        let disagreements = index.accepted.map(\.trigger)
        XCTAssertTrue(disagreements.isEmpty,
                      "the tap refuses \(disagreements.count) characters the engine accepts as triggers, e.g. "
                        + disagreements.prefix(10).map { "'\($0)'" }.joined(separator: ", ")
                        + " — a saved combo that can never fire")
        XCTAssertEqual(index.rejections.count, refused.count,
                       "every refused character must reach the rejection list, not be dropped")
    }

    /// The other direction, and the one that was actually broken: a character the engine *will* accept
    /// must survive the tap. Pins the 35 scalars this finding was filed against by name, and asks the
    /// question three ways -- the predicate, the trigger index, and the production path through `route`.
    func testTheInertRangeCharactersTheEngineCallsWordsAreStillKeystrokes() {
        var wordAndInert: [UInt32] = []
        for value in sweptCodepoints() {
            guard let scalar = Unicode.Scalar(value) else { continue }
            if KeystrokeSource.isInertScalar(scalar), isWordCharacter(Character(scalar)) {
                wordAndInert.append(value)
            }
        }
        XCTAssertEqual(wordAndInert,
                       [0xF882, 0xF89A, 0xF89B, 0xF89C, 0xF89D, 0xF89E, 0xF8A2, 0xF8A3, 0xF8A4, 0xF8A5,
                        0xF8A6, 0xF8A7, 0xF8B8, 0xF8C1, 0xF8C2, 0xF8C3, 0xF8C4, 0xF8C5, 0xF8C6, 0xF8C7,
                        0xF8C8, 0xF8C9, 0xF8CA, 0xF8CB, 0xF8CC, 0xF8CD, 0xF8CE, 0xF8CF, 0xF8D0, 0xF8D1,
                        0xF8D2, 0xF8D3, 0xF8D4, 0xF8D5, 0xF8D6],
                       "the set of word-classified characters inside the inert ranges changed: a range "
                         + "that now covers a letter is a range that can refuse a live trigger again")
        for value in wordAndInert {
            let character = Character(Unicode.Scalar(value)!)
            XCTAssertFalse(KeystrokeSource.refuses(character),
                           "\(name(value)) is a letter to this machine's data, so the tap must not refuse it")
            XCTAssertEqual(TriggerIndex(combos: [combo(String(character))]).accepted.count, 1,
                           "\(name(value)) must be a trigger the engine accepts, or there was no disagreement")
            if case .keyDown(let routed, _) = KeystrokeSource.route(into: keyDown(carrying: value),
                                                                   type: .keyDown) {
                XCTAssertEqual(routed, character, "\(name(value)) must reach the matcher")
            } else {
                XCTFail("\(name(value)) must route as .keyDown, not be dropped at the tap")
            }
        }
    }

    // MARK: - The re-enable budget keeps a ceiling

    /// Drives a budget with a fake `enable` so the ceiling is tested as it is applied. `live` is what
    /// the read-back answers -- always true is the shape a persistently slow callback makes: the tap
    /// does come back on, and then times out again immediately.
    ///
    /// `now` is seconds on the clock `ReEnableBudget.monotonicNow` reads, fed by hand: that is what
    /// makes the window arithmetic testable at all. The tests below pin the *policy* -- three in a
    /// window, the fourth latches, a window that passes ages an attempt out -- and only
    /// `testTheBudgetIsDrivenByAMonotonicClockAndNotTheCalendar` pins the clock the policy is read from.
    private func recover(_ budget: inout KeystrokeSource.ReEnableBudget,
                         at now: TimeInterval,
                         enablements: inout Int,
                         live: Bool = true) -> Bool {
        budget.recover(at: now) { enablements += 1; return live }
    }

    func testTheReEnableBudgetRefusesADisableStormInsideOneWindow() {
        XCTAssertEqual(KeystrokeSource.ReEnableBudget.maximumAttempts, 3,
                       "the documented ceiling; a change here must change the comment with it")
        XCTAssertEqual(KeystrokeSource.ReEnableBudget.window, 60, accuracy: 0.001,
                       "the documented window; a change here must change the comment with it")

        var budget = KeystrokeSource.ReEnableBudget()
        var enablements = 0
        let start: TimeInterval = 1_000
        XCTAssertTrue(recover(&budget, at: start, enablements: &enablements))
        XCTAssertTrue(recover(&budget, at: start + 2, enablements: &enablements))
        XCTAssertTrue(recover(&budget, at: start + 4, enablements: &enablements))
        // Three timeouts inside one window is not ordinary load, it is a callback that cannot keep up.
        XCTAssertFalse(recover(&budget, at: start + 6, enablements: &enablements),
                       "a fourth re-enable in the same window is the loop round 1 allowed")
        XCTAssertEqual(enablements, 3, "past the ceiling the tap must not be poked at all")
        XCTAssertTrue(budget.hasGivenUp,
                      "the state the caller must report instead of claiming the tap is live")
        // Given up is a latch, not a rate limit: the window expiring must not restart the hammering.
        XCTAssertFalse(recover(&budget, at: start + 3_600, enablements: &enablements))
        XCTAssertEqual(enablements, 3)
    }

    func testReEnableAttemptsThatTookDoNotRestoreTheBudget() {
        // The exact decay that made round 1 unbounded: every re-enable below answered "yes, it is
        // enabled again", and a lifetime cap with that reset re-enables a slow callback forever.
        var budget = KeystrokeSource.ReEnableBudget()
        var enablements = 0
        let start: TimeInterval = 1_000
        for index in 0..<3 {
            XCTAssertTrue(recover(&budget, at: start + Double(index) * 3,
                                  enablements: &enablements, live: true))
        }
        XCTAssertFalse(recover(&budget, at: start + 9,
                               enablements: &enablements, live: true))
        XCTAssertTrue(budget.hasGivenUp)
    }

    func testTimeoutsWiderThanOneWindowNeverAddUpToAShutdown() {
        var budget = KeystrokeSource.ReEnableBudget()
        var enablements = 0
        let start: TimeInterval = 1_000
        let spacing = KeystrokeSource.ReEnableBudget.window + 1
        // An afternoon of one timeout per window-and-a-bit -- a login transition here, a Spotlight
        // rebuild there -- must keep expanding. This is the property round 1's lifetime-total cap broke.
        for index in 0..<12 {
            XCTAssertTrue(recover(&budget, at: start + spacing * Double(index),
                                  enablements: &enablements),
                          "the timeout at +\(Int(spacing * Double(index)))s met a closed budget")
        }
        XCTAssertEqual(enablements, 12)
        XCTAssertFalse(budget.hasGivenUp)
    }

    func testOnlyADeliberateRestartReopensAGivenUpBudget() {
        var budget = KeystrokeSource.ReEnableBudget()
        var enablements = 0
        let start: TimeInterval = 1_000
        for index in 0..<4 {
            _ = recover(&budget, at: start + Double(index), enablements: &enablements)
        }
        XCTAssertTrue(budget.hasGivenUp)
        XCTAssertFalse(recover(&budget, at: start + 86_400, enablements: &enablements))
        // The latch opens for a person asking for the tap back, and for nothing else: at this level
        // that is `ReEnableBudget.restart()`, which `KeystrokeSource.restart()` calls -- the test below
        // walks the same thing from the source, through the arm the callback uses.
        budget.restart()
        XCTAssertTrue(recover(&budget, at: start + 86_401, enablements: &enablements))
        XCTAssertFalse(budget.hasGivenUp)
    }

    // MARK: - A failed start must leave the object as fresh as it was

    /// Stand-ins for the three CoreGraphics tap calls, with the counters that prove what `start()` did.
    ///
    /// `KeystrokeSource.coreGraphicsTapBridge` is the only place `CGEvent.tapCreate`,
    /// `CGEvent.tapEnable` and `CGEvent.tapIsEnabled` are written, so a source built with one of these
    /// cannot touch the session: the "no live tap" rule holds for the retry tests by construction, and
    /// the port they hand back is a plain mach port (`CFMachPortCreate`), never a tap.
    private final class TapBridgeProbe {
        private(set) var creations = 0
        private(set) var enablements = 0
        private(set) var disablements = 0
        /// How many creations hand back a port before they start returning nil; `0` fails every one,
        /// which is how a process without Accessibility permission fails.
        var portCreations = 0
        /// The enable read-back stays false until this attempt number: a tap that exists but refuses
        /// to switch on.
        var enableSucceedsFrom = 1
        /// What the live `isEnabled` read answers for the port. Flipped by a test to simulate a tap
        /// macOS invalidated without telling `isActive`.
        var enabled = true
        private(set) var enabledQueries = 0

        func bridge() -> KeystrokeSource.TapBridge {
            KeystrokeSource.TapBridge(
                create: { [weak self] _, _ in
                    guard let self else { return nil }
                    self.creations += 1
                    guard self.creations <= self.portCreations else { return nil }
                    var shouldFreeInfo = DarwinBoolean(false)
                    return CFMachPortCreate(kCFAllocatorDefault, nil, nil, &shouldFreeInfo)
                },
                enable: { [weak self] _ in
                    guard let self else { return false }
                    self.enablements += 1
                    return self.enablements >= self.enableSucceedsFrom
                },
                disable: { [weak self] _ in self?.disablements += 1 },
                isEnabled: { [weak self] _ in
                    guard let self else { return false }
                    self.enabledQueries += 1
                    return self.enabled
                }
            )
        }
    }

    func testASourceThatCouldNotCreateATapCanTryAgain() {
        let probe = TapBridgeProbe()
        probe.portCreations = 0
        let source = KeystrokeSource(handler: { _, _, _ in .swallow }, bridge: probe.bridge())

        XCTAssertFalse(source.start())
        XCTAssertFalse(source.isActive)
        XCTAssertEqual(probe.creations, 1)

        // Before the fix `start()` wrote `tap` and registered the run-loop source before it knew
        // whether either had taken, so the `guard tap == nil` at the top answered from the wreckage:
        // the second start did not reach CoreGraphics at all and the only way back was `stop()`.
        XCTAssertFalse(source.start())
        XCTAssertEqual(probe.creations, 2, "a start that failed must be retryable without a stop()")

        source.stop()
        XCTAssertEqual(probe.disablements, 0,
                       "a start that created nothing leaves nothing for stop() to switch off")
    }

    func testASourceWhoseTapRefusedToEnableIsRolledBackAndRetries() {
        let probe = TapBridgeProbe()
        probe.portCreations = 2
        probe.enableSucceedsFrom = 2
        let source = KeystrokeSource(handler: { _, _, _ in .swallow }, bridge: probe.bridge())

        XCTAssertFalse(source.start(), "a tap that exists but will not switch on is not an active source")
        XCTAssertFalse(source.isActive)
        XCTAssertEqual(probe.enablements, 1)
        XCTAssertEqual(probe.disablements, 0,
                       "the rolled-back port is dropped, not registered with the run loop and abandoned")

        XCTAssertTrue(source.start(), "the retry must reach CoreGraphics again")
        XCTAssertTrue(source.isActive)
        XCTAssertEqual(probe.creations, 2)

        source.stop()
        XCTAssertEqual(probe.disablements, 1, "stop() goes through the bridge, so no test calls the tap API")
        XCTAssertFalse(source.isActive)
    }

    // MARK: - The path back from a budget the recovery gave up on

    /// Round 2's contract said `isActive == false` with `hasGivenUp == true` means "only a `start()`
    /// brings it back", and the re-review is right that the path cannot execute: when the recovery
    /// gives up, the port is *still registered*, so `start()`'s `guard tap == nil` answers from it,
    /// returns `isActive` -- false -- and control never reaches the `restart()` at the bottom.
    ///
    /// The recovery is `KeystrokeSource.restart()`, not a latch cleared inside `start()`: a `start()`
    /// that reopened the budget would hand anyone polling it on a timer a free refill, which is the
    /// loop round 2's ceiling exists to end, and it is the thing round 2's own contract warned against.
    /// This walks the sequence a persistently slow callback actually leaves behind -- through the same
    /// arm the C callback uses (`enableAgain`) -- so the path is live here or it is dead code.
    func testTheDocumentedRecoveryBringsBackATapTheBudgetGaveUpOn() {
        let probe = TapBridgeProbe()
        probe.portCreations = 1
        let source = KeystrokeSource(handler: { _, _, _ in .swallow }, bridge: probe.bridge())
        XCTAssertTrue(source.start())
        XCTAssertEqual(probe.enablements, 1, "start() enables and reads back through the seam")

        // Four disables inside one window: three are ridden out, the fourth latches the budget.
        for _ in 0..<4 { source.enableAgain() }
        XCTAssertFalse(source.isActive, "the fourth disable reports the tap off")
        XCTAssertTrue(source.reEnableBudget.hasGivenUp)
        XCTAssertEqual(probe.enablements, 4, "past the ceiling the port must not be poked at all")

        // Round 2's documented recovery. `start()` answers from the port that is still registered and
        // returns `isActive`, so it is *not* the path back -- pinned here because the two calls are
        // otherwise one keystroke of confusion apart, and a coordinator that polls `start()` to work
        // around the latch would re-open exactly the loop the ceiling closes.
        XCTAssertFalse(source.start(),
                       "start() cannot recover a tap it never stopped: the guard returns isActive")
        XCTAssertFalse(source.isActive, "and the tap stays off")
        XCTAssertTrue(source.reEnableBudget.hasGivenUp, "a refused start must not clear the latch either")
        XCTAssertEqual(probe.creations, 1, "a refused start must not create a second tap")

        // The recovery that is documented now: clear the latch and switch the same port back on.
        XCTAssertTrue(source.restart(),
                      "the documented recovery must report the tap live again")
        XCTAssertTrue(source.isActive,
                      "a latched budget with the port still registered is exactly the state the user is "
                        + "left in: the tap is off, and a deliberate request has to bring it back")
        XCTAssertFalse(source.reEnableBudget.hasGivenUp, "recovery must clear the latch")
        XCTAssertEqual(probe.enablements, 5,
                       "recovery switches the existing port on through the seam, never CGEvent.tapEnable")
        XCTAssertEqual(probe.creations, 1,
                       "recovery switches the existing port back on; a second tapCreate would strand the first")

        // And the tap is usable again: a keystroke still reaches the handler, and the next disable is
        // treated as a transient instead of being refused.
        XCTAssertNil(source.handle(type: .keyDown, event: keyDown(carrying: 0x0061)),
                     "the handler must still be consulted, or the recovered tap is not a live tap")
        source.enableAgain()
        XCTAssertTrue(source.isActive, "after a recovery a fresh timeout is a transient, not a refusal")
    }

    /// The other route back from a latch, and the only one `start()` owns: the tap is stopped, then
    /// asked for again. This is what makes the `reEnableBudget.restart()` at the bottom of `start()`
    /// live code rather than the same dead claim moved one call earlier -- `start()` reopens a latch only
    /// on the path that creates a tap, and only `stop()` puts it in a position to create one.
    func testStopThenStartReopensALatchedBudget() {
        let probe = TapBridgeProbe()
        probe.portCreations = 2
        let source = KeystrokeSource(handler: { _, _, _ in .swallow }, bridge: probe.bridge())
        XCTAssertTrue(source.start())
        for _ in 0..<4 { source.enableAgain() }
        XCTAssertTrue(source.reEnableBudget.hasGivenUp, "the sequence the finding is about")

        source.stop()
        XCTAssertEqual(probe.disablements, 1, "stop() switches the port off through the seam")
        XCTAssertTrue(source.start(), "a fresh tap is a fresh budget")
        XCTAssertTrue(source.isActive)
        XCTAssertFalse(source.reEnableBudget.hasGivenUp)
        XCTAssertEqual(probe.creations, 2, "start() created the second tap, as a stop/start must")

        // and usable, not merely un-latched: the disable after it is ridden out again
        source.enableAgain()
        XCTAssertTrue(source.isActive)
    }

    // MARK: - The clock the window is measured with

    /// Finding B: the budget's intervals are measured on a monotonic clock, because a `Date()` is the
    /// calendar and the calendar lies. It steps when the user changes the clock or NTP corrects a
    /// drift, and it keeps counting behind a closed lid: a Mac that sleeps for an hour wakes to find
    /// every attempt older than the window, which hands a persistently slow callback three fresh
    /// attempts every wake -- the stretched-out version of the loop round 2's latch exists to end. A
    /// clock that never moves backwards and does not tick while the machine sleeps is the only one on
    /// which "the callback had 60 seconds to prove it can keep up" means what it says.
    ///
    /// What this test can exercise is the *source*, and it does that with teeth: Apple's reference
    /// date is 2001-01-01, so calendar seconds are ~7.9e8 while the monotonic clock counts from boot.
    /// A recorded instant that sits within seconds of the calendar IS the calendar -- restoring `Date()`
    /// fails here -- and one hours-to-years below it is not. What no unit test on a live Mac can
    /// produce on demand is the hour behind a closed lid; that half of the property rests on the
    /// documented behaviour of the clock chosen, and the note says so instead of pretending.
    func testTheBudgetIsDrivenByAMonotonicClockAndNotTheCalendar() throws {
        let probe = TapBridgeProbe()
        probe.portCreations = 1
        let source = KeystrokeSource(handler: { _, _, _ in .swallow }, bridge: probe.bridge())
        XCTAssertTrue(source.start())
        source.enableAgain()
        source.enableAgain()

        let attempts = source.reEnableBudget.attempts
        XCTAssertEqual(attempts.count, 2, "two disables, two recorded instants")
        let recorded = try XCTUnwrap(attempts.last, "an attempt must record the instant it happened")
        for index in 1..<attempts.count {
            XCTAssertLessThanOrEqual(attempts[index - 1], attempts[index],
                                      "the clock never goes backwards, so an attempt can never be "
                                        + "dated in the future — which is what ages the window")
        }

        let calendar = Date().timeIntervalSinceReferenceDate
        XCTAssertGreaterThan(calendar - recorded, 3_600,
                             "the budget is reading the calendar (seconds since 2001), not a clock that "
                               + "counts from boot and pauses while the system sleeps: a clock change or "
                               + "an overnight sleep would then rewrite every window in the budget")
    }

    // MARK: - Fix round 1, finding 2: the live enabled check

    /// The menu must ask the tap API, not the cached `isActive`. This accessor answers false when no
    /// port is held -- and asking must be safe then, not a disguised `start()`. Once a port exists it
    /// reads that port through the same seam `enable` uses, so a tap macOS silently switched off is
    /// visible even while `isActive` still says true.
    func testLiveEnabledIsFalseWithoutAPortAndReadsTheHeldPortOtherwise() {
        let probe = TapBridgeProbe()
        probe.portCreations = 1
        let source = KeystrokeSource(handler: { _, _, _ in .swallow }, bridge: probe.bridge())

        XCTAssertFalse(source.isTapEnabled, "no port means no tap to ask about")
        XCTAssertEqual(probe.enabledQueries, 0,
                       "a read with no port must not reach the tap API or create one")
        XCTAssertEqual(probe.creations, 0, "reading state is not attaching")

        XCTAssertTrue(source.start())
        XCTAssertTrue(source.isTapEnabled)
        XCTAssertEqual(probe.enabledQueries, 1, "the answer must come from the held port, live")

        probe.enabled = false
        XCTAssertFalse(source.isTapEnabled,
                       "a tap that macOS silently invalidated must read false")
        XCTAssertTrue(source.isActive,
                      "the cached isActive is exactly what can lie; the live read is not")

        source.stop()
        XCTAssertFalse(source.isTapEnabled, "a stopped source holds no port to ask")
        XCTAssertEqual(probe.enabledQueries, 2,
                       "stop() drops the port, so the read must not reach the tap API again")
    }
}
