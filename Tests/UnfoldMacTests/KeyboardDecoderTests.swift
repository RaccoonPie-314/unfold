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
