import CoreGraphics
import XCTest
@testable import UnfoldMac

final class KeyboardDecoderTests: XCTestCase {
    private func keyDown(_ unicode: [UniChar]) -> CGEvent {
        let event = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true)!
        event.keyboardSetUnicodeString(stringLength: unicode.count, unicodeString: unicode)
        return event
    }

    func testDecodesASingleCharacter() {
        XCTAssertEqual(KeyboardDecoder.character(from: keyDown(Array("a".utf16))), "a")
    }

    func testDecodesACombinedGraphemeAsOneCharacter() {
        // "é" DECOMPOSED: e + U+0301 COMBINING ACUTE ACCENT -- two UTF-16 units across two scalars,
        // yet one grapheme. A precomposed é is one unit and exercises the identical path to
        // testDecodesASingleCharacter, proving nothing about graphemes. This pins the name.
        let decomposed = Array("e\u{0301}".utf16)
        XCTAssertEqual(decomposed.count, 2, "the input must really be a two-unit combining sequence")
        XCTAssertEqual(KeyboardDecoder.character(from: keyDown(decomposed)), "e\u{0301}")
    }

    func testCharacterReturnsAMultiScalarSingleGrapheme() {
        // The ZWJ family is 5 scalars / 8 UTF-16 units but ONE Swift `Character`, so `character(from:)`
        // must return it non-nil: the matcher's vocabulary is grapheme-based, and nil here would
        // make the router treat a real keystroke as carrying nothing.
        let family = Array("👨‍👩‍👧".utf16)
        XCTAssertEqual(family.count, 8)
        XCTAssertNotNil(KeyboardDecoder.character(from: keyDown(family)))
        XCTAssertEqual(KeyboardDecoder.character(from: keyDown(family)), "👨‍👩‍👧")
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

    func testDecodesAPayloadWiderThanTheOldSixteenUnitBuffer() {
        // 👨🏻‍👩🏼‍👧🏽‍👦🏾: four skin-tone people joined by ZWJ -- 19 UTF-16 units,
        // 11 scalars, ONE grapheme. The old fixed 16-unit buffer clamped this to 16 units, cutting
        // mid-surrogate-pair of the final child and decoding to U+FFFD with no signal.
        let family = Array("👨🏻‍👩🏼‍👧🏽‍👦🏾".utf16)
        XCTAssertEqual(family.count, 19, "the payload under test must be wider than 16 units")
        XCTAssertEqual(KeyboardDecoder.characters(from: keyDown(family)), "👨🏻‍👩🏼‍👧🏽‍👦🏾")
    }

    func testRefusesAPayloadWiderThanTheHardCeilingInsteadOfTrimmingIt() {
        // 200 units is far beyond the decoder's 64-unit hard ceiling and beyond anything a real
        // layout emits per keystroke. The failure mode must be nil from both decoders -- handing
        // back a truncated prefix is the silent corruption this fix exists to remove, so the
        // truncation path must be unreachable: either the whole payload fits, or the event is refused.
        let oversize = Array(repeating: UniChar(0x61), count: 200)
        XCTAssertNil(KeyboardDecoder.characters(from: keyDown(oversize)))
        XCTAssertNil(KeyboardDecoder.character(from: keyDown(oversize)))
    }
}
