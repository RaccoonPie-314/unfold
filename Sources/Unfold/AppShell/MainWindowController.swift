import AppKit
import UnfoldEngine
import UnfoldMac

/// The app's window: a sidebar of combos, an editor for the selected one, a field to try it in, and an
/// inspector for diagnostics.
///
/// The layout is the platform's, not an approximation of it. A split view with a sidebar item and a
/// unified toolbar is what gives the window the system's own materials -- the sidebar and the toolbar
/// float over the content and pick up whatever is behind them, which is the part of the Liquid Glass
/// look an app is allowed to have. `materials.md` is explicit about the rest: "Don't use Liquid Glass
/// in the content layer." So the editor, the list rows and the inspector are ordinary content on
/// ordinary materials, and nothing here draws a custom glass surface.
final class MainWindowController: NSWindowController, NSToolbarDelegate, NSTableViewDataSource,
                                  NSTableViewDelegate, NSTextFieldDelegate, NSSearchFieldDelegate,
                                  NSTextViewDelegate, NSWindowDelegate {
    private let coordinator: ExpansionCoordinator
    private let store: Store
    private let consistencyTest: ConsistencyTest

    private var file: CombosFile
    private var selectedID: UUID?

    private let splitView = NSSplitViewController()
    private let tableView = NSTableView()
    private let sidebarScroll = NSScrollView()
    private let searchField = NSSearchField()
    private var filter = ""
    private var visible: [Combo] = []
    private let triggerField = NSTextField(string: "")
    private let replacementScroll = NSScrollView()
    private let replacementView = NSTextView()
    private let insertionPopUp = NSPopUpButton()
    private let enabledCheck = NSButton(checkboxWithTitle: "Enabled", target: nil, action: nil)
    private let editorHint = NSTextField(wrappingLabelWithString: "")
    private let tryScroll = NSScrollView()
    private let tryView = NSTextView()
    private let diagnosticsSummary = NSTextField(wrappingLabelWithString: "")
    private let testResult = NSTextField(labelWithString: "")
    private let pathLabel = NSTextField(labelWithString: "")

    private var diagnosticsItem: NSSplitViewItem!
    private var pauseItem: NSToolbarItem?
    private var statusLabel: NSTextField?
    private var statusSymbol: NSImageView?
    private var statusItem: NSToolbarItem?
    private var addRemoveItems: [NSToolbarItem] = []
    private var statusTimer: Timer?

    // MARK: - Identity

    private static let add = NSToolbarItem.Identifier("unfold.add")
    private static let remove = NSToolbarItem.Identifier("unfold.remove")
    private static let pause = NSToolbarItem.Identifier("unfold.pause")
    private static let status = NSToolbarItem.Identifier("unfold.status")
    private static let diagnostics = NSToolbarItem.Identifier("unfold.diagnostics")

    init(coordinator: ExpansionCoordinator, store: Store) {
        self.coordinator = coordinator
        self.store = store
        self.file = (try? store.load())
            ?? CombosFile(formatVersion: CombosFile.currentFormatVersion, combos: [])
        self.consistencyTest = ConsistencyTest(coordinator: coordinator, textView: tryView)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        // "Don't title windows with your app name" -- the title says what is in the window.
        window.title = "Combos"
        window.titlebarAppearsTransparent = false
        window.minSize = NSSize(width: 700, height: 460)
        window.isReleasedWhenClosed = false
        // The window paints its own material (below), so the default opaque background has to go.
        // Without this the glass controls would have a flat colour behind them and nothing to refract.
        window.isOpaque = false
        window.backgroundColor = .clear
        // The autosaved frame is applied later, once the content view controller exists.

        super.init(window: window)
        window.delegate = self

        buildSidebar()
        buildDetail()
        buildDiagnostics()
        assembleSplitView()
        installToolbar()
        restoreFrame(window)
        // The list, not the filter: an accidental keystroke should move the selection, not quietly
        // narrow the library to nothing.
        window.initialFirstResponder = tableView
        reloadRows()
        loadEditor()
        refreshStatus()
        startStatusTimer()
    }

    /// Setting `contentViewController` resizes the window to the split view's fitting size -- the sum
    /// of the pane minimums, which is the smallest legal window, not the designed one. So the design
    /// size and the saved frame are applied afterwards, in that order.
    private func restoreFrame(_ window: NSWindow) {
        window.setContentSize(NSSize(width: 900, height: 580))
        (splitView.view as? NSSplitView)?.setPosition(218, ofDividerAt: 0)
        if !window.setFrameAutosaveName("UnfoldMainWindow") {
            window.center()
        }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    // MARK: - Construction

    private func buildSidebar() {
        tableView.headerView = nil
        tableView.selectionHighlightStyle = .sourceList
        tableView.style = .sourceList
        tableView.allowsMultipleSelection = false
        tableView.allowsEmptySelection = true
        tableView.usesAutomaticRowHeights = true
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(editTriggerFromList)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("combo"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)

        sidebarScroll.documentView = tableView
        sidebarScroll.hasVerticalScroller = true
        sidebarScroll.drawsBackground = false
        // The filter pill owns the strip under the toolbar, so the scroll view must not inset itself
        // for it as well.
        sidebarScroll.automaticallyAdjustsContentInsets = false

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
        sidebarContainer = container
    }

    private var sidebarContainer: NSView!

    private func buildDetail() {
        triggerField.delegate = self
        triggerField.placeholderString = "addr"
        triggerField.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        triggerField.target = self
        triggerField.action = #selector(commitTrigger)

        configure(replacementView, in: replacementScroll, monospaced: true)
        replacementView.delegate = self

        insertionPopUp.addItems(withTitles: ["Paste", "Type as keystrokes"])
        insertionPopUp.target = self
        insertionPopUp.action = #selector(commitInsertion)
        enabledCheck.target = self
        enabledCheck.action = #selector(commitEnabled)

        editorHint.font = .secondaryLabelFont()
        editorHint.textColor = .secondaryLabelColor
        editorHint.maximumNumberOfLines = 2
        editorHint.setContentHuggingPriority(.defaultLow, for: .vertical)

        configure(tryView, in: tryScroll, monospaced: false)

        pathLabel.font = .secondaryLabelFont()
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.stringValue = shortPath()
        pathLabel.toolTip = store.url.path
        pathLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        // Two columns, pinned by hand rather than by stack views: an 82-point caption column that
        // right-aligns, a 12-point gutter, and controls that take everything left over. Stack views
        // distribute their slack through gravity areas, which let the caption column drift a few
        // hundred points sideways while still reporting a satisfied layout.
        let triggerCaption = caption("Trigger")
        let replacementCaption = caption("Replacement")
        let tryCaption = caption("Try it")
        let container = NSView()
        let views = [triggerCaption, replacementCaption, tryCaption, triggerField, editorHint,
                     replacementScroll, insertionPopUp, enabledCheck, tryScroll, pathLabel]
        views.forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview($0)
        }

        let guide = container.safeAreaLayoutGuide
        // Pane padding + the 82-point caption column, and the same plus a 12-point gutter.
        let captionColumn: CGFloat = 24 + 82
        let controlColumn: CGFloat = captionColumn + 12

        NSLayoutConstraint.activate([
            triggerCaption.trailingAnchor.constraint(equalTo: guide.leadingAnchor, constant: captionColumn),
            replacementCaption.trailingAnchor.constraint(equalTo: guide.leadingAnchor,
                                                         constant: captionColumn),
            tryCaption.trailingAnchor.constraint(equalTo: guide.leadingAnchor, constant: captionColumn),

            triggerField.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: controlColumn),
            editorHint.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: controlColumn),
            replacementScroll.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: controlColumn),
            insertionPopUp.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: controlColumn),
            tryScroll.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: controlColumn),
            triggerField.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -24),
            editorHint.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -24),
            replacementScroll.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -24),
            tryScroll.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -24),
            pathLabel.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: 24),
            pathLabel.trailingAnchor.constraint(equalTo: guide.trailingAnchor, constant: -24),

            triggerField.topAnchor.constraint(equalTo: guide.topAnchor, constant: 20),
            triggerCaption.centerYAnchor.constraint(equalTo: triggerField.centerYAnchor),
            editorHint.topAnchor.constraint(equalTo: triggerField.bottomAnchor, constant: 4),

            replacementScroll.topAnchor.constraint(equalTo: editorHint.bottomAnchor, constant: 16),
            replacementScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 110).withPriority(750),
            replacementCaption.topAnchor.constraint(equalTo: replacementScroll.topAnchor, constant: 3),
            insertionPopUp.topAnchor.constraint(equalTo: replacementScroll.bottomAnchor, constant: 10),
            enabledCheck.leadingAnchor.constraint(equalTo: insertionPopUp.trailingAnchor, constant: 10),
            enabledCheck.centerYAnchor.constraint(equalTo: insertionPopUp.centerYAnchor),

            tryScroll.topAnchor.constraint(equalTo: insertionPopUp.bottomAnchor, constant: 18),
            tryScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 80).withPriority(750),
            tryCaption.topAnchor.constraint(equalTo: tryScroll.topAnchor, constant: 3),

            pathLabel.topAnchor.constraint(equalTo: tryScroll.bottomAnchor, constant: 14),
            pathLabel.bottomAnchor.constraint(equalTo: guide.bottomAnchor, constant: -14),

            // The spare height the window has left over goes to the two text areas equally. Left to
            // their own devices, the lower one absorbs all of it and the editor looks lopsided.
            tryScroll.heightAnchor.constraint(equalTo: replacementScroll.heightAnchor).withPriority(250),
        ])
        for scroll in [replacementScroll, tryScroll] {
            scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
            scroll.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        }
        detailContainer = container
    }

    private var detailContainer: NSView!

    private func buildDiagnostics() {
        diagnosticsSummary.font = .secondaryLabelFont()
        diagnosticsSummary.textColor = .secondaryLabelColor
        diagnosticsSummary.isSelectable = true
        diagnosticsSummary.maximumNumberOfLines = 0
        diagnosticsSummary.setContentHuggingPriority(.defaultLow, for: .horizontal)

        testResult.font = .secondaryLabelFont()
        testResult.textColor = .secondaryLabelColor
        testResult.alignment = .left

        let run = pushButton("Run consistency test", #selector(runConsistencyTest))
        let stress = pushButton("Stress test (40)", #selector(runStressTest))
        let selfTest = pushButton("Self-test", #selector(runSelfTest))
        let idle = pushButton("Idle timeout", #selector(testIdleTimeout))
        let controlC = pushButton("Ctrl-C in Terminal", #selector(testControlC))
        let restart = pushButton("Restart tap", #selector(restartTap))
        let relaunch = pushButton("Relaunch", #selector(relaunch))
        let revealApp = pushButton("Reveal app", #selector(revealApp))

        let buttons = [run, stress, selfTest, idle, controlC, restart, relaunch, revealApp]
        buttons.forEach { $0.translatesAutoresizingMaskIntoConstraints = false }
        let column = NSStackView(views: buttons)
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 6
        buttons.forEach { $0.widthAnchor.constraint(greaterThanOrEqualToConstant: 190).isActive = true }

        let stack = NSStackView(views: [
            section("Diagnostics"), diagnosticsSummary,
            Glass.wrap(column, cornerRadius: 10, padding: 8), testResult,
        ])
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            // The safe area, not the top edge: this pane also starts under the unified toolbar.
            stack.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor),
        ])
        diagnosticsContainer = container
    }

    private var diagnosticsContainer: NSView!

    private func assembleSplitView() {
        let sidebar = NSSplitViewItem(sidebarWithViewController: host(sidebarContainer, label: "Combos"))
        sidebar.minimumThickness = 190
        sidebar.preferredThicknessFraction = 0.3
        sidebar.canCollapse = false
        splitView.addSplitViewItem(sidebar)

        let detail = NSSplitViewItem(viewController: host(detailContainer, label: "Combo"))
        detail.minimumThickness = 380
        splitView.addSplitViewItem(detail)

        diagnosticsItem = NSSplitViewItem(viewController: host(diagnosticsContainer, label: "Diagnostics"))
        diagnosticsItem.minimumThickness = 230
        diagnosticsItem.canCollapse = true
        diagnosticsItem.isCollapsed = true
        splitView.addSplitViewItem(diagnosticsItem)

        // The split view sits on a window-wide material instead of the opaque default background, so
        // the desktop reads through the panes and the glass controls have something to sample.
        let root = NSViewController()
        root.view = Glass.windowBackground()
        root.addChild(splitView)
        let split = splitView.view
        split.translatesAutoresizingMaskIntoConstraints = false
        root.view.addSubview(split)
        NSLayoutConstraint.activate([
            split.leadingAnchor.constraint(equalTo: root.view.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: root.view.trailingAnchor),
            split.topAnchor.constraint(equalTo: root.view.topAnchor),
            split.bottomAnchor.constraint(equalTo: root.view.bottomAnchor),
        ])
        window?.contentViewController = root
    }

    private func installToolbar() {
        let toolbar = NSToolbar(identifier: NSToolbar.Identifier("UnfoldMainToolbar"))
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = true
        toolbar.centeredItemIdentifier = nil
        window?.toolbar = toolbar
        window?.toolbarStyle = .unified
    }

    /// A view controller wrapping a view, so the split view items can host plain views and the
    /// sidebar material applies to the whole pane.
    private func host(_ view: NSView, label: String) -> NSViewController {
        let controller = NSViewController()
        controller.title = label
        controller.view = view
        return controller
    }

    private func configure(_ textView: NSTextView, in scroll: NSScrollView, monospaced: Bool) {
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.font = monospaced ? .monospacedSystemFont(ofSize: 13, weight: .regular)
                                   : .systemFont(ofSize: 13)
        textView.isVerticallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = true
        scroll.borderType = .bezelBorder
    }

    private func caption(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        label.alignment = .right
        return label
    }

    private func vstack(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        return stack
    }

    private func section(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .secondaryLabelColor
        // Explicit: a label stretched to its container's width by a stack view otherwise resolves
        // `.natural` alignment against its own writing direction and lands the text on the right.
        label.alignment = .left
        return label
    }

    private func pushButton(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: self, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        return button
    }

    // MARK: - Toolbar

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch identifier {
        case Self.add:
            return symbolItem(identifier, "plus", "Add Combo", #selector(addCombo(_:)))
        case Self.remove:
            return symbolItem(identifier, "minus", "Delete Combo", #selector(deleteCombo(_:)))
        case Self.pause:
            let item = symbolItem(identifier, "pause.fill", "Pause Expansion", #selector(toggleExpansionPaused(_:)))
            pauseItem = item
            return item
        case Self.diagnostics:
            return symbolItem(identifier, "stethoscope", "Show Diagnostics", #selector(toggleDiagnostics(_:)))
        case Self.status:
            return buildStatusItem(identifier)
        default:
            return nil
        }
    }

    private func symbolItem(_ identifier: NSToolbarItem.Identifier, _ symbol: String, _ label: String,
                            _ action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = label
        item.paletteLabel = label
        item.toolTip = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.target = self
        item.action = action
        item.isBordered = true
        return item
    }

    /// The one place colour is spent: a status indicator, which `color.md › Liquid Glass color` names
    /// as a legitimate use. The symbol carries the meaning too, so colour is never the only signal.
    private func buildStatusItem(_ identifier: NSToolbarItem.Identifier) -> NSToolbarItem {
        let symbol = NSImageView()
        symbol.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        symbol.setContentHuggingPriority(.required, for: .horizontal)
        let text = NSTextField(labelWithString: "…")
        text.font = .systemFont(ofSize: 11, weight: .medium)
        let stack = NSStackView(views: [symbol, text])
        stack.orientation = .horizontal
        stack.spacing = 5
        statusSymbol = symbol
        statusLabel = text

        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = "Status"
        item.paletteLabel = "Status"
        item.view = Glass.wrap(stack, cornerRadius: 13, padding: 6)
        statusItem = item
        return item
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, Self.add, Self.remove,
         .flexibleSpace, Self.pause, Self.status, Self.diagnostics]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, Self.add, Self.remove, Self.pause,
         Self.status, Self.diagnostics, .flexibleSpace, .space]
    }

    func toolbar(_ toolbar: NSToolbar, validateItem item: NSToolbarItem) {
        if item.itemIdentifier == Self.remove || item.itemIdentifier == Self.add {
            item.isEnabled = true
        }
        addRemoveItems.forEach { $0.isEnabled = true }
    }

    // MARK: - Library list

    func numberOfRows(in tableView: NSTableView) -> Int { visible.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row < visible.count else { return nil }
        let cell = ComboRowView.dequeue(from: tableView)
        cell.apply(visible[row])
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        selectedID = (row >= 0 && row < visible.count) ? visible[row].id : nil
        loadEditor()
    }

    /// The filter matches what a person would type or remember: the trigger, the combo's own name, or
    /// the text it expands to.
    func controlTextDidChange(_ notification: Notification) {
        guard (notification.object as? NSControl) === searchField else { return }
        filter = searchField.stringValue
        reloadRows()
    }

    // MARK: - Editor

    private func loadEditor() {
        guard let combo = selected() else {
            triggerField.stringValue = ""
            replacementView.string = ""
            triggerField.isEnabled = false
            replacementView.isEditable = false
            insertionPopUp.isEnabled = false
            enabledCheck.state = .off
            let emptyMessage: String
            if file.combos.isEmpty {
                emptyMessage = "No combos yet. Choose Add Combo in the toolbar, or press ⌘N."
            } else if visible.isEmpty {
                emptyMessage = "Nothing matches «\(filter)»."
            } else {
                emptyMessage = "Select a combo in the sidebar."
            }
            showHint(emptyMessage, red: false)
            return
        }
        triggerField.isEnabled = true
        replacementView.isEditable = true
        insertionPopUp.isEnabled = true
        triggerField.stringValue = combo.trigger
        replacementView.string = Template.serialize(combo.parts)
        insertionPopUp.selectItem(withTitle: combo.insertion == .paste ? "Paste" : "Type as keystrokes")
        enabledCheck.state = combo.enabled ? .on : .off
        showHint(hint(for: combo), red: false)
    }

    private func selected() -> Combo? {
        guard let selectedID else { return nil }
        return file.combos.first { $0.id == selectedID }
    }

    private func hint(for combo: Combo) -> String {
        guard !combo.trigger.isEmpty else { return "A trigger cannot be empty." }
        if let rejection = TriggerIndex(combos: [combo]).rejections.first {
            return "This trigger cannot fire: \(rejection.problem.description)"
        }
        if file.combos.contains(where: { $0.id != combo.id && $0.trigger == combo.trigger }) {
            return "Another combo already uses «\(combo.trigger)»."
        }
        if combo.trigger != combo.trigger.lowercased() {
            return "Matching is case-sensitive: «\(combo.trigger)» only fires on that exact spelling."
        }
        return "Saves as you type. A space, comma, period or return fires the trigger."
    }

    private func showHint(_ text: String, red: Bool) {
        editorHint.stringValue = text
        editorHint.textColor = red ? .systemRed : .secondaryLabelColor
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        if (notification.object as? NSControl) === triggerField { commitTrigger() }
    }

    /// "Saves as you type" is the promise the hint makes, so the replacement commits on change rather
    /// than on focus loss. It deliberately does not reload the editor: rewriting the string under a
    /// caret that is mid-word moves the caret to the end.
    func textDidChange(_ notification: Notification) {
        guard (notification.object as? NSTextView) === replacementView else { return }
        commitReplacement(replacementView.string)
    }

    @objc private func commitTrigger() {
        let wanted = triggerField.stringValue
        mutate { $0.trigger = wanted }
        reloadRows()
        loadEditor()
    }

    @objc private func commitInsertion() {
        let mode: InsertionMode = insertionPopUp.indexOfSelectedItem == 0 ? .paste : .keys
        mutate { $0.insertion = mode }
    }

    @objc private func commitEnabled() {
        let wanted = enabledCheck.state == .on
        mutate { $0.enabled = wanted }
        reloadRows()
    }

    private func commitReplacement(_ text: String) {
        do {
            let parts = try Template.parse(text)
            mutate { $0.parts = parts }
            reloadRows()
            if let combo = selected() { showHint(hint(for: combo), red: false) }
        } catch {
            showHint("Not saved — \(error)", red: true)
        }
    }

    private func mutate(_ change: (inout Combo) -> Void) {
        guard let selectedID, let index = file.combos.firstIndex(where: { $0.id == selectedID }) else { return }
        change(&file.combos[index])
        if file.combos[index].label.isEmpty { file.combos[index].label = file.combos[index].trigger }
        apply()
    }

    /// Menu and toolbar target for adding a combo.
    @objc func newCombo(_ sender: Any?) { addCombo(sender) }

    @objc private func addCombo(_ sender: Any?) {
        // A new combo is named "new", which a half-typed filter would hide. Clear it rather than
        // letting the user add a combo that appears not to have been added.
        filter = ""
        searchField.stringValue = ""
        let previousID = selectedID
        // No replacement is `parts: []`, not `.text("")`: the plain-text form drops an empty part, so
        // the store refuses to write one. An empty label takes the trigger as its name on the first
        // edit, which is what `mutate` already does for a name nobody has typed.
        let combo = Combo(id: UUID(), trigger: "new", label: "", enabled: true,
                          parts: [], insertion: .paste)
        file.combos.append(combo)
        selectedID = combo.id
        // A combo that never reached the file must not stay in memory either: it is the one thing every
        // later save validates against, so keeping it would make the whole library unsavable.
        guard apply() else {
            file.combos.removeAll { $0.id == combo.id }
            selectedID = previousID
            return
        }
        reloadRows()
        if let row = visible.firstIndex(where: { $0.id == combo.id }) {
            tableView.scrollRowToVisible(row)
        }
        loadEditor()
        window?.makeFirstResponder(triggerField)
        triggerField.selectText(nil)
    }

    @objc func deleteCombo(_ sender: Any?) {
        guard let combo = selected() else { return }
        let alert = NSAlert()
        alert.messageText = "Delete «\(combo.trigger)»?"
        alert.informativeText = "It is removed from \(shortPath()). This cannot be undone."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window!) { [weak self] response in
            guard response == .alertFirstButtonReturn, let self else { return }
            let before = self.file.combos
            let previousID = self.selectedID
            self.file.combos.removeAll { $0.id == combo.id }
            self.selectedID = nil
            // A refused write has to put the row back, or the list shows a library the file does not
            // have and the deleted combo returns on the next launch.
            if !self.apply() {
                self.file.combos = before
                self.selectedID = previousID
            }
            self.reloadRows()
            self.loadEditor()
        }
    }

    @discardableResult
    private func apply() -> Bool {
        do {
            try store.save(file)
        } catch {
            showHint("Could not save — \(error)", red: true)
            NSSound.beep()
            return false
        }
        coordinator.reload(combos: file.combos)
        refreshStatus()
        return true
    }

    /// Rebuilds the filtered view and puts the selection back where it was. Row indexes are indexes
    /// into `visible`, never into `file.combos`, so a filter cannot make the editor select a combo
    /// that is not on screen.
    private func reloadRows() {
        let previous = selectedID
        let needle = filter.lowercased()
        visible = needle.isEmpty ? file.combos : file.combos.filter {
            $0.trigger.lowercased().contains(needle) || $0.label.lowercased().contains(needle)
                || $0.preview.lowercased().contains(needle)
        }
        tableView.reloadData()
        if let previous, let index = visible.firstIndex(where: { $0.id == previous }) {
            tableView.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false)
        } else if let first = visible.first {
            selectedID = first.id
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        } else {
            selectedID = nil
        }
    }

    @objc private func editTriggerFromList() {
        window?.makeFirstResponder(triggerField)
        triggerField.selectText(nil)
    }

    // MARK: - Status

    private func startStatusTimer() {
        statusTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refreshStatus()
        }
    }

    private func refreshStatus() {
        let trusted = PermissionFlow.isTrusted
        let state: (symbol: String, text: String, color: NSColor)
        if !trusted {
            state = ("exclamationmark.triangle.fill", "Grant access", .systemRed)
        } else if coordinator.isPaused {
            state = ("pause.circle.fill", "Paused", .systemOrange)
        } else {
            switch coordinator.tapState {
            case .detached, .disabled:
                state = ("slash.circle.fill", "Tap off", .systemOrange)
            case .givenUp:
                state = ("exclamationmark.triangle.fill", "Tap stopped", .systemRed)
            case .live:
                state = coordinator.isTapEnabled
                    ? ("checkmark.circle.fill", "Ready", .systemGreen)
                    : ("exclamationmark.circle.fill", "Tap disabled", .systemOrange)
            }
        }
        statusSymbol?.image = NSImage(systemSymbolName: state.symbol, accessibilityDescription: state.text)
        statusSymbol?.contentTintColor = state.color
        statusLabel?.stringValue = state.text
        statusLabel?.textColor = state.color
        statusItem?.toolTip = "\(state.text) — \(coordinator.keystrokesSeen) keystrokes, "
            + "\(coordinator.tapDisableObservations) tap switch-offs"
        pauseItem?.image = NSImage(systemSymbolName: coordinator.isPaused ? "play.fill" : "pause.fill",
                                   accessibilityDescription: coordinator.isPaused ? "Resume" : "Pause")
        pauseItem?.label = coordinator.isPaused ? "Resume" : "Pause"
        pathLabel.stringValue = shortPath()
        diagnosticsSummary.stringValue =
            "Keystrokes seen \(coordinator.keystrokesSeen)\n"
            + "Tap switched off by macOS \(coordinator.tapDisableObservations)×\n"
            + "Combos \(coordinator.activeCount) live, \(coordinator.inactivePlaceholderCount) need the prompt UI\n"
            + "Last event \(coordinator.lastRouting ?? "none")\n"
            + "Last expansion \(coordinator.lastExpansion.map { "«\($0.replacingOccurrences(of: "\n", with: "⏎"))»" } ?? "—")"
        testResult.stringValue = consistencyTest.summary
    }

    private func shortPath() -> String {
        store.url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    // MARK: - Commands

    @objc func toggleExpansionPaused(_ sender: Any?) {
        if coordinator.isPaused {
            coordinator.resume()
            _ = coordinator.attachTap()
        } else {
            coordinator.pause()
            coordinator.detachTap()
        }
        refreshStatus()
    }

    @objc func toggleDiagnostics(_ sender: Any?) {
        guard let diagnosticsItem else { return }
        diagnosticsItem.isCollapsed.toggle()
    }

    @objc func revealCombos(_ sender: Any?) {
        NSWorkspace.shared.activateFileViewerSelecting([store.url])
    }

    @objc private func revealApp() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    @objc private func restartTap() {
        _ = coordinator.restartTap()
        refreshStatus()
    }

    @objc private func relaunch() {
        let path = Bundle.main.bundlePath
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", "sleep 0.6; /usr/bin/open \"\(path)\""]
        try? helper.run()
        NSApp.terminate(nil)
    }

    // MARK: - Diagnostics actions

    @objc private func runSelfTest() {
        show()
        window?.makeFirstResponder(tryView)
        tryView.string = ""
        SyntheticKeys.selectAll()
        SyntheticKeys.type("addr ") { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self?.refreshStatus() }
        }
    }

    @objc private func testIdleTimeout() {
        show()
        window?.makeFirstResponder(tryView)
        tryView.string = ""
        SyntheticKeys.type("ad") { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 9.5) {
                self?.refreshStatus()
                launchLog("idle timeout test survived")
            }
        }
    }

    @objc private func testControlC() {
        window?.orderOut(nil)
        let terminal = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Terminal").first
        terminal?.activate(options: [.activateAllWindows])
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            SyntheticKeys.controlC()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.show()
                self?.refreshStatus()
            }
        }
    }

    @objc private func runConsistencyTest() {
        show()
        consistencyTest.start(roundsPerCase: 2) { [weak self] summary in
            self?.testResult.stringValue = summary
        }
    }

    @objc private func runStressTest() {
        show()
        consistencyTest.start(stressRounds: 40) { [weak self] summary in
            self?.testResult.stringValue = summary
        }
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
        previewLabel.font = .systemFont(ofSize: 11)
        previewLabel.textColor = .secondaryLabelColor
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
        // Secondary, not tertiary: tertiary label on a window background measures about 2.3:1, under
        // the 4.5:1 floor accessibility.md sets for text up to 17 pt.
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
    fileprivate var preview: String {
        parts.reduce(into: "") { result, part in
            switch part {
            case .text(let value): result += value
            case .placeholder(let placeholder): result += "[\(placeholder.id)]"
            }
        }.replacingOccurrences(of: "\n", with: "⏎")
    }
}

private extension NSLayoutConstraint {
    /// Sets the priority inline, so a list of activated constraints reads with its own breakability.
    func withPriority(_ priority: Float) -> NSLayoutConstraint {
        self.priority = NSLayoutConstraint.Priority(priority)
        return self
    }
}

private extension NSFont {
    /// The caption size on macOS. Ten points is the platform floor accessibility.md sets; 11 keeps
    /// secondary text legible without competing with the 13-point body.
    static func secondaryLabelFont() -> NSFont { .systemFont(ofSize: 11) }
}
