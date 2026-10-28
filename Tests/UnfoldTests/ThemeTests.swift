import AppKit
import XCTest
@testable import Unfold

/// The preference is a decoded value, not a view: it must survive a garbage defaults entry by
/// falling back to the system, because a stuck Dark mode is the failure the HIG warns about.
final class ThemeTests: XCTestCase {
    private func freshDefaults(_ suffix: String) -> UserDefaults {
        let defaults = UserDefaults(suiteName: "ThemeTests.\(suffix)")!
        defaults.removePersistentDomain(forName: "ThemeTests.\(suffix)")
        return defaults
    }

    func testMissingValueMeansMatchSystem() {
        XCTAssertEqual(AppearancePreference.read(from: freshDefaults("missing")), .system)
    }

    func testUnknownValueMeansMatchSystem() {
        let defaults = freshDefaults("unknown")
        defaults.set("graphite", forKey: UserDefaults.unfoldAppearanceKey)
        XCTAssertEqual(AppearancePreference.read(from: defaults), .system,
                       "an unreadable preference must not strand the app in a fixed appearance")
    }

    func testRoundTripThroughDefaults() {
        for preference in AppearancePreference.allCases {
            let defaults = freshDefaults("roundtrip-\(preference.rawValue)")
            preference.write(to: defaults)
            XCTAssertEqual(AppearancePreference.read(from: defaults), preference)
        }
    }

    func testOnlySystemLeavesTheAppAppearanceUnset() {
        XCTAssertEqual(AppearancePreference.system.appearanceName, nil)
        XCTAssertEqual(AppearancePreference.light.appearanceName, .aqua)
        XCTAssertEqual(AppearancePreference.dark.appearanceName, .darkAqua)
        XCTAssertEqual(AppearancePreference.allCases.count, 3,
                       "Match System must stay reachable from the same control")
    }
}
