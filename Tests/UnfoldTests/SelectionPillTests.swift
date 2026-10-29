import AppKit
import XCTest
import UnfoldEngine
@testable import Unfold

/// The glass selection pill, measured in-process.
///
/// The user asked for it on 2026-10-29 ("a glass enlarge pill and just sliding through, native Apple
/// animation tho") -- and the same user deleted the old `selectionMorph` line (Ruling AK), so what is
/// being proven here is exactly the difference between the two: one surface that **stays inside the
/// list**, behind the row text, driven by the one `Motion.morph` path. The claims split into what is
/// decidable in-process and what only pixels can settle:
///
/// * placement -- the pill sits in the table's own document view, ordered **below** the row views in the
///   sibling list (so it paints behind the text), and the row views are not opaque over it;
/// * first load -- the pill is placed on the selected row and **no animation is installed** (there is no
///   previous position to slide from);
/// * a move -- selecting another row installs the `unfold.morph` transform synchronously, on the same
///   driver path every other transition uses, and the pill's resting frame is the new row's rect inset
///   by the list's horizontal inset;
/// * the landings -- delete, filter-eviction and empty list all leave the pill where the selection is
///   (hidden when there is none).
///
/// Live-pass items this file cannot decide: whether text over the glass is legible in both appearances
/// and over a light and a dark desktop picture, and whether the grow-on-landing reads as "enlarge" or
/// as nothing. See the live-check list.
///
/// Mutation-proven: moving the pill above the row views (`positioned: .above`) fails the placement test;
/// letting the first appearance animate (`previous` synthesized from the target) fails
/// `testFirstLoadPlacesThePillWithoutAnimating`; skipping `positionSelectionPill` on the `.empty`
/// landing fails the hide test; deleting the morph call leaves every slide test with a pill that
/// teleports and no key ever installed.
final class SelectionPillTests: XCTestCase {
    private let morphKey = "unfold.morph"

    /// The property the whole feature lives or dies by: the pill must render **behind** the row text,
    /// inside the scrolled document, and never above the content. Measured, not assumed -- the SDK offers
    /// `NSScrollView.overlayView`, which paints above everything and would refract the text it is meant
    /// to sit behind; that is why this is a subview of the document view, and this test is the proof.
    @MainActor
    func testThePillSitsBehindTheRowViewsItMarks() throws {
        let (sidebar, _) = try presentedSidebar(count: 3)
        let table = sidebar.listTableView
        let pill = sidebar.selectionPill
        drain(0.12)

        // 1. It lives in the table itself -- the scroll view's document view -- so scrolling moves it with
        //    the rows for free, in the same coordinate space as `rect(ofRow:)`.
        let document = try XCTUnwrap(table.enclosingScrollView?.documentView)
        XCTAssertIdentical(pill.superview, table,
                           "the pill's parent is \(String(describing: pill.superview)), not the table "
                               + "that is the scroll view's document view")
        XCTAssertIdentical(table, document,
                           "the table is not the scrolled document; the placement claim is false")

        // 2. The selected row's view is a **sibling painted after it**, and neither the row view nor its
        //    cells are opaque over the pill.
        let row = table.selectedRow
        XCTAssertGreaterThanOrEqual(row, 0)
        let rowView = try XCTUnwrap(table.rowView(atRow: row, makeIfNecessary: true),
                                    "no row view for the selected row — the table never laid out")
        let siblings = table.subviews
        let pillIndex = try XCTUnwrap(siblings.firstIndex(of: pill))
        let rowIndex = try XCTUnwrap(siblings.firstIndex(of: rowView),
                                     "the row view is not a sibling of the pill in the document view "
                                         + "(\(siblings.map { Swift.type(of: $0) })): the placement "
                                         + "candidate changed under this test")
        XCTAssertLessThan(pillIndex, rowIndex,
                          "the pill (\(pillIndex)) is ordered at or above the row view (\(rowIndex)) "
                              + "in the same parent: it would paint over the text it marks")
        XCTAssertFalse(rowView.isOpaque,
                       "an opaque row view would hide the pill no matter what the sibling order says")

        // 3. The glass itself, as the class documents it: one regular, untinted surface.
        XCTAssertEqual(pill.glass.style, .regular)
        XCTAssertNil(pill.glass.tintColor,
                     "the colour budget is spent on glyphs, not surfaces — no glass gets a tintColor")
    }

    /// The first load places. An arrival from nowhere is the flash the deleted row transitions were
    /// famous for, and it is the one rule `SidebarRowMotionWiringTests`' baseline pass also exercises:
    /// the pane is presented, the pill lands, and nothing holds a transform.
    @MainActor
    func testFirstLoadPlacesThePillWithoutAnimating() throws {
        let (sidebar, rows) = try presentedSidebar(count: 3)
        let table = sidebar.listTableView
        let pill = sidebar.selectionPill
        drain(0.12)

        XCTAssertEqual(table.selectedRow, 0, "the fixture selects the first row")
        XCTAssertFalse(pill.isHidden, "the pill marks the selected row from the first frame")
        XCTAssertEqual(pill.frame, Self.pillRect(for: table, row: 0))
        XCTAssertFalse(pill.layer?.animationKeys()?.contains(morphKey) ?? false,
                       "a \(morphKey) transform was installed on the very first placement "
                           + "(keys=\(pill.layer?.animationKeys() ?? [])): first load must place, not slide")
        XCTAssertEqual(rows.count, 3)
    }

    /// Switching between trigger words is the motion the user asked for. The in-process proof is the
    /// one `MotionDriverTests` established: the transform is installed under `unfold.morph`
    /// synchronously, and the resting frame is already the new row's rect -- what rides the ramp is the
    /// layer's presentation geometry, which the driver suite measures in full.
    @MainActor
    func testSelectingAnotherRowSlidesThePillToItsRect() throws {
        let (sidebar, _) = try presentedSidebar(count: 3)
        let table = sidebar.listTableView
        let pill = sidebar.selectionPill
        drain(0.12)
        XCTAssertEqual(pill.frame, Self.pillRect(for: table, row: 0))

        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)

        XCTAssertTrue(pill.layer?.animationKeys()?.contains(morphKey) == true,
                      "moving the selection installed no \(morphKey) transform (keys="
                          + "\(pill.layer?.animationKeys() ?? [])): the pill teleports, which is the "
                          + "'sliding animation' the user asked for and did not get")
        XCTAssertEqual(pill.frame, Self.pillRect(for: table, row: 1),
                       "the resting frame is the truth the morph lands on; it must already be the new row")

        // And a re-assertion of the same selection must NOT restart the motion (an identity morph would
        // re-run the anti-flash ramp and make the pill blink under a no-op).
        let before = pill.layer?.animation(forKey: morphKey)
        XCTAssertNotNil(before, "the slide installed no readable animation object to compare against")
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        let after = pill.layer?.animation(forKey: morphKey)
        XCTAssertTrue(after === before,
                      "selecting the already-selected row replaced the morph object — the identity "
                          + "guard in `positionSelectionPill` let an identity morph restart")
    }

    /// Deleting the selected row is `SidebarRowDiff`'s neighbour landing; the pill has to follow the
    /// selection, not the deleted row's ghost position.
    @MainActor
    func testDeletingTheSelectedRowMovesItToTheNeighboursPosition() throws {
        let (sidebar, rows) = try presentedSidebar(count: 4)
        let table = sidebar.listTableView
        drain(0.12)
        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        var remaining = rows
        remaining.remove(at: 1) // row 1 is selected; its neighbour lands in its slot
        sidebar.setRows(remaining, selecting: nil)
        drain(0.12)

        let pill = sidebar.selectionPill
        XCTAssertEqual(table.selectedRow, 1, "the neighbour landing is what the pane guarantees")
        XCTAssertFalse(pill.isHidden)
        XCTAssertEqual(pill.frame, Self.pillRect(for: table, row: 1),
                       "the pill sits on the row the selection actually landed on")
    }

    /// A filter that moves the selected combo to a different row repositions the pill; one that evicts
    /// it repositions onto the landing. Either way the pill is on `selectedRow`, never on an old index.
    @MainActor
    func testAFilterThatMovesTheSelectedRowRepositionsIt() throws {
        let (sidebar, rows) = try presentedSidebar(count: 3)
        let table = sidebar.listTableView
        // Keep rows 2 and 0, in that order, and ask for row 2's combo: the "requested" landing moves it
        // from index 2 to index 0.
        sidebar.setRows([rows[2], rows[0]], selecting: rows[2].id)
        drain(0.12)

        let pill = sidebar.selectionPill
        XCTAssertEqual(table.selectedRow, 0)
        XCTAssertFalse(pill.isHidden)
        XCTAssertEqual(pill.frame, Self.pillRect(for: table, row: 0))
    }

    @MainActor
    func testAnEmptyListHidesThePill() throws {
        let (sidebar, rows) = try presentedSidebar(count: 2)
        let pill = sidebar.selectionPill
        XCTAssertFalse(pill.isHidden)
        sidebar.setRows([], selecting: nil)
        XCTAssertTrue(pill.isHidden, "nothing is on screen to mark — the pill must not float over an "
                                    + "empty list (fixture rows: \(rows.count))")
        sidebar.setRows(rows, selecting: rows[1].id)
        XCTAssertFalse(pill.isHidden)
        XCTAssertEqual(pill.frame, Self.pillRect(for: sidebar.listTableView, row: 1))
    }

    // MARK: - fixture

    /// The pill's rect for a row -- spelled independently of the production helper so a change to the
    /// inset or the formula has to be a deliberate two-file edit, the same convention the motion tests
    /// use for the geometry they measure.
    private static func pillRect(for table: NSTableView, row: Int) -> CGRect {
        table.rect(ofRow: row).insetBy(dx: Theme.Spacing.rowPillInset, dy: 0)
    }

    /// A sidebar in a real window with `count` rows already presented, ordered front off the corner of
    /// any plausible display (on-screen-ness is what gates AppKit realizing row views -- same fixture as
    /// `SidebarRowMotionWiringTests`).
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
        sidebar.setRows(rows, selecting: rows.first?.id)
        window.setFrameOrigin(NSPoint(x: -3_200, y: -1_800))
        window.orderFrontRegardless()
        return (sidebar, rows)
    }

    @MainActor
    private func drain(_ seconds: TimeInterval) {
        let started = Date()
        while Date() < started.addingTimeInterval(seconds) {
            RunLoop.main.run(until: Date().addingTimeInterval(0.005))
        }
    }

    private var windowsToClose: [NSWindow] = []
    override func tearDown() {
        windowsToClose.forEach { $0.orderOut(nil) }
        windowsToClose = []
        super.tearDown()
    }
}
