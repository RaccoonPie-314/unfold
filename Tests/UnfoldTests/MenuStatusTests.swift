import UnfoldMac
import XCTest
@testable import Unfold

/// The status line is the only place the menu says *why* expansion is not happening. These tests
/// pin the decision as a pure function: no status item, no tap, no permission prompt.
final class MenuStatusTests: XCTestCase {
    private let everyTapState: [ExpansionCoordinator.TapState] = [.detached, .live, .disabled, .givenUp]

    func testUntrustedOutranksEveryOtherState() {
        for paused in [true, false] {
            for tapState in everyTapState {
                XCTAssertEqual(
                    MenuStatus.evaluate(isTrusted: false, isPaused: paused, tapState: tapState),
                    .notPermitted,
                    "untrusted must be reported even when paused=\(paused), tapState=\(tapState)"
                )
            }
        }
        XCTAssertEqual(MenuStatus.notPermitted.text,
                       "Not permitted — allow Accessibility in Settings")
    }

    func testPausedIsReportedOncePermissionExists() {
        for tapState in everyTapState {
            XCTAssertEqual(
                MenuStatus.evaluate(isTrusted: true, isPaused: true, tapState: tapState),
                .paused,
                "the user's own pause must be reported for tapState=\(tapState)"
            )
        }
        XCTAssertEqual(MenuStatus.paused.text, "Paused")
    }

    func testOnlyALiveUnpausedTrustedTapReportsListening() {
        XCTAssertEqual(
            MenuStatus.evaluate(isTrusted: true, isPaused: false, tapState: .live),
            .listening
        )
        XCTAssertEqual(MenuStatus.listening.text, "Listening")

        for tapState in everyTapState where tapState != .live {
            let status = MenuStatus.evaluate(isTrusted: true, isPaused: false, tapState: tapState)
            XCTAssertNotEqual(status.text, "Listening",
                              "tapState=\(tapState) must not masquerade as a working tap")
        }
        XCTAssertNotEqual(
            MenuStatus.evaluate(isTrusted: false, isPaused: false, tapState: .live).text,
            "Listening"
        )
        XCTAssertNotEqual(
            MenuStatus.evaluate(isTrusted: true, isPaused: true, tapState: .live).text,
            "Listening"
        )
    }

    func testGivenUpSaysStoppedAndHowToRecover() {
        let status = MenuStatus.evaluate(isTrusted: true, isPaused: false, tapState: .givenUp)

        XCTAssertEqual(status, .tapGivenUp)
        XCTAssertEqual(status.text, "Stopped — macOS disabled the tap; choose Pause, then Resume")
    }

    func testDisabledSaysInterruptedRatherThanListening() {
        let status = MenuStatus.evaluate(isTrusted: true, isPaused: false, tapState: .disabled)

        XCTAssertEqual(status, .tapInterrupted)
        XCTAssertEqual(status.text, "Interrupted — the tap is off; choose Pause, then Resume")
    }

    func testDetachedSaysOffRatherThanListening() {
        let status = MenuStatus.evaluate(isTrusted: true, isPaused: false, tapState: .detached)

        XCTAssertEqual(status, .tapDetached)
        XCTAssertEqual(status.text, "Off — keyboard access is not attached")
    }
}
