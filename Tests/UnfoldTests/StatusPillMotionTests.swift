import AppKit
import UnfoldEngine
import UnfoldMac
import XCTest
@testable import Unfold

/// Ruling AJ7, measured in-process: `statusMorph` runs on the toolbar item's **wrapped view** -- the glass
/// surface AppKit's toolbar layout sizes -- and not on the `NSStackView` inside it, which is that glass
/// view's own `contentView`.
///
/// Three measurements on the real controller window, in the same offscreen-but-ordered-front technique
/// `MotionDriverTests` uses, plus one sampled ramp behind the render-cycle skip every motion test in
/// this suite already carries:
///
/// 1. **The target is the item view.** `MainWindowController.statusPill` is the `NSGlassEffectView` the
///    toolbar item wraps, and the symbol+label stack is its `contentView`. One object therefore carries the
///    material and the content.
/// 2. **One clock, measured rather than argued.** Rewriting the pill's label re-measures the item view from
///    71 pt to 263 pt in a single layout pass, and the frame is already final at the first ~5 ms poll and
///    never moves again for the next half second, with **no** animation installed on the pill's layer or on
///    the `NSToolbarItemViewer` above it. So AppKit's own toolbar layout does not spring the box on a second
///    clock while the content springs on ours -- the transform `Motion.morph` installs is the only animation
///    in the tree, which is what the spec's rule 4 requires of a control the system already lays out.
///    The content stack grows by the same 192 pt in the same pass, so nothing travels separately.
/// 3. **The motion is a width change.** Morphing the pill from its previous frame onto its final one
///    interpolates the *rendered* width across the ramp with `scale.y` pinned at 1.000 -- the pill's width
///    springing, not the row-style vertical grow a zero-height gap would give.
///
/// The label is rewritten directly rather than through `refreshStatus()`, which is private: the fact under
/// test is which view the toolbar re-measures and what a morph of that view paints, and both are true of
/// any path that changes the pill's text. The status itself does not change during the test, so the
/// controller's one-second tick cannot rewrite the label under it (`refreshStatus` skips the pill when the
/// status is unchanged).
final class StatusPillMotionTests: XCTestCase {
    private let morphKey = "unfold.morph"

    @MainActor
    func testTheMorphTargetIsTheToolbarItemsWrappedViewAndTheToolbarReMeasuresItOnOneClock() throws {
        let controller = try makeController()
        defer { controller.window?.orderOut(nil) }

        let pill = try XCTUnwrap(controller.statusPill,
                                 "the status item exposes no wrapped view to morph")
        let glass = try XCTUnwrap(pill as? NSGlassEffectView,
                                  "the pill view is \(Swift.type(of: pill)), not the glass surface the "
                                      + "toolbar item wraps — the morph target moved off Ruling AJ7")
        let content = try XCTUnwrap(glass.contentView,
                                    "the glass view hosts no content view, so material and content cannot "
                                        + "be the same object's two halves")
        let label = try XCTUnwrap(content.subviews.compactMap { $0 as? NSTextField }.first,
                                  "no label inside the pill's content stack")
        let stack = try XCTUnwrap(content as? NSStackView,
                                  "the pill's content view is \(Swift.type(of: content)), not the stack "
                                      + "`Glass.wrap` was handed")

        let beforePill = pill.frame
        let beforeContent = stack.frame
        XCTAssertGreaterThan(beforePill.width, 0, "the toolbar never laid the pill out: \(beforePill)")

        label.stringValue = "A much longer status sentence than the pill started with"
        var polls = 0
        var alienHolders: [String] = []
        var widest = beforePill.width
        let started = Date()
        drain(from: started, until: started.addingTimeInterval(0.5)) { now in
            polls += 1
            widest = max(widest, pill.frame.width)
            // "One clock" is a claim about the *tree*, not about the number: nothing may hold an animation
            // on either the pill or the toolbar's own item viewer while the layout lands.
            for (name, view) in [("pill", pill), ("viewer", pill.superview)] {
                let keys = view?.layer?.animationKeys() ?? []
                if !keys.isEmpty { alienHolders.append("t=\(Int(now.timeIntervalSince(started) * 1000))ms "
                                                       + "\(name): \(keys)") }
            }
        }
        let finalPill = pill.frame
        let finalContent = stack.frame

        let report = "pill \(beforePill) → \(finalPill) (Δx \(finalPill.width - beforePill.width) pt) "
            + "content \(beforeContent) → \(finalContent) "
            + "(Δx \(finalContent.width - beforeContent.width) pt) in \(polls) polls, "
            + "viewer=\(String(describing: pill.superview.map { Swift.type(of: $0) })), "
            + "alienHolders=\(alienHolders)"
        print("status pill re-measurement:\n\(report)")
        NSLog("status pill remeasure: %@", report)

        // 1 + 2: the wrapped view is the one the toolbar sizes, it changes by the same amount as its own
        // content, and no AppKit animation rides along with the layout pass.
        XCTAssertGreaterThan(finalPill.width, beforePill.width,
                             "the toolbar did not re-measure the item view at all (\(report)), so this "
                                 + "fixture cannot say which view carries the pill's width")
        XCTAssertEqual(finalPill.width - beforePill.width, finalContent.width - beforeContent.width,
                       accuracy: 1.0,
                       "the pill and its content grew by different amounts, so they are not one object's "
                           + "two halves (\(report))")
        XCTAssertTrue(alienHolders.isEmpty,
                      "something animated the pill or the toolbar item viewer while the width changed "
                          + "(\(report)) — two clocks, which is the defect Ruling AJ7 names")
        XCTAssertEqual(widest, finalPill.width, accuracy: 1.0,
                       "the frame arrived at its final width gradually (\(report)), so the layout itself "
                           + "is animating and the morph would be riding a second transition")

        // 3: the morph on that view is a width change. The animation must attach before any hope about the
        // render cycle (`MotionDriverTests`' discipline: a skip may only mean "no render cycle").
        let transition = try XCTUnwrap(MotionPlan.lookup(.statusMorph))
        Motion.morph(pill, source: beforePill, transition: transition)
        XCTAssertTrue(pill.layer?.animationKeys()?.contains(morphKey) == true,
                      "no \(morphKey) animation on the pill view after morphing it from \(beforePill) "
                          + "onto \(pill.frame): the driver attached nothing, which is not a render-cycle "
                          + "question")

        var readings: [(elapsed: TimeInterval, scaleX: CGFloat, scaleY: CGFloat, renderedWidth: CGFloat)] = []
        let ramp = Date()
        drain(from: ramp, until: ramp.addingTimeInterval(transition.duration + 0.20)) { now in
            guard let presentation = pill.layer?.presentation() else { return }
            let t = presentation.affineTransform()
            readings.append((now.timeIntervalSince(ramp), t.a, t.d, presentation.frame.width))
        }

        let rampReport = readings.enumerated()
            .filter { $0.offset % 4 == 0 || $0.element.elapsed > transition.duration }
            .map { String(format: "t=%.0fms scale=%.3fx%.3f renderedWidth=%.1f",
                          $0.element.elapsed * 1000, $0.element.scaleX, $0.element.scaleY,
                          $0.element.renderedWidth) }
            .joined(separator: "\n")
        print("status pill morph ramp (\(readings.count) readings):\n\(rampReport)")
        NSLog("status pill ramp: %zd readings", readings.count)

        try XCTSkipUnless(!readings.isEmpty,
                          "presentation() was nil at every poll for a morph attached under \(morphKey): "
                              + "this process never entered a render cycle, so the ramp cannot be "
                              + "measured in-process. Live pass owns it.")
        let inFlight = readings.filter { $0.elapsed < transition.duration }
        let first = try XCTUnwrap(inFlight.first, "no reading fell inside the ramp")
        let last = try XCTUnwrap(inFlight.max(by: { $0.elapsed < $1.elapsed }), "no in-flight reading")
        // Which way the width moves is the status's business (a longer label grows the pill, a shorter one
        // shrinks it) and `MotionGeometry` clamps the ratio either way, so the assertions are about the
        // *x axis being the one that moves*: the pose starts well off rest, starts near the previous frame,
        // and travels toward 1 as the ramp runs.
        XCTAssertGreaterThan(abs(first.scaleX - 1), 0.3,
                             "the first in-flight reading sat at scale "
                                 + "\(String(format: "%.3f", first.scaleX))x — the width never moved "
                                 + "(see the ramp above)")
        XCTAssertLessThan(abs(last.scaleX - 1), abs(first.scaleX - 1),
                          "the ramp did not close on the x axis (first "
                              + "\(String(format: "%.3f", first.scaleX))x, last "
                              + "\(String(format: "%.3f", last.scaleX))x)")
        XCTAssertLessThan(abs(first.renderedWidth - beforePill.width),
                          abs(first.renderedWidth - finalPill.width),
                          "the pose started at \(String(format: "%.1f", first.renderedWidth)) pt, which is "
                              + "closer to the final \(finalPill.width) than to the previous "
                              + "\(beforePill.width) — it did not start on its source (\(report))")
        for reading in readings {
            XCTAssertEqual(reading.scaleY, 1, accuracy: 0.01,
                           "the pill morph scaled y at t=\(String(format: "%.0f", reading.elapsed * 1000))ms "
                               + "(\(String(format: "%.3f", reading.scaleY))): statusMorph is a width "
                               + "change, not a grow out of a gap")
        }
        for reading in readings where reading.elapsed >= transition.duration + 0.10 {
            XCTAssertEqual(reading.renderedWidth, finalPill.width, accuracy: 1.0,
                           "the ramp ended somewhere other than the pill's real frame")
        }
    }

    // MARK: - fixture

    /// A real `MainWindowController` over a scratch store in a temporary directory, its window ordered
    /// front off the corner of any plausible display (on-screen-ness, not position, is what gates AppKit
    /// laying the toolbar out), with a few run-loop turns for the toolbar to place its items. The
    /// coordinator is built untrusted, so no tap is ever attached and nothing is typed.
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
        let started = Date()
        drain(from: started, until: started.addingTimeInterval(0.15))
        return controller
    }

    /// Advances the main run loop to `deadline`, calling `check` on every pass (~5 ms) -- the same reason
    /// `MotionDriverTests` gives: XCTest's own wait loop does not let Core Animation retire a transaction.
    @MainActor
    private func drain(from start: Date, until deadline: Date, check: (Date) -> Void = { _ in }) {
        while Date() < deadline {
            let slice = min(deadline, Date().addingTimeInterval(0.005))
            RunLoop.main.run(until: slice)
            check(Date())
        }
    }
}
