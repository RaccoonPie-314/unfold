import AppKit
import UnfoldEngine
import UnfoldMac
import XCTest
@testable import Unfold

/// Task 12's control: `unfold.appearance` -- one bordered symbol item whose menu is the three choices,
/// with the stored one checked and named in the tooltip.
///
/// What is asserted here and what is not, stated plainly: the item is built through the **real delegate
/// call on a real `MainWindowController`** (the fixture technique `SelectionOverlayTests` uses), so the
/// identifier switch, the menu construction, the target wiring and the identifier lists are all the
/// production objects. What no in-process test can decide is the pixels of a live toolbar -- whether the
/// item renders, where it sits, and whether clicking it opens the menu -- and the *persist-and-apply*
/// half of selecting an entry, because `swift test` runs in the shared `com.apple.dt.xctest.tool`
/// defaults domain (measured: `Bundle.main.bundleIdentifier`), so a test that called `write()` would
/// strand an appearance override in a domain this repo does not own. Those are the plan's checklist
/// items, not tests that assert nothing.
final class AppearanceToolbarTests: XCTestCase {
    /// The identifier as a literal, same discipline as `SelectionOverlayTests.morphKey` and
    /// `ThemeTests.testPersistedContractIsPinned`: renaming it in production has to fail here.
    private static let appearance = NSToolbarItem.Identifier("unfold.appearance")
    private static let pause = NSToolbarItem.Identifier("unfold.pause")
    private static let status = NSToolbarItem.Identifier("unfold.status")

    // MARK: - the item

    @MainActor
    func testTheAppearanceItemOpensThreeChoicesInOrder() throws {
        let controller = try makeController()
        defer { controller.window?.orderOut(nil) }
        let item = try appearanceItem(for: controller)

        XCTAssertEqual(item.label, "Appearance")
        XCTAssertEqual(item.paletteLabel, "Appearance", "the Customize Toolbar palette says what the item is")
        XCTAssertTrue(item.isBordered, "a symbol item that is not bordered reads as decoration, not a control")
        XCTAssertTrue(item is NSMenuToolbarItem,
                      "an item that opens a menu has to be an NSMenuToolbarItem — the SDK's NSToolbarItem "
                          + "has no `menu` property (measured: the plan's snippet does not compile)")
        let menu = try XCTUnwrap((item as? NSMenuToolbarItem)?.menu)
        XCTAssertEqual(menu.items.map(\.title), ["Match System", "Light", "Dark"],
                       "Match System first and reachable, because the failure mode of an in-app switch "
                           + "is getting stuck in it")

        // The symbol, pinned by what it draws rather than by a name property AppKit does not expose:
        // measured, `tiffRepresentation` is equal for two images made from the same symbol name and
        // different for two made from different names, and it ignores the accessibility description.
        XCTAssertNotNil(item.image, "a symbol name the OS cannot resolve leaves the control blank")
        XCTAssertEqual(item.image?.accessibilityDescription, "Appearance")
        XCTAssertEqual(item.image?.tiffRepresentation,
                       NSImage(systemSymbolName: "circle.lefthalf.filled",
                               accessibilityDescription: nil)?.tiffRepresentation,
                       "the item's glyph must be circle.lefthalf.filled")
    }

    @MainActor
    func testEachEntryCarriesADecodablePreferenceAndAWiredAction() throws {
        let controller = try makeController()
        defer { controller.window?.orderOut(nil) }
        let menu = try XCTUnwrap((appearanceItem(for: controller) as? NSMenuToolbarItem)?.menu)

        XCTAssertEqual(menu.items.count, AppearancePreference.allCases.count,
                       "one entry per case, in `allCases` order")
        for (index, preference) in AppearancePreference.allCases.enumerated() {
            let entry = menu.items[index]
            XCTAssertEqual(entry.title, preference.menuTitle)
            let raw = try XCTUnwrap(entry.representedObject as? String,
                                    "entry \(index) carries no string to decode")
            XCTAssertEqual(raw, preference.rawValue)
            XCTAssertEqual(AppearancePreference(rawValue: raw), preference,
                           "a representedObject that will not decode is a menu item that does nothing")
            XCTAssertNotNil(entry.action, "\(entry.title) has no action — the entry would be inert")
            XCTAssertTrue(entry.target === controller, "\(entry.title) does not target the controller")
            XCTAssertEqual(entry.keyEquivalent, "",
                           "no keyboard shortcut was asked for, and ⌘-keying an appearance is how a "
                               + "person ends up stuck in it")
        }
    }

    // MARK: - the stored preference is what the menu shows

    @MainActor
    func testTheCheckedEntryIsTheStoredPreference() throws {
        // The seam covers all three values; the domain the production path reads is not this test's to
        // write (see the header), so the loop passes the preference in instead of storing it.
        for preference in AppearancePreference.allCases {
            let controller = try makeController()
            defer { controller.window?.orderOut(nil) }
            let built = controller.appearanceMenu(current: preference)
            let on = built.items.enumerated().filter { $0.element.state == .on }.map(\.offset)
            XCTAssertEqual(on, [AppearancePreference.allCases.firstIndex(of: preference)!],
                           "\(preference.rawValue) stored must check exactly its own entry, got "
                               + "\(built.items.map { "\($0.title):\($0.state == .on ? "on" : "off")" })")
            XCTAssertEqual(built.items.filter { $0.state == .on }.count, 1)
            XCTAssertEqual(built.items.filter { $0.state == .off }.count, 2)
        }

        // And the production path: the item the toolbar actually builds reads the stored preference.
        let controller = try makeController()
        defer { controller.window?.orderOut(nil) }
        let item = try appearanceItem(for: controller)
        let menu = try XCTUnwrap((item as? NSMenuToolbarItem)?.menu)
        let stored = AppearancePreference.read()
        let checked = try XCTUnwrap(menu.items.first { $0.state == .on },
                                    "the built item checks nothing, so it cannot show which choice is in force")
        XCTAssertEqual(AppearancePreference(rawValue: checked.representedObject as? String ?? ""), stored,
                       "the checked entry must be the stored preference, whichever it is")
        XCTAssertEqual(item.toolTip, stored.tooltip)
    }

    @MainActor
    func testTheToolTipAndMenuTitlesAreTheContractTheUserReads() {
        XCTAssertEqual(AppearancePreference.allCases.map(\.menuTitle), ["Match System", "Light", "Dark"])
        XCTAssertEqual(AppearancePreference.allCases.map(\.tooltip),
                       ["Appearance — Match System", "Appearance — Light", "Appearance — Dark"])
    }

    // MARK: - selecting an entry

    @MainActor
    func testSelectingRePointsTheCheckmarkWithoutRebuildingTheMenu() throws {
        let controller = try makeController()
        defer { controller.window?.orderOut(nil) }
        let item = try appearanceItem(for: controller)
        let menu = try XCTUnwrap((item as? NSMenuToolbarItem)?.menu)
        let chosen = try XCTUnwrap(menu.items.first { $0.title == "Dark" })
        let identitiesBefore = menu.items.map { ObjectIdentifier($0) }

        controller.refreshAppearanceSelection(chosen, preference: .dark)

        XCTAssertEqual(menu.items.map { ObjectIdentifier($0) }, identitiesBefore,
                       "the entries were swapped out — a menu that is already open would be rebuilt "
                           + "from under the pointer instead of having its checkmarks re-pointed")
        XCTAssertEqual(chosen.state, .on)
        XCTAssertEqual(menu.items.filter { $0.state == .on }.count, 1, "two entries checked at once")
        XCTAssertEqual(item.toolTip, "Appearance — Dark", "the tooltip must name the choice just made")
    }

    // MARK: - the identifier lists

    @MainActor
    func testTheItemIsInTheDefaultAndAllowedIdentifierLists() throws {
        let controller = try makeController()
        defer { controller.window?.orderOut(nil) }
        let toolbar = try XCTUnwrap(controller.window?.toolbar)
        let defaults = controller.toolbarDefaultItemIdentifiers(toolbar)
        let allowed = controller.toolbarAllowedItemIdentifiers(toolbar)

        XCTAssertTrue(defaults.contains(Self.appearance), "not in the default set: nobody would ever see it")
        XCTAssertTrue(allowed.contains(Self.appearance),
                      "not allowed: the item cannot come back after Customize Toolbar removed it")
        let index = try XCTUnwrap(defaults.firstIndex(of: Self.appearance))
        XCTAssertGreaterThan(index, 0, "the first item is a system identifier; the control is not it")
        XCTAssertEqual(defaults[index - 1], Self.pause,
                       "the plan puts it after Pause, and the toolbar's left-to-right order is what the "
                           + "user reads")
        XCTAssertNotNil(defaults.firstIndex(of: Self.status), "the pill is still there either way")
    }

    // MARK: - fixtures

    private func appearanceItem(for controller: MainWindowController) throws -> NSToolbarItem {
        let toolbar = try XCTUnwrap(controller.window?.toolbar)
        return try XCTUnwrap(controller.toolbar(toolbar, itemForItemIdentifier: Self.appearance,
                                               willBeInsertedIntoToolbar: true),
                             "the delegate returns nil for \(Self.appearance.rawValue) — the toolbar "
                                 + "would show an empty gap where the control should be")
    }

    /// A real controller over a scratch store in a temporary directory, window ordered front off the
    /// corner of any display -- copied from `SelectionOverlayTests`, including why nothing at the keyboard
    /// layer moves: the coordinator is built untrusted, so no tap is ever attached.
    @MainActor
    private func makeController() throws -> MainWindowController {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("unfold-appearance-toolbar-\(UUID().uuidString)", isDirectory: true)
        let store = Store(url: directory.appendingPathComponent("combos.json"))
        let combos = [
            Combo(id: UUID(), trigger: "sig", label: "", enabled: true,
                  parts: [.text("Sent from my iPhone")], insertion: .paste),
            Combo(id: UUID(), trigger: "addr", label: "", enabled: true,
                  parts: [.text("1 Main Street")], insertion: .paste),
        ]
        try store.save(CombosFile(formatVersion: CombosFile.currentFormatVersion, combos: combos))
        let coordinator = ExpansionCoordinator(combos: combos)
        let controller = MainWindowController(coordinator: coordinator, store: store)
        let window = try XCTUnwrap(controller.window)
        window.setFrameOrigin(NSPoint(x: -3_200, y: -1_800))
        window.orderFrontRegardless()
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        return controller
    }
}
