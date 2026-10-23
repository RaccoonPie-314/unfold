import CoreGraphics
import XCTest
@testable import UnfoldMac

final class ModifierGateTests: XCTestCase {
    func testNoModifiersIsEligible() {
        XCTAssertTrue(ModifierGate.mayConsiderExpansion([]))
    }

    func testShiftAndCapsLockAreEligibleBecauseTheyOnlyChangeTheCharacter() {
        XCTAssertTrue(ModifierGate.mayConsiderExpansion(.maskShift))
        // maskAlphaShift is the Caps Lock flag (NX_ALPHASHIFTMASK).
        XCTAssertTrue(ModifierGate.mayConsiderExpansion(.maskAlphaShift))
        XCTAssertTrue(ModifierGate.mayConsiderExpansion([.maskShift, .maskAlphaShift]))
    }

    func testCommandControlAndOptionAreNeverEligible() {
        XCTAssertFalse(ModifierGate.mayConsiderExpansion(.maskCommand))
        XCTAssertFalse(ModifierGate.mayConsiderExpansion(.maskControl))
        XCTAssertFalse(ModifierGate.mayConsiderExpansion(.maskAlternate))
        XCTAssertFalse(ModifierGate.mayConsiderExpansion([.maskCommand, .maskShift]),
                       "Cmd+Shift+A is a shortcut, not a trigger")
    }

    func testCharacterProducingRequiresAKeyDownWithoutBlockingModifiers() {
        XCTAssertTrue(ModifierGate.isCharacterProducing(flags: .maskShift, type: .keyDown))
        XCTAssertFalse(ModifierGate.isCharacterProducing(flags: .maskShift, type: .keyUp))
        XCTAssertFalse(ModifierGate.isCharacterProducing(flags: .maskCommand, type: .keyDown))
        XCTAssertFalse(ModifierGate.isCharacterProducing(flags: [], type: .flagsChanged))
        XCTAssertFalse(ModifierGate.isCharacterProducing(flags: [], type: .leftMouseDown))
    }
}
