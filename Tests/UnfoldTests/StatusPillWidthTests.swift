import AppKit
import UnfoldEngine
import UnfoldMac
import XCTest
@testable import Unfold

/// The status pill is one fixed box, measured across all seven `MenuStatus` states.
///
/// The user's words on 2026-10-29: *"the status 'Ready and paused' i want it a fixed size without
/// changing when toggling it."* The shell answers that with a reservation -- the label is pinned to the
/// widest `shortText` rendered in the pill's own font (`MainWindowController.statusLabelFont`) -- and
/// deletes the pill-width transition, whose entire subject was the width change that may now
/// never happen. This file asserts the property directly rather than the animation that used to hide it:
///
/// 1. **Fitting size is identical for every state.** The pill's wrapped glass view resolves to the
///    same `NSSize` whichever status is rendered into it -- the measurable half of "fixed size".
/// 2. **The laid-out toolbar frame does not move either.** Rewriting the label and glyph on the real
///    item, with a display pass between states, leaves `pill.frame.width` unchanged to 0.01 pt -- the
///    reservation works through AppKit's own toolbar sizing, not just inside the view.
/// 3. **Nothing animates the swap.** After the transition's removal the pill's layer and its toolbar
///    viewer hold no `unfold.morph` (or any other) animation across a state change; the swap is a
///    plain image-and-text replacement. (The glyph half was measured before deciding not to animate
///    it: all seven symbols render 15 pt wide at the pill's symbol size, so no replacement animation
///    could move the pill even if this SDK's AppKit offered one -- its headers do not.)
///
/// Mutation-proven where the property is actually discriminating: deleting the `widthAnchor`
/// reservation in `buildStatusItem` moves the laid-out pill between 65 pt and 98 pt across states and
/// test 2 fails on several of them. Test 1 (fitting size) passes both ways -- measured on this machine
/// `NSGlassEffectView`'s own `fittingSize` does not track the label's intrinsic width -- so it records
/// the contract the task demands ("the pill's fitting size must be identical for every state") while
/// test 2 is the one that can fail.
final class StatusPillWidthTests: XCTestCase {
    private let morphKey = "unfold.morph"

    @MainActor
    func testThePillFittingSizeIsIdenticalAcrossAllSevenStates() throws {
        let controller = try makeController()
        defer { controller.window?.orderOut(nil) }
        let (pill, label, symbol) = try pillParts(controller)

        var sizes: [MenuStatus: NSSize] = [:]
        for status in MenuStatus.allPillStates {
            render(status, into: label, symbol: symbol)
            sizes[status] = pill.fittingSize
        }
        let reference = try XCTUnwrap(sizes[.listening], "the enum lost its listening case")
        let report = sizes.map { "\($0.key): \($0.value)" }.joined(separator: "\n")
        print("status pill fitting sizes:\n\(report)")
        NSLog("status pill fitting sizes: %@", sizes.description)

        XCTAssertEqual(sizes.count, MenuStatus.allPillStates.count,
                       "a status collapsed onto another in the dictionary — duplicate shortTexts must "
                           + "still each be measured")
        for (status, size) in sizes {
            XCTAssertEqual(size, reference,
                           "the pill changes size between states (\(status) = \(size), reference "
                               + "\(reference)) — the width reservation is gone:\n\(report)")
        }
    }

    @MainActor
    func testTheLaidOutPillWidthDoesNotMoveAcrossStateChanges() throws {
        let controller = try makeController()
        defer { controller.window?.orderOut(nil) }
        let (pill, label, symbol) = try pillParts(controller)

        var widths: [MenuStatus: CGFloat] = [:]
        var alienHolders: [String] = []
        for status in MenuStatus.allPillStates {
            let before = pill.frame
            render(status, into: label, symbol: symbol)
            // A display pass per state -- the toolbar re-measures the wrapped view on its own clock,
            // the same one the deleted pill-motion test measured once.
            drain(0.12) { _ in
                for (name, view) in [("pill", pill), ("viewer", pill.superview)] {
                    let keys = view?.layer?.animationKeys() ?? []
                    if !keys.isEmpty { alienHolders.append("\(name): \(keys)") }
                }
            }
            widths[status] = pill.frame.width
            _ = before
        }
        let report = widths.map { "\($0.key): \(String(format: "%.2f", $0.value)) pt" }
            .joined(separator: "\n")
        print("status pill laid-out widths:\n\(report)")

        let listening = try XCTUnwrap(widths[.listening])
        for (status, width) in widths {
            XCTAssertEqual(width, listening, accuracy: 0.01,
                           "toggling to \(status) moved the pill on screen (\(width) pt vs "
                               + "\(listening) pt) — exactly the jump the user rejected:\n\(report)")
        }
        XCTAssertTrue(alienHolders.isEmpty,
                      "something animates the pill or the toolbar item viewer during a state change "
                          + "(\(alienHolders)) — the width motion was deleted with its transition, and "
                          + "a fixed pill gives any such animation nothing to say")
    }

    // MARK: - fixture

    /// The pill and the two visible parts, read off the real toolbar item. Same route the deleted
    /// motion test used; the reservation is only worth measuring on the assembled item.
    @MainActor
    private func pillParts(_ controller: MainWindowController) throws
        -> (pill: NSView, label: NSTextField, symbol: NSImageView) {
        let pill = try XCTUnwrap(controller.statusPill,
                                 "the status item exposes no wrapped view to measure")
        let glass = try XCTUnwrap(pill as? NSGlassEffectView,
                                  "the pill view is \(Swift.type(of: pill)), not the glass surface the "
                                      + "toolbar item wraps")
        let stack = try XCTUnwrap(glass.contentView as? NSStackView,
                                  "the pill's content view is not the stack `Glass.wrap` was handed")
        let label = try XCTUnwrap(stack.arrangedSubviews.compactMap { $0 as? NSTextField }.first)
        let symbol = try XCTUnwrap(stack.arrangedSubviews.compactMap { $0 as? NSImageView }.first)
        return (pill, label, symbol)
    }

    /// What `refreshStatus` renders for one state: the `shortText` and the symbol, through the same
    /// views. The controller's own tick cannot overwrite this mid-test: the fixture's real status
    /// never changes, and the memo skips every unchanged second.
    @MainActor
    private func render(_ status: MenuStatus, into label: NSTextField, symbol: NSImageView) {
        label.stringValue = status.shortText
        symbol.image = NSImage(systemSymbolName: status.symbolName, accessibilityDescription: status.text)
    }

    /// A real `MainWindowController` over a scratch store in a temporary directory, its window
    /// ordered front off the corner of any plausible display (on-screen-ness, not position, is what
    /// gates AppKit laying the toolbar out), with a few run-loop turns for the toolbar to place its
    /// items. The coordinator is built untrusted, so no tap is ever attached and nothing is typed.
    @MainActor
    private func makeController() throws -> MainWindowController {
        _ = NSApplication.shared
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("unfold-status-pill-\(UUID().uuidString)", isDirectory: true)
        let store = Store(url: directory.appendingPathComponent("combos.json"))
        let combos = [
            Combo(id: UUID(), trigger: "sig", label: "", enabled: true,
                  parts: [.text("Sent from my iPhone")], insertion: .paste)
        ]
        try store.save(CombosFile(formatVersion: CombosFile.currentFormatVersion, combos: combos))

        let coordinator = ExpansionCoordinator(combos: combos)
        let controller = MainWindowController(coordinator: coordinator, store: store)
        let window = try XCTUnwrap(controller.window)
        window.setFrameOrigin(NSPoint(x: -3_200, y: -1_800))
        window.orderFrontRegardless()
        drain(0.15)
        return controller
    }

    /// Advances the main run loop to `seconds` from now, calling `check` on every pass (~5 ms) -- the
    /// same reason `MotionDriverTests` gives: XCTest's own wait loop does not let AppKit or Core
    /// Animation finish a scheduled pass.
    @MainActor
    private func drain(_ seconds: TimeInterval, check: (Date) -> Void = { _ in }) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            let slice = min(deadline, Date().addingTimeInterval(0.005))
            RunLoop.main.run(until: slice)
            check(Date())
        }
    }
}
