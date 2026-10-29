import AppKit
import UnfoldEngine

/// The library list: a source list of combos with a filter over it.
///
/// The pane renders; it does not decide. `setRows(_:selecting:)` is the only entry point, which is what
/// lets Task 11 animate the diff: the pane can see which ids arrived and which left because it
/// remembers what it last showed. The model and the filter string stay with the window controller -- the
/// pane reports intent through `onSelect` / `onFilter` / `onRequestEdit` and never edits a `Combo`.
final class SidebarViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate,
                                   NSSearchFieldDelegate {
    var onSelect: ((UUID?) -> Void)?
    var onFilter: ((String) -> Void)?
    var onRequestEdit: (() -> Void)?

    private let tableView = NSTableView()
    private let sidebarScroll = NSScrollView()
    private let searchField = NSSearchField()
    private var visible: [Combo] = []
    /// The ids this pane last showed, and the left half of the diff Task 11 animates: a row whose id was
    /// not here unfolds (`rowInsert`), a row whose id is no longer here collapses (`rowRemove`).
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
    /// The two halves of this function are one change on purpose: where a delete lands (`SidebarRowDiff`'s
    /// neighbour rule) is also the index whose row view `rowRemove` collapses.
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
            // The controller asked for this combo and it is on screen. Tell it nothing: `selectRowIndexes`
            // posts when the row moves and stays silent when it does not, and silence is correct here --
            // re-displaying the editor under a caret that is mid-word is Ruling Q's bug, and this is the
            // path a replacement edit takes.
            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        case .landed(let index):
            // What the user had selected left the list (or there was never a selection to honour), and the
            // table may keep the *same row index* showing a different combo -- which posts nothing. So the
            // pane reports the landing itself, after the selection has moved, because the window
            // controller reads `selectedRowFrame` from inside this callback.
            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
            onSelect?(visible[index].id)
        }
        animate(diff)
    }

    /// Animates the difference the diff found. Every transition gets its **own** real rect: a row that
    /// arrived unfolds out of a zero-height gap on its own baseline, and a row that left closes onto the
    /// baseline of the neighbour it collapsed against -- never one geometry reused for both.
    ///
    /// Row views are recycled, so `rowRemove` animates whatever now occupies the vanished row's slot.
    /// `SidebarRowDiff` only allows that when the slot really took on new content: after a delete the rows
    /// below move up into it, but deleting the *last* row leaves the row above exactly where it was, and
    /// morphing that one would animate a row that did not change -- the defect the plan names. (The
    /// alternative it prescribes, a `bitmapImageRepForCachingDisplay` snapshot of the leaving row, cannot
    /// collapse: `Motion.morph` always lands on `view.frame`, so a snapshot's pose can only *expand out
    /// of* the closing line and then vanish. See the Task 11b note.)
    private func animate(_ diff: SidebarRowDiff) {
        guard !diff.isEmpty, view.window?.isVisible == true else { return }

        if let insert = MotionPlan.lookup(.rowInsert) {
            for arrival in diff.arrivals {
                guard let rowView = tableView.rowView(atRow: arrival.index, makeIfNecessary: true)
                else { continue }
                let final = rowView.frame
                // The table is flipped, so `maxY` is the edge the row's text sits on: the gap opens at the
                // arriving row's own baseline and the row unfolds out of it.
                Motion.morph(rowView, source: CGRect(x: final.minX, y: final.maxY,
                                                     width: final.width, height: 0),
                             transition: insert)
            }
        }

        if let remove = MotionPlan.lookup(.rowRemove) {
            for departure in diff.departures where departure.collapses {
                // `makeIfNecessary: true` on both reads, and that is a measurement, not a guess: right
                // after `reloadData()` the table answers `false` with nil for *every* row, so the collapse
                // would never have a subject at all. With `true` the row views come back already at their
                // final resting frames (measured: (0, 50, 300, 40) before and after the next display pass).
                guard let slot = departure.slotIndex,
                      let occupant = tableView.rowView(atRow: slot, makeIfNecessary: true)
                else { continue }
                // The neighbour above is the row the gap closes onto; its baseline is the line between it
                // and the vanished row. A delete at the top of the list has no neighbour above, so the gap
                // closes onto the top line of the slot itself.
                let line: CGRect
                if slot > 0, let above = tableView.rowView(atRow: slot - 1, makeIfNecessary: true) {
                    line = CGRect(x: above.frame.minX, y: above.frame.maxY,
                                  width: above.frame.width, height: 0)
                } else {
                    line = CGRect(x: occupant.frame.minX, y: occupant.frame.minY,
                                  width: occupant.frame.width, height: 0)
                }
                Motion.morph(occupant, source: line, transition: remove)
            }
        }
    }

    /// The selected row's frame in screen coordinates -- the anchor the editor's morph starts from.
    ///
    /// `makeIfNecessary: true`, because this is read from inside `setRows`' selection report, and a table
    /// that has just been reloaded hands back nil for every row until it is asked to realize one.
    var selectedRowFrame: CGRect? {
        let row = tableView.selectedRow
        guard row >= 0, let rowView = tableView.rowView(atRow: row, makeIfNecessary: true),
              let window = view.window else { return nil }
        return window.convertToScreen(tableView.convert(rowView.frame, to: nil))
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

/// What one `setRows` call costs, decided from two id lists and the id the controller asked for -- no
/// AppKit, no view, no window. This is the part of the row motion that can be proven in-process: which
/// rows arrive, which leave, and where the selection lands. What the pose on a live row view *looks like*
/// cannot be, and the live pass owns that; `Tests/UnfoldTests/SidebarRowMotionTests.swift` says exactly
/// where the line falls.
struct SidebarRowDiff: Equatable {
    /// A row that arrived. `index` is its position in the new list, which is where its own baseline is.
    struct Arrival: Equatable {
        let id: UUID
        let index: Int
    }

    /// A row that left. `slotIndex` is the row index that now holds whatever took its place, and
    /// `collapses` says whether that slot really changed hands: one collapse per slot, and never a slot
    /// whose recycled row view is still showing the same combo.
    struct Departure: Equatable {
        let id: UUID
        let oldIndex: Int
        let slotIndex: Int?
        let collapses: Bool
    }

    /// Where the selection lands, and -- just as load-bearing -- whether the pane has to *say* it.
    enum Landing: Equatable {
        /// The id the controller asked for is still on screen. The table's own selection notification
        /// covers this and stays silent when the row index does not move, which is the point: a
        /// replacement edit must not re-display the editor under its own caret (Ruling Q).
        case requested(Int)
        /// Nothing to honour: the selected combo left the list, so the selection lands on its **neighbour**
        /// -- the row that now sits where it sat, clamped to the end of the list -- and the pane reports it,
        /// because a table that keeps the same row index for a different combo posts nothing.
        /// Two deletes with the confirmation unread used to land on row 0 and delete a combo nobody chose.
        case landed(Int)
        /// No rows at all.
        case empty
    }

    let arrivals: [Arrival]
    let departures: [Departure]
    let landing: Landing

    var isEmpty: Bool { arrivals.isEmpty && departures.isEmpty }

    static func between(previous: [UUID], next: [UUID], requested: UUID?) -> SidebarRowDiff {
        let leaving = Set(previous).subtracting(next)
        let arriving = Set(next).subtracting(previous)
        let arrivals = next.enumerated()
            .filter { arriving.contains($0.element) }
            .map { Arrival(id: $0.element, index: $0.offset) }

        var claimedSlots: Set<Int> = []
        var departures: [Departure] = []
        for (oldIndex, id) in previous.enumerated() where leaving.contains(id) {
            let slot = next.isEmpty ? nil : min(oldIndex, next.count - 1)
            // The slot changed hands only when a different combo now sits in it.
            let moved = slot.map { $0 < previous.count && previous[$0] != next[$0] } ?? false
            let unclaimed = slot.map { claimedSlots.insert($0).inserted } ?? true
            departures.append(Departure(id: id, oldIndex: oldIndex, slotIndex: slot,
                                        collapses: moved && unclaimed))
        }

        let landing: Landing
        if next.isEmpty {
            landing = .empty
        } else if let requested, let index = next.firstIndex(of: requested) {
            landing = .requested(index)
        } else {
            // The neighbour the deleted row leaves behind: where the selection *was* if that row is gone,
            // otherwise the first row that left. Both are indexes into the list that no longer has them,
            // so the landing is clamped to the end of the list that does.
            let anchor = requested.flatMap { previous.firstIndex(of: $0) } ?? departures.first?.oldIndex
            landing = .landed(min(anchor ?? 0, next.count - 1))
        }
        return SidebarRowDiff(arrivals: arrivals, departures: departures, landing: landing)
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
        triggerLabel.font = .monospacedSystemFont(ofSize: 12.5, weight: .medium)
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
