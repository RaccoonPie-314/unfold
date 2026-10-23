import CoreGraphics
import XCTest
@testable import UnfoldMac

final class KeystrokeSourceTests: XCTestCase {
    // This SDK spells membership as a bit test on CGEventMask (a UInt64); `mask.contains(.keyDown)`
    // does not compile. The plan says the compiler decides the spelling -- this is the same assertion.
    private func maskContains(_ mask: CGEventMask, _ type: CGEventType) -> Bool {
        mask & (CGEventMask(1) << type.rawValue) != 0
    }

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
        // The plan sketched this with an arrow key's empty payload, but this SDK refuses to
        // construct one: a synthetic CGEvent with no settable empty payload falls back to the
        // layout's U+001C stand-in for unmapped keys (probed: a zero-length
        // keyboardSetUnicodeString still reads back as U+001C), which decodes as a character.
        // A multi-scalar payload -- what a ligature layout emits for one keystroke -- is the
        // provably-undecodable arrangement Task 3 already pins in KeyboardDecoderTests. Whether
        // real tapped arrow events carry an empty payload or U+001C is a Task 7 live question.
        let ligature = CGEvent(keyboardEventSource: nil, virtualKey: 123, keyDown: true)!
        let payload = Array("fi".utf16)
        ligature.keyboardSetUnicodeString(stringLength: payload.count, unicodeString: payload)
        XCTAssertEqual(KeystrokeSource.route(into: ligature, type: .keyDown), .other)
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
