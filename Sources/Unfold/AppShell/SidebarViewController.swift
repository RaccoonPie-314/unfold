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

    /// True when the list shows no rows. The controller reads this for its empty-state copy instead of
    /// reaching into the table view.
    var isEmptyList: Bool { visible.isEmpty }
    /// Read-only, because the window sets `initialFirstResponder` to the list and the controller cannot
    /// reach a private property of the pane.
    var listTableView: NSTableView { tableView }

    override func loadView() {
        tableView.headerView = nil
        tableView.style = .sourceList
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
        let row = tableView.selectedRow
        onSelect?(row >= 0 && row < visible.count ? visible[row].id : nil)
    }

    func controlTextDidChange(_ notification: Notification) {
        guard (notification.object as? NSControl) === searchField else { return }
        onFilter?(searchField.stringValue)
    }

    @objc private func doubleClicked() { onRequestEdit?() }

    /// Puts the rows back where they were, and moves the selection to the right row. Row indexes are
    /// indexes into `visible`, never into `file.combos`, so a filter cannot make the editor select a
    /// combo that is not on screen.
    ///
    /// The landing rule below (`SidebarRowDiff`'s neighbour clamp) is the correctness half of a delete:
    /// two deletes with the confirmation unread used to land on row 0 and destroy a combo nobody chose.
    /// Row motion on top of it was removed by user decision on 2026-10-29 -- `setRows` now reloads and
    /// selects, and nothing between those is animated.
    func setRows(_ rows: [Combo], selecting id: UUID?) {
        let diff = SidebarRowDiff.between(previous: shownIDs, next: rows.map(\.id), requested: id)
        visible = rows
        tableView.reloadData()
        shownIDs = visible.map(\.id)

        switch diff.landing {
        case .empty:
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

/// A source-list row. The trigger is what a person scans for, so it owns the first line and the
/// replacement sits underneath it rather than competing for the same row.
///
/// Both `NSTableCellView` outlets are set on purpose: the cell only recolours the views handed to
/// `textField` and `imageView` when a row becomes selected, so a symbol or label wired up as a plain
/// subview keeps its accent tint and disappears into the blue selection.
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
        // Tertiary label is not an option at any size: it measures 1.88:1 in Light.
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
