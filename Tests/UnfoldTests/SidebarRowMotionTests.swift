import AppKit
import XCTest
import UnfoldEngine
@testable import Unfold

/// Task 11's row motion, in two halves: the pane arithmetic that decides it, and which row view actually
/// gets handed to the driver.
///
/// The arithmetic (`SidebarRowDiffTests`) is a pure function of three arrays -- the ids shown, the ids
/// arriving, the id the controller asked for -- so it has no excuse for being left to the live pass. It is
/// also where the correctness half of the task lives: `setRows` used to answer a delete with "row 0", so
/// two deletes with the confirmation unread destroyed a combo nobody chose.
///
/// The other half (`SidebarRowMotionWiringTests`) asserts *which* row view carries the morph. That is
/// assertable in-process because `Motion.morph` installs its transform synchronously: the animation keys
/// are readable the instant `setRows` returns, with no render cycle and no stopwatch. What is **not**
/// assertable here is what the pose looks like mid-flight. `MotionDriverTests` measures that against
/// fixtures it builds itself, one view at a real frame; a row view laid out by `NSTableView`'s automatic
/// heights, reused across indexes and repositioned by a reload, is not that, and "the row was smaller at
/// 100 ms" would be timing luck rather than a proof. The live pass owns whether the rows read right.
///
/// Mutation-proven by hand, in order: `min(anchor ?? 0, ...)` → `0` (the old row-0 landing) fails
/// `testTwoDeletesWithoutReadingTheAlertNeverLandOnRowZero`; `moved` hard-coded to `true` fails
/// `testDeletingTheLastRowDoesNotCollapseARowThatDidNotChange`; dropping the slot claim fails
/// `testSeveralRowsLeavingClaimOnlyOneCollapsePerSlot`; `makeIfNecessary: true` → `false` in
/// `animate(_:)` fails `testDeletingAMiddleRowAnimatesTheRowThatTookItsPlaceAndNobodyElse` (measured: a
/// table that has just been reloaded hands back nil for every row until it is asked to realize one).
final class SidebarRowDiffTests: XCTestCase {
    private let a = UUID(), b = UUID(), c = UUID(), d = UUID(), e = UUID()

    // MARK: - where the selection lands

    /// The bug: a delete landed on row 0, so the toolbar's minus deleted whatever happened to be first.
    /// The rule is now the deleted row's own index, clamped to the end of what is left.
    func testMiddleDeleteLandsOnTheNeighbourThatTookItsPlace() {
        let diff = SidebarRowDiff.between(previous: [a, b, c, d], next: [a, c, d], requested: nil)
        XCTAssertEqual(diff.landing, .landed(1),
                       "b left from index 1, so the selection has to land on index 1 — where its "
                           + "neighbour c now sits — and not on row 0")
        XCTAssertEqual(diff.departures, [
            SidebarRowDiff.Departure(id: b, oldIndex: 1, slotIndex: 1, collapses: true)])
        XCTAssertEqual(diff.selectedID(in: [a, c, d]), c,
                       "the neighbour of a middle delete is the row that moved up into its slot")
    }

    /// Two deletes in a row, the confirmation never read: the second has to hit what the row said. With
    /// the old landing rule the first delete moved the selection to row 0 and the second killed `a`.
    func testTwoDeletesWithoutReadingTheAlertNeverLandOnRowZero() {
        let first = SidebarRowDiff.between(previous: [a, b, c, d], next: [a, c, d], requested: nil)
        let afterFirst = [a, c, d]
        guard case .landed(let landedFirst) = first.landing else {
            return XCTFail("a delete with no surviving selection has to land on a neighbour")
        }
        XCTAssertEqual(landedFirst, 1)
        XCTAssertEqual(afterFirst[landedFirst], c)

        // `deleteCombo` clears `selectedID` before reloading, so the second pass is also requested: nil,
        // and it must still refuse row 0.
        let second = SidebarRowDiff.between(previous: afterFirst, next: [a, d], requested: nil)
        XCTAssertEqual(second.landing, .landed(1),
                       "the second delete removes index 1, so it lands on index 1 (= d); landing on row 0 "
                           + "would arm the toolbar minus against «a», which nobody chose")
        XCTAssertEqual(second.selectedID(in: [a, d]), d)
    }

    /// Deleting the last row has no row below moving up, so the neighbour is the one above: the landing is
    /// clamped to the end of the list instead of running off it.
    func testLastDeleteIsClampedToTheEndOfWhatIsLeft() {
        let diff = SidebarRowDiff.between(previous: [a, b, c], next: [a, b], requested: nil)
        XCTAssertEqual(diff.landing, .landed(1), "index 2 does not exist any more; the clamp is the "
                           + "same value the collapse needs")
        XCTAssertEqual(diff.selectedID(in: [a, b]), b)
    }

    func testFirstDeleteLandsOnTheNewFirstRow() {
        let diff = SidebarRowDiff.between(previous: [a, b, c], next: [b, c], requested: nil)
        XCTAssertEqual(diff.landing, .landed(0))
        XCTAssertEqual(diff.departures, [
            SidebarRowDiff.Departure(id: a, oldIndex: 0, slotIndex: 0, collapses: true)])
    }

    /// The combo the user is *typing into* can leave the list on its own (the filter matches `preview`),
    /// and then the landing is anchored on where that combo sat -- not on whichever id a `Set` happened to
    /// iterate first.
    func testAFilterThatEvictsTheSelectedComboAnchorsOnItsOwnOldIndex() {
        let diff = SidebarRowDiff.between(previous: [a, b, c, d], next: [a], requested: c)
        XCTAssertEqual(diff.landing, .landed(0),
                       "c sat at index 2 and nothing survived that far down, so the clamp decides")
    }

    /// Ruling Q's hole: the pane must stay quiet when the controller asked for a row that is on screen,
    /// because the controller re-displays the editor on every report and a report it did not ask for moves
    /// the caret. `.requested` is the case whose caller says nothing.
    func testASelectionStillOnScreenIsReportedByTheTableNotThePane() {
        let diff = SidebarRowDiff.between(previous: [a, b, c], next: [a, b, c], requested: c)
        XCTAssertEqual(diff.landing, .requested(2))
        XCTAssertTrue(diff.isEmpty, "the same rows in the same order must not animate anything")
    }

    func testAnEmptyListLandsNowhere() {
        let diff = SidebarRowDiff.between(previous: [a, b], next: [], requested: nil)
        XCTAssertEqual(diff.landing, .empty)
        XCTAssertEqual(diff.departures.map(\.slotIndex), [nil, nil],
                       "there is no slot to collapse into, and no index to clamp")
        XCTAssertTrue(diff.departures.allSatisfy { !$0.collapses })
    }

    // MARK: - which rows move

    /// Row views are recycled: after a reload the row above the vanished slot is still the same combo in
    /// the same place. Animating *it* is the defect the plan names ("a row morphing that did not change")
    /// -- which is why `collapses` is a statement about the slot's content, not about the fact something left.
    func testDeletingTheLastRowDoesNotCollapseARowThatDidNotChange() {
        let diff = SidebarRowDiff.between(previous: [a, b, c], next: [a, b], requested: nil)
        XCTAssertEqual(diff.departures, [
            SidebarRowDiff.Departure(id: c, oldIndex: 2, slotIndex: 1, collapses: false)])
        XCTAssertTrue(diff.arrivals.isEmpty)
    }

    func testAMiddleRowLeavingDoesHandItsSlotToADifferentCombo() {
        let diff = SidebarRowDiff.between(previous: [a, b, c, d], next: [a, c, d], requested: nil)
        XCTAssertEqual(diff.departures.first?.collapses, true,
                       "index 1 now shows c where it showed b, so the slot really closed")
    }

    /// Filtering can evict several rows at once, and everything that clamps past the end of the list lands
    /// on the same surviving index; only one collapse may be installed there, because two morphs on one row
    /// view leave the second deleting the first mid-ramp.
    func testSeveralRowsLeavingClaimOnlyOneCollapsePerSlot() {
        let diff = SidebarRowDiff.between(previous: [a, b, c, d, e], next: [a, e], requested: nil)
        XCTAssertEqual(diff.departures.map(\.id), [b, c, d])
        XCTAssertEqual(diff.departures.map(\.collapses), [true, false, false],
                       "index 1 now shows e where it showed b, so the slot did change hands — but three "
                           + "departures all clamp to that one slot, and only the first may animate it")
    }

    func testAFilterThatRevealsARowAnnouncesOnlyTheRowThatArrived() {
        let diff = SidebarRowDiff.between(previous: [a, c], next: [a, b, c], requested: nil)
        XCTAssertEqual(diff.arrivals, [SidebarRowDiff.Arrival(id: b, index: 1)])
        XCTAssertTrue(diff.departures.isEmpty)
    }

    /// A filter that leaves the visible set alone is the unchanged-target case: `setRows` still reloads,
    /// but it must install no motion at all.
    func testAFilterThatChangesTheVisibleSetNowChangesNothing() {
        let diff = SidebarRowDiff.between(previous: [a, b, c], next: [a, b, c], requested: a)
        XCTAssertTrue(diff.isEmpty)
    }

    func testReorderingWithoutArrivalsOrDeparturesIsStillNotMotion() {
        let diff = SidebarRowDiff.between(previous: [a, b, c], next: [c, a, b], requested: nil)
        XCTAssertTrue(diff.isEmpty, "the same ids in a new order are not rows arriving")
        XCTAssertEqual(diff.landing, .landed(0), "nothing anchored the landing, so it falls to the top row")
    }
}

private extension SidebarRowDiff {
    /// Reads the landing back as an id, so a test can say *which* combo the toolbar minus would now kill.
    func selectedID(in next: [UUID]) -> UUID? {
        switch landing {
        case .empty: nil
        case .requested(let index), .landed(let index):
            index < next.count ? next[index] : nil
        }
    }
}

/// The wiring, on a real `NSTableView` in an offscreen-but-ordered-front window: after one `setRows`,
/// exactly the row views the diff named carry `unfold.morph`, and no others -- and exactly one `onSelect`
/// delivery reports the landing (Ruling AJ8), which is the invariant the editor's caret rule rests on.
///
/// The baseline pass runs while the window is still ordered out, which is the same condition that keeps a
/// launch from animating every row onto the screen -- so what the assertions below see is the motion of one
/// delete, not the residue of the first paint.
final class SidebarRowMotionWiringTests: XCTestCase {
    @MainActor
    func testDeletingAMiddleRowAnimatesTheRowThatTookItsPlaceAndNobodyElse() throws {
        let (sidebar, rows) = try presentedSidebar(count: 5)
        let table = sidebar.listTableView
        var remaining = rows
        remaining.remove(at: 2)
        sidebar.setRows(remaining, selecting: nil)

        XCTAssertEqual(morphedRows(table), [2],
                       "the row that left from index 2 handed its slot to a neighbour: index 2 is what "
                           + "closes, and the rows either side of it did not move")
        XCTAssertEqual(table.selectedRow, 2, "the selection has to land on the same row the collapse does")
    }

    /// The recycling guard, measured on live row views rather than argued from arrays: deleting the last
    /// row leaves the row above exactly where it was, so nothing may be morphed -- and the pane must not
    /// "help" by animating that unchanged neighbour.
    @MainActor
    func testDeletingTheLastRowAnimatesNobody() throws {
        let (sidebar, rows) = try presentedSidebar(count: 4)
        var remaining = rows
        remaining.removeLast()
        sidebar.setRows(remaining, selecting: nil)

        XCTAssertEqual(morphedRows(sidebar.listTableView), [],
                       "the slot kept the same combo, so the only row available to morph was one that had "
                           + "not changed")
        XCTAssertEqual(sidebar.listTableView.selectedRow, 2,
                       "the landing is still the clamped neighbour index")
    }

    @MainActor
    func testARowArrivingUnderAFilterAnimatesItselfAlone() throws {
        let (sidebar, rows) = try presentedSidebar(count: 3)
        sidebar.setRows([rows[0], rows[1]], selecting: rows[0].id)
        XCTAssertEqual(morphedRows(sidebar.listTableView), [], "the rows that stayed are not arrivals")

        sidebar.setRows([rows[0], rows[2], rows[1]], selecting: rows[0].id)
        XCTAssertEqual(morphedRows(sidebar.listTableView), [1],
                       "only the row the filter put back on screen unfolds, and it unfolds at index 1")
    }

    /// The unchanged-target rule on the real pane: the same rows again, with the same selection, must
    /// install nothing -- this is what a keystroke in the filter that changes nothing costs.
    @MainActor
    func testRepeatingTheSameRowsInstallsNoMotion() throws {
        let (sidebar, rows) = try presentedSidebar(count: 3)
        sidebar.setRows(rows, selecting: rows[1].id)
        XCTAssertEqual(morphedRows(sidebar.listTableView), [],
                       "a reload of an identical visible set is not a set of arrivals")
    }

    // MARK: - Ruling AJ8: the landing is reported exactly once

    /// The bug AJ8 names: a landing the table already announced. `setRows` used to call `selectRowIndexes`
    /// **and then** report the same landing itself, so the window controller ran `redisplay()` twice -- each
    /// pass rewriting `triggerField.stringValue` and `replacementView.string`, which is Ruling Q's caret rule
    /// broken on the delete path.
    ///
    /// Which path carries it, measured rather than assumed: the `tableView.reloadData()` inside `setRows`
    /// leaves the table with no selection (`selectedRow == -1` read from the pane mid-call), so
    /// `selectRowIndexes` moves the index and AppKit's own `tableViewSelectionDidChange` posts -- the delegate
    /// is the carrier, and the pane's explicit line is the fallback for a reload that kept the index.
    /// Mutation-proven: restoring the unconditional `onSelect?(visible[index].id)` after `selectRowIndexes`
    /// makes both tests below report **2**.
    @MainActor
    func testAMiddleRowDeleteThatMovesTheIndexReportsItsLandingExactlyOnce() throws {
        let (sidebar, rows) = try presentedSidebar(count: 5)
        var reports: [UUID?] = []
        sidebar.onSelect = { reports.append($0) }
        // Whatever the baseline `setRows` queued has to land before the count starts, so what is counted
        // below is the delete's report and nothing the fixture left running.
        drain(0.12)
        reports.removeAll()

        var remaining = rows
        remaining.remove(at: 2)
        sidebar.setRows(remaining, selecting: nil)
        XCTAssertEqual(sidebar.listTableView.selectedRow, 2,
                       "the fixture's setup assumes the landing moves the index off row 0")
        drain(0.12)

        XCTAssertEqual(reports.count, 1,
                       "a middle-row delete reported its landing \(reports.count) times "
                           + "(\(reports.map { $0.map(\.uuidString) ?? "nil" })) — the delegate notification "
                           + "and the pane's explicit report both fired, so the editor was re-displayed "
                           + "twice and the replacement field rewritten under the user's caret")
        XCTAssertEqual(reports.first ?? nil, remaining[2].id,
                       "the one report must name the neighbour the selection landed on")
    }

    /// The same invariant on the other landing shape: a delete at the **top** of the list, whose landing is
    /// row 0 (no neighbour above, so `collapseGap` and the clamp both come from the slot itself). Still one
    /// delivery -- a fix that suppressed the report on one branch only would pass the test above and leave
    /// this one firing twice.
    @MainActor
    func testADeleteAtTheTopOfTheListAlsoReportsItsLandingExactlyOnce() throws {
        let (sidebar, rows) = try presentedSidebar(count: 4)
        var reports: [UUID?] = []
        sidebar.onSelect = { reports.append($0) }
        drain(0.12)
        reports.removeAll()

        var remaining = rows
        remaining.removeFirst()
        sidebar.setRows(remaining, selecting: nil)
        drain(0.12)

        XCTAssertEqual(reports.count, 1,
                       "the first row's delete reported \(reports.count) times: "
                           + "\(reports.map { $0.map(\.uuidString) ?? "nil" })")
        XCTAssertEqual(reports.first ?? nil, remaining[0].id,
                       "and it landed on the row that became the first")
    }

    // MARK: - fixture

    /// A sidebar in a real window with `count` rows already presented, ordered front off the corner of any
    /// plausible display (on-screen-ness is what gates AppKit realizing row views, exactly as in
    /// `MotionDriverTests`), and left with **no** morph installed.
    @MainActor
    private func presentedSidebar(count: Int) throws -> (SidebarViewController, [Combo]) {
        _ = NSApplication.shared
        let rows = (0..<count).map {
            Combo(id: UUID(), trigger: "trigger\($0)", label: "l\($0)", enabled: true,
                  parts: [.text("replacement number \($0)")], insertion: .paste)
        }
        let sidebar = SidebarViewController()
        sidebar.loadViewIfNeeded()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 420),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = sidebar.view
        windowsToClose.append(window)
        // Ordered out: the baseline pass must install no motion, or every assertion below would read the
        // first paint's arrivals instead of the delete's.
        sidebar.setRows(rows, selecting: rows.first?.id)
        window.setFrameOrigin(NSPoint(x: -3_200, y: -1_800))
        window.orderFrontRegardless()
        return (sidebar, rows)
    }

    /// Which visible rows currently carry the driver's transform. Read with `makeIfNecessary: false` so
    /// this cannot realize a row view and manufacture the very animation it is looking for.
    @MainActor
    private func morphedRows(_ table: NSTableView) -> [Int] {
        (0..<max(table.numberOfRows, 0)).filter { row in
            table.rowView(atRow: row, makeIfNecessary: false)?.layer?.animationKeys()?
                .contains(Motion.morphKey) == true
        }
    }

    /// Runs the main loop for `seconds`, so a selection notification AppKit defers to the next turn arrives
    /// before a count is taken. Same reason `MotionDriverTests` drains instead of waiting on expectations.
    @MainActor
    private func drain(_ seconds: TimeInterval) {
        let started = Date()
        while Date() < started.addingTimeInterval(seconds) {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
    }

    /// Windows ordered front for a test have to go away again, or the next one measures a stale table.
    private var windowsToClose: [NSWindow] = []
    override func tearDown() {
        windowsToClose.forEach { $0.orderOut(nil) }
        windowsToClose = []
        super.tearDown()
    }
}

