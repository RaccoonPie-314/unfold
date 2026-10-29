import AppKit
import UnfoldEngine

/// The library list: a source list of combos with a filter over it.
///
/// The pane renders; it does not decide. `setRows(_:selecting:)` is the only entry point, which is what
/// lets the pane compute the delete landing itself: it remembers the ids it last showed, so it can see
/// which rows left and land the selection on the neighbour instead of on row 0. The model and the filter
/// string stay with the window controller -- the pane reports intent through `onSelect` / `onFilter` /
/// `onRequestEdit` and never edits a `Combo`.
final class SidebarViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate,
                                   NSSearchFieldDelegate {
    var onSelect: ((UUID?) -> Void)?
    var onFilter: ((String) -> Void)?
    var onRequestEdit: (() -> Void)?

    private let tableView = NSTableView()
    private let sidebarScroll = NSScrollView()
    private let searchField = NSSearchField()
    private var visible: [Combo] = []
    /// The ids this pane last showed. `SidebarRowDiff` reads them against the incoming ids to decide
    /// where the selection lands after a delete -- the correctness half of a delete, which survives the
    /// row-motion transitions the user asked to have removed on 2026-10-29.
    private var shownIDs: [UUID] = []
    /// The pill's last **placed** rect, in the table's own coordinates, or nil while it is hidden. The
    /// slide's source pose is read from it, which is why "first appearance places, later moves slide"
    /// needs no other state.
    private var lastPillFrame: CGRect?

    /// The glass selection pill. Internal rather than private because `SelectionPillTests` measures its
    /// **placement in the view hierarchy** -- behind the row views, inside the scrolled document -- and a
    /// placement nobody can read is a placement nobody can prove. Nothing outside the pane moves it.
    let selectionPill = SelectionPillView()

    /// True when the list shows no rows. The controller reads this for its empty-state copy instead of
    /// reaching into the table view.
    var isEmptyList: Bool { visible.isEmpty }
    /// Read-only, because the window sets `initialFirstResponder` to the list and the controller cannot
    /// reach a private property of the pane.
    var listTableView: NSTableView { tableView }

    override func loadView() {
        tableView.headerView = nil
        tableView.style = .sourceList
        // The system source-list selection fill is switched off in favour of one glass pill
        // (`SelectionPillView`) that slides row to row -- the user's request of 2026-10-29. `.none` is a
        // real case of `NSTableView.SelectionHighlightStyle` (`NSTableView.h:101`), and `.sourceList`
        // stays as the table **style** because that is what supplies the row insets and gaps.
        tableView.selectionHighlightStyle = .none
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.usesAutomaticRowHeights = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(doubleClicked)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("combo"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        sidebarScroll.documentView = tableView
        sidebarScroll.hasVerticalScroller = true
        sidebarScroll.drawsBackground = false
        // The pill lives **inside the document view**, inserted below every row view: the row views are
        // its siblings painted after it, its frame is written in the same space as
        // `tableView.rect(ofRow:)`, and scrolling moves it with the rows for free. `NSScrollView`'s
        // `overlayView` was rejected on measurement grounds -- it paints **above** the content, which
        // would refract the row text it is supposed to sit behind. The placement is asserted by
        // `SelectionPillTests.testThePillSitsBehindTheRowViewsItMarks`, not trusted to this comment.
        tableView.addSubview(selectionPill, positioned: .below, relativeTo: nil)
        // Content insets stay automatic (the property's default of `true`): the system scroll-edge fade
        // is what `liquid-glass.md` prescribes in place of a solid background under a bar. If the
        // magnifier glyph ever lands on the placeholder text again, fix it on `searchField` -- not by
        // suppressing the edge effect, which was the wrong lever.

        // The stock search field, not a field inside a hand-made glass capsule: on macOS 26 the
        // system control already *is* the glass pill, and stripping its bezel to put glass behind it
        // only removes the inset that keeps the magnifier out of the placeholder text.
        searchField.placeholderString = "Filter"
        searchField.delegate = self
        searchField.translatesAutoresizingMaskIntoConstraints = false
        sidebarScroll.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView()
        container.addSubview(searchField)
        container.addSubview(sidebarScroll)
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor, constant: 8),
            searchField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            searchField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),
            sidebarScroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 6),
            sidebarScroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            sidebarScroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            sidebarScroll.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        self.view = container
    }

    func numberOfRows(in tableView: NSTableView) -> Int { visible.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < visible.count else { return nil }
        let cell = ComboRowView.dequeue(from: tableView)
        cell.apply(visible[row])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        positionSelectionPill(animated: true)
        let row = tableView.selectedRow
        onSelect?(row >= 0 && row < visible.count ? visible[row].id : nil)
    }

    /// The row views carry one thing `NSTableView`'s defaults do not: a resize callback. An
    /// automatic-height row is **not final** when AppKit first tiles it (measured with a temporary
    /// probe: both `rect(ofRow:)` and the freshly added row view reported the 24 pt default during
    /// `reloadData`, the laid-out height is 40 pt, and the correction arrives later as an in-place
    /// resize with no delegate callback of its own). The pill re-places on that resize -- without
    /// animating, because following the ruler is not the user switching trigger words.
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let identifier = NSUserInterfaceItemIdentifier("unfold.pillTrackingRow")
        let rowView: PillTrackingRowView
        if let reused = tableView.makeView(withIdentifier: identifier, owner: nil) as? PillTrackingRowView {
            rowView = reused
        } else {
            rowView = PillTrackingRowView()
            rowView.identifier = identifier
        }
        rowView.onGeometryChange = { [weak self] in self?.positionSelectionPill(animated: false) }
        return rowView
    }

    func controlTextDidChange(_ notification: Notification) {
        guard (notification.object as? NSControl) === searchField else { return }
        onFilter?(searchField.stringValue)
    }

    @objc private func doubleClicked() { onRequestEdit?() }

    /// Moves the glass selection pill onto the row the table has selected -- or hides it when nothing is
    /// selected, because an empty list has no row to mark.
    ///
    /// Three rules, each asserted in `SelectionPillTests` rather than trusted to prose:
    /// * The **first** placement, and every placement from a hidden pill (`lastPillFrame == nil` in
    ///   both), sets the frame and runs no animation: there is no position the user watched the pill
    ///   leave, so a slide from nowhere is the flash the row transitions were deleted for.
    /// * A move between two visible placements is one `Motion.morph` under the plan's `selectionSlide`,
    ///   whose source pose is the pill's previous frame grown down by `MotionGeometry.slideGrowRatio` --
    ///   no second animation path.
    /// * A placement already at its target does nothing, so the `selectRowIndexes` inside `setRows`
    ///   (which fires the selection notification *and* lands here in the same turn) cannot restart an
    ///   identity morph whose only visible effect would be the anti-flash opacity ramp.
    ///
    /// `animated == false` is the layout clock -- `viewDidLayout` (window resize) and the
    /// `PillTrackingRowView` resize hook (AppKit finishing an automatic row height) re-place without
    /// motion: the pill **following the ruler** is not a selection change, and measured, the rect right
    /// after `reloadData()` is not the final one.
    private func positionSelectionPill(animated: Bool) {
        let row = tableView.selectedRow
        guard row >= 0, row < visible.count else {
            selectionPill.isHidden = true
            lastPillFrame = nil
            return
        }
        let target = Self.pillFrame(inRowRect: tableView.rect(ofRow: row))
        guard selectionPill.isHidden || target != lastPillFrame else { return }
        let previous = lastPillFrame
        selectionPill.frame = target
        selectionPill.isHidden = false
        lastPillFrame = target
        if animated, let previous, let slide = MotionPlan.lookup(.selectionSlide) {
            Motion.morph(selectionPill,
                         source: MotionGeometry.slideAndGrowSource(previous: previous),
                         transition: slide)
        }
    }

    override func viewDidLayout() {
        super.viewDidLayout()
        positionSelectionPill(animated: false)
    }

    /// The pill's rect for a row: the row's own rect, inset by the list's horizontal inset so the pill
    /// lines up with the filter field's column instead of running into the scroller. Height is the
    /// row's -- the pill marks *the row*, not a capsule floating inside it.
    private static func pillFrame(inRowRect rowRect: CGRect) -> CGRect {
        rowRect.insetBy(dx: Theme.Spacing.rowPillInset, dy: 0)
    }

    /// Puts the rows back where they were, and moves the selection to the right row. Row indexes are
    /// indexes into `visible`, never into `file.combos`, so a filter cannot make the editor select a
    /// combo that is not on screen.
    ///
    /// The landing rule below (`SidebarRowDiff`'s neighbour clamp) is the correctness half of a delete:
    /// two deletes with the confirmation unread used to land on row 0 and destroy a combo nobody chose.
    /// Row motion on top of it was removed by user decision on 2026-10-29 -- `setRows` now reloads and
    /// selects, and no row transform rides along. The glass selection pill does follow: every landing
    /// ends at `positionSelectionPill`, which reads the selection this method has just landed (the
    /// `selectRowIndexes` below usually fires the selection notification first; the trailing call is
    /// the same-index path, where no notification posts).
    func setRows(_ rows: [Combo], selecting id: UUID?) {
        let diff = SidebarRowDiff.between(previous: shownIDs, next: rows.map(\.id), requested: id)
        visible = rows
        tableView.reloadData()
        shownIDs = visible.map(\.id)

        switch diff.landing {
        case .empty:
            positionSelectionPill(animated: true)
            onSelect?(nil)
            return
        case .requested(let index):
            // The controller asked for this combo and it is on screen, so the pane adds no report of its
            // own -- this is the path a replacement edit takes and Ruling Q's rule is that it must not be
            // re-displayed by the pane. Which path does fire here: `reloadData()` above leaves the table with
            // **no** selection (measured: `selectedRow == -1`), so `selectRowIndexes` moves the index and
            // `tableViewSelectionDidChange` carries the landing. The silence below is therefore the pane's
            // silence, not the table's -- see the note filed against Ruling AJ8.
            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        case .landed(let index):
            // Which path says it, precisely -- the pane reports on exactly one of them (Ruling AJ8).
            // `selectRowIndexes` posts `tableViewSelectionDidChange` whenever the numeric row index moves,
            // and the delegate reads the landing off `visible`, so a moved index needs no second report: the
            // explicit one used to ride on top of it, so the window controller got two `redisplay()` calls --
            // each rewriting `triggerField.stringValue` and `replacementView.string`, which is Ruling Q's
            // caret rule broken on the delete path. Measured (`SidebarRowMotionWiringTests`): because the
            // `reloadData()` above deselects, every delete landing moves the index, so the notification is
            // the carrier in every landing this pane produces today; the explicit line is the fallback for
            // the case the old comment called the only one -- a table that keeps the same row index for a
            // different combo posts nothing. One delivery either way, and the tests count them.
            let indexAlreadySelected = tableView.selectedRow == index
            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            if indexAlreadySelected { onSelect?(visible[index].id) }
        }
        positionSelectionPill(animated: true)
    }

    /// The controller clears the filter when a combo is added, because "new" is a word a half-typed
    /// filter would hide.
    ///
    /// Contract: this clears the field's text only. The caller owns `MainWindowController.filter` and
    /// must reset it too -- setting `stringValue` programmatically does not fire `controlTextDidChange`,
    /// so the pane never learns about it on its own.
    func clearFilter() {
        searchField.stringValue = ""
    }
}

/// What one `setRows` call's selection costs, decided from two id lists and the id the controller asked
/// for -- no AppKit, no view, no window. This is the correctness half of a delete: where the selection
/// lands. Row motion used to be computed here too (which rows arrived, which left, which slot collapsed);
/// the user asked for that on 2026-10-29 and it is gone -- what remains is the landing rule and the
/// report-exactly-once contract `Tests/UnfoldTests/SidebarRowMotionTests.swift` pins.
struct SidebarRowDiff: Equatable {
    /// Where the selection lands, and -- just as load-bearing -- whether the pane has to *say* it.
    enum Landing: Equatable {
        /// The id the controller asked for is still on screen. The pane adds no report of its own; the
        /// table's selection notification carries this landing (measured: `reloadData()` deselects first, so
        /// the index always moves and the notification always posts). What the pane deliberately keeps quiet
        /// about is re-displaying the editor under a caret that is mid-word -- Ruling Q.
        case requested(Int)
        /// Nothing to honour: the selected combo left the list, so the selection lands on its **neighbour**
        /// -- the row that now sits where it sat, clamped to the end of the list. Two deletes with the
        /// confirmation unread used to land on row 0 and delete a combo nobody chose.
        ///
        /// Exactly one report, whichever way the index moved (Ruling AJ8): AppKit's selection notification
        /// carries it when the landing changes the numeric row index, and the pane says it itself only when
        /// the same index now shows a different combo and the table posts nothing.
        case landed(Int)
        /// No rows at all.
        case empty
    }

    let landing: Landing

    static func between(previous: [UUID], next: [UUID], requested: UUID?) -> SidebarRowDiff {
        let landing: Landing
        if next.isEmpty {
            landing = .empty
        } else if let requested, let index = next.firstIndex(of: requested) {
            landing = .requested(index)
        } else {
            // The neighbour the deleted row leaves behind: where the selection *was* if that row is gone,
            // otherwise the first row that left (the lowest index in `previous` whose id is not in `next`).
            // Both are indexes into the list that no longer has them, so the landing is clamped to the end
            // of the list that does.
            let leaving = Set(previous).subtracting(next)
            let anchor = requested.flatMap { previous.firstIndex(of: $0) }
                ?? previous.enumerated().first { leaving.contains($0.element) }?.offset
            landing = .landed(min(anchor ?? 0, next.count - 1))
        }
        return SidebarRowDiff(landing: landing)
    }
}

/// An `NSTableRowView` that says out loud when AppKit changes its size.
///
/// The automatic row height is computed *after* the row view is added, and the correction arrives as a
/// bare `setFrameSize:` with no delegate callback (measured 2026-10-29: during `reloadData` the fresh
/// row view and `rect(ofRow:)` both said 24 pt; the laid-out height is 40 pt). The selection pill's
/// placement needs that moment; nothing else about the row changes.
///
/// `drawSelection(in:)` is switched off in this subclass as belt-and-braces: the table already runs
/// `selectionHighlightStyle = .none` and the glass pill is the selection mark, so a row view that
/// re-consulted the style could only double the paint.
private final class PillTrackingRowView: NSTableRowView {
    var onGeometryChange: (() -> Void)?
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // Every call, not just the size-changing ones: the probe measured AppKit re-tiling rows with
        // same-size `setFrameSize:` passes that carry the *origin* correction -- skipping those leaves
        // the pill parked on the stale (10, 34, 280, 24) while the row has already settled at
        // (..., 50, ..., 40). `positionSelectionPill` no-ops unless the pill's own target moved, so the
        // extra calls cost one rect comparison each.
        onGeometryChange?()
    }
    override func drawSelection(in dirtyRect: NSRect) {}
}

/// A source-list row. The trigger is what a person scans for, so it owns the first line and the
/// replacement sits underneath it rather than competing for the same row.///
/// Both `NSTableCellView` outlets are still set -- `imageView` on the disabled-row slash, `textField` on
/// the trigger -- but with `selectionHighlightStyle = .none` AppKit no longer recolours them on
/// selection, and it is deliberate that the colours below no longer depend on it: both lines are
/// `labelColor` (disabled triggers `secondaryLabelColor`) and the glass pill behind the row carries the
/// selection instead of a fill swapping the text to a highlighted colour.
private final class ComboRowView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("unfold.comboRow")

    private let symbol = NSImageView()
    private let triggerLabel = NSTextField(labelWithString: "")
    private let previewLabel = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        triggerLabel.font = Theme.Font.monoTrigger
        triggerLabel.lineBreakMode = .byTruncatingMiddle
        previewLabel.font = Theme.Font.caption
        previewLabel.textColor = .labelColor
        previewLabel.lineBreakMode = .byTruncatingTail
        previewLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        previewLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        triggerLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let lines = NSStackView(views: [triggerLabel, previewLabel])
        lines.orientation = .vertical
        lines.alignment = .leading
        lines.spacing = 1

        symbol.translatesAutoresizingMaskIntoConstraints = false
        lines.translatesAutoresizingMaskIntoConstraints = false
        addSubview(lines)
        addSubview(symbol)
        NSLayoutConstraint.activate([
            symbol.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            symbol.centerYAnchor.constraint(equalTo: triggerLabel.centerYAnchor),
            symbol.widthAnchor.constraint(equalToConstant: 14),
            lines.leadingAnchor.constraint(equalTo: symbol.trailingAnchor, constant: 7),
            lines.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            lines.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            lines.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -5),
        ])

        textField = triggerLabel
        imageView = symbol
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func apply(_ combo: Combo) {
        toolTip = "\(combo.trigger) → \(combo.preview)"
        triggerLabel.stringValue = combo.trigger
        // Enabled rows are `labelColor` (14.94:1 in Light); only the disabled case steps down to
        // secondary label, which measures 3.95:1 in Light and 5.89:1 in Dark -- deliberately under the
        // 4.5:1 text floor, because "disabled" is the message and the slash symbol plus the tooltip
        // carry it without colour (see `row.triggerDisabled` in Contrast.swift, floored at 3.0).
        // Tertiary label is not an option at any size: it measures 1.88:1 in Light. These colours do
        // not change on selection any more -- the selection highlight is `.none` and the glass pill
        // carries the mark -- so the pair the user sees over the pill is exactly the pair set here.
        triggerLabel.textColor = combo.enabled ? .labelColor : .secondaryLabelColor
        previewLabel.stringValue = combo.preview
        // Only the exception gets an icon. A filled circle on every row reads as a column of radio
        // buttons and says nothing; a slash on the rows that will not fire says everything.
        symbol.image = combo.enabled ? nil
            : NSImage(systemSymbolName: "slash.circle", accessibilityDescription: "Disabled")
        symbol.contentTintColor = .secondaryLabelColor
    }

    static func dequeue(from tableView: NSTableView) -> ComboRowView {
        if let reused = tableView.makeView(withIdentifier: identifier, owner: nil) as? ComboRowView {
            return reused
        }
        let cell = ComboRowView()
        cell.identifier = identifier
        return cell
    }
}

extension Combo {
    /// The literal text of the replacement, flattened for one line of a list. Placeholders keep their
    /// names, because a combo that only works after you answer a question should say so in the list.
    ///
    /// Internal rather than file-private, because the window controller's filter predicate reads it.
    var preview: String {
        parts.reduce(into: "") { result, part in
            switch part {
            case .text(let value): result += value
            case .placeholder(let placeholder): result += "[\(placeholder.id)]"
            }
        }.replacingOccurrences(of: "\n", with: "⏎")
    }
}
