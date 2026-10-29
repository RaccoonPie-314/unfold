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
    /// The ids this pane last showed. Nothing reads it in this task: Task 11 diffs the incoming rows
    /// against it to decide which rows animate in and which animate out.
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

    /// Puts the selection back where it was. Row indexes are indexes into `visible`, never into
    /// `file.combos`, so a filter cannot make the editor select a combo that is not on screen.
    func setRows(_ rows: [Combo], selecting id: UUID?) {
        visible = rows
        tableView.reloadData()
        if let id, let index = visible.firstIndex(where: { $0.id == id }) {
            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else if let first = visible.first {
            onSelect?(first.id)
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        } else {
            onSelect?(nil)
        }
        shownIDs = visible.map(\.id)
    }

    /// The selected row's frame in screen coordinates -- the anchor the editor's morph starts from.
    var selectedRowFrame: CGRect? {
        let row = tableView.selectedRow
        guard row >= 0, let rowView = tableView.rowView(atRow: row, makeIfNecessary: false),
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
