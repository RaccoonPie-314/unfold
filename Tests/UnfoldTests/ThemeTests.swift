import AppKit
import XCTest
@testable import Unfold

/// The preference is a decoded value, not a view: it must survive a garbage defaults entry by
/// falling back to the system, because a stuck Dark mode is the failure the HIG warns about.
final class ThemeTests: XCTestCase {
    /// `UserDefaults(suiteName:)` persists on every `set`, so the domains it creates are tracked and
    /// cleared in `tearDown`. Clearing only at the start of the next test leaves the previous run's files
    /// in `~/Library/Preferences` -- an artifact in the home folder that nobody asked for.
    ///
    /// Clearing turns out not to be sufficient on its own. A *named* suite writes
    /// `~/Library/Preferences/<suite>.plist`, and the preference daemon re-creates that file after the
    /// test process exits even when `removePersistentDomain` has run, so the run leaked four empty plists
    /// every time. A suite name that is an absolute path keeps the same persisted domain under a per-run
    /// directory in the temp folder, so the real preferences directory is never written at all and the
    /// run directory is the whole artifact. The domain stays genuinely persistent -- a value written by one
    /// process is read back by another -- so `read(from:)` and `write(to:)` are still exercised for real.
    private let runDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("UnfoldTests.Theme.\(UUID().uuidString)")
    private var suites: [String] = []

    private func freshDefaults(_ suffix: String) -> UserDefaults {
        try? FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
        let name = runDirectory.appendingPathComponent("UnfoldTests.Theme.\(suffix)").path
        suites.append(name)
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    override func tearDown() {
        for name in suites {
            UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
        }
        suites.removeAll()
        try? FileManager.default.removeItem(at: runDirectory)
        super.tearDown()
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

    /// The on-disk contract, pinned as a literal. A round-trip test alone stays green if the key or a
    /// raw value is renamed, and a renamed key silently breaks hand-edited defaults and the toolbar
    /// control that writes it later.
    func testPersistedContractIsPinned() {
        XCTAssertEqual(UserDefaults.unfoldAppearanceKey, "unfold.appearancePreference")
        XCTAssertEqual(AppearancePreference.allCases.map(\.rawValue), ["system", "light", "dark"],
                       "Match System first, because it is the default the menu must keep reachable")
    }

    func testAppearanceNameMapping() {
        XCTAssertEqual(AppearancePreference.system.appearanceName, nil)
        XCTAssertEqual(AppearancePreference.light.appearanceName, .aqua)
        XCTAssertEqual(AppearancePreference.dark.appearanceName, .darkAqua)
        XCTAssertEqual(AppearancePreference.allCases.count, 3,
                       "Match System must stay reachable from the same control")
    }

    /// `apply()` is the only part of this type with a runtime effect, so it is asserted rather than
    /// read. `NSApp` only exists once the shared application has been created.
    func testApplyMovesTheAppAppearance() {
        _ = NSApplication.shared
        AppearancePreference.dark.apply()
        XCTAssertEqual(NSApp.appearance?.name, .darkAqua)
        AppearancePreference.light.apply()
        XCTAssertEqual(NSApp.appearance?.name, .aqua)
        AppearancePreference.system.apply()
        XCTAssertNil(NSApp.appearance, "Match System must leave the app tracking the system")
    }
}
