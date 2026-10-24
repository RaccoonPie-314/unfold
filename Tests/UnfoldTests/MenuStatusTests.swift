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
                for isTapEnabled in [true, false] {
                    XCTAssertEqual(
                        MenuStatus.evaluate(isTrusted: false, isPaused: paused, tapState: tapState,
                                            isTapEnabled: isTapEnabled),
                        .notPermitted,
                        "untrusted must be reported even when paused=\(paused), "
                            + "tapState=\(tapState), isTapEnabled=\(isTapEnabled)"
                    )
                }
            }
        }
        XCTAssertEqual(MenuStatus.notPermitted.text,
                       "Not permitted — allow Accessibility in Settings")
    }

    func testPausedIsReportedOncePermissionExists() {
        for tapState in everyTapState {
            for isTapEnabled in [true, false] {
                XCTAssertEqual(
                    MenuStatus.evaluate(isTrusted: true, isPaused: true, tapState: tapState,
                                        isTapEnabled: isTapEnabled),
                    .paused,
                    "the user's own pause must be reported for tapState=\(tapState), "
                        + "isTapEnabled=\(isTapEnabled)"
                )
            }
        }
        XCTAssertEqual(MenuStatus.paused.text, "Paused")
    }

    func testOnlyALiveUnpausedTrustedTapReportsListening() {
        XCTAssertEqual(
            MenuStatus.evaluate(isTrusted: true, isPaused: false, tapState: .live,
                                isTapEnabled: true),
            .listening
        )
        XCTAssertEqual(MenuStatus.listening.text, "Listening")

        for tapState in everyTapState where tapState != .live {
            let status = MenuStatus.evaluate(isTrusted: true, isPaused: false, tapState: tapState,
                                             isTapEnabled: true)
            XCTAssertNotEqual(status.text, "Listening",
                              "tapState=\(tapState) must not masquerade as a working tap")
        }
        XCTAssertNotEqual(
            MenuStatus.evaluate(isTrusted: false, isPaused: false, tapState: .live,
                                isTapEnabled: true).text,
            "Listening"
        )
        XCTAssertNotEqual(
            MenuStatus.evaluate(isTrusted: true, isPaused: true, tapState: .live,
                                isTapEnabled: true).text,
            "Listening"
        )
    }

    func testGivenUpSaysStoppedAndHowToRecover() {
        let status = MenuStatus.evaluate(isTrusted: true, isPaused: false, tapState: .givenUp,
                                         isTapEnabled: true)

        XCTAssertEqual(status, .tapGivenUp)
        XCTAssertEqual(status.text, "Stopped — macOS disabled the tap; choose Pause, then Resume")
    }

    func testDisabledSaysInterruptedRatherThanListening() {
        let status = MenuStatus.evaluate(isTrusted: true, isPaused: false, tapState: .disabled,
                                         isTapEnabled: true)

        XCTAssertEqual(status, .tapInterrupted)
        XCTAssertEqual(status.text, "Interrupted — the tap is off; choose Pause, then Resume")
    }

    func testDetachedSaysOffRatherThanListening() {
        let status = MenuStatus.evaluate(isTrusted: true, isPaused: false, tapState: .detached,
                                         isTapEnabled: true)

        XCTAssertEqual(status, .tapDetached)
        XCTAssertEqual(status.text,
                       "Off — keyboard access is not attached; choose Pause, then Resume")
    }

    // MARK: - Fix round 1, finding 2: "Listening" may not rest on a cached isActive

    /// The missing state. A tap can be attached, trusted, unpaused and *not receiving*: Secure Input,
    /// a password field, or a tap macOS silently invalidated. `CGEvent.tapIsEnabled` is the live
    /// answer, and when it is false the line must never say "Listening" on the cached value alone.
    func testATrustedLiveTapThatIsNotEnabledSaysItIsNotReceiving() {
        let status = MenuStatus.evaluate(isTrusted: true, isPaused: false, tapState: .live,
                                         isTapEnabled: false)

        XCTAssertEqual(status, .notReceivingKeystrokes)
        XCTAssertEqual(status.text,
                       "not receiving keystrokes — a password field or Secure Input can block expansion")
        XCTAssertNotEqual(status.text, "Listening",
                          "a cached isActive may not render Listening when the live check says off")
    }

    /// The live check wins over every attached tap state, `.live` included. A cached `.disabled` whose
    /// port actually recovered is the one case where the interrupted text remains appropriate -- but a
    /// dead port is not a working tap, whichever cached state claims it.
    func testNotReceivingOutranksEveryAttachedTapState() {
        for tapState in [ExpansionCoordinator.TapState.live, .disabled] {
            XCTAssertEqual(
                MenuStatus.evaluate(isTrusted: true, isPaused: false, tapState: tapState,
                                    isTapEnabled: false),
                .notReceivingKeystrokes,
                "tapState=\(tapState) with a live check of false must not claim to receive keys"
            )
        }
    }

    /// The new state is a last word about a tap that exists. Every earlier precedence still applies:
    /// no permission, an explicit pause, a given-up budget, and a detached tap each name their own
    /// reason even though the live check is false in all four.
    func testNotReceivingDoesNotOverrideTheStatesThatOutrankIt() {
        XCTAssertEqual(
            MenuStatus.evaluate(isTrusted: false, isPaused: false, tapState: .live,
                                isTapEnabled: false),
            .notPermitted
        )
        XCTAssertEqual(
            MenuStatus.evaluate(isTrusted: true, isPaused: true, tapState: .live,
                                isTapEnabled: false),
            .paused
        )
        XCTAssertEqual(
            MenuStatus.evaluate(isTrusted: true, isPaused: false, tapState: .givenUp,
                                isTapEnabled: false),
            .tapGivenUp
        )
        XCTAssertEqual(
            MenuStatus.evaluate(isTrusted: true, isPaused: false, tapState: .detached,
                                isTapEnabled: false),
            .tapDetached
        )
    }
}
