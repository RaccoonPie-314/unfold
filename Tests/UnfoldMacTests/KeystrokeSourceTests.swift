import CoreGraphics
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

}
