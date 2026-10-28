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
final class MainWindowController: NSWindowController, NSToolbarDelegate, NSWindowDelegate {
    private let coordinator: ExpansionCoordinator
    private let store: Store
    /// Built against the editor pane's Try-it field, so it waits until that pane's view exists --
    /// `init` loads it before anything reads this.
    private lazy var consistencyTest = ConsistencyTest(coordinator: coordinator,
                                                       textView: editor.tryTextView)

    private var file: CombosFile
    private var selectedID: UUID?

    private let splitView = NSSplitViewController()
    private let sidebar = SidebarViewController()
    private let editor = EditorViewController()
    /// The single source of the filter text. The pane holds no copy of it, so `addCombo` clearing the
    /// filter and the empty-state copy cannot disagree with what the list shows.
    private var filter = ""
    private let diagnosticsSummary = NSTextField(wrappingLabelWithString: "")
    private let testResult = NSTextField(labelWithString: "")

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

        // The panes' views must exist before anything reaches into their controls -- the window's
        // `initialFirstResponder`, the pane closures below, and the consistency test all do. Loading
        // them here makes that a contract instead of an accident of `assembleSplitView()` touching
        // `splitView.view` first.
        sidebar.loadViewIfNeeded()
        editor.loadViewIfNeeded()

        buildDiagnostics()
        assembleSplitView()
        installToolbar()
        restoreFrame(window)

        // The plumbing between the panes and the state they render. Installed before the first
        // `reloadRows()`, because that call puts a selection on screen and the controller has to hear
        // about it.
        sidebar.onSelect = { [weak self] id in
            self?.selectedID = id
            self?.redisplay()
        }
        sidebar.onFilter = { [weak self] needle in
            self?.filter = needle
            self?.reloadRows()
        }
        sidebar.onRequestEdit = { [weak self] in
            self?.editor.beginTriggerEdit()
        }
        editor.onEdit = { [weak self] edit in
            guard let self else { return }
            switch edit {
            case .trigger(let value):
                self.mutate { $0.trigger = value }
                self.reloadRows()
                self.redisplay()
            case .replacement(let text):
                // Deliberately not `redisplay()`: the user is typing in the replacement view right now,
                // and `editor.display(_:)` would rewrite its string under a mid-word caret. The hint
                // still refreshes, because the trigger's burn-down of this text just changed.
                do {
                    let parts = try Template.parse(text)
                    self.mutate { $0.parts = parts }
                    self.reloadRows()
                    if let combo = self.selected() {
                        self.editor.showHint(self.hint(for: combo), failure: false)
                    }
                } catch {
                    self.editor.showHint("Not saved — \(error)", failure: true)
                }
            case .insertion(let mode):
                self.mutate { $0.insertion = mode }
            case .enabled(let on):
                self.mutate { $0.enabled = on }
                self.reloadRows()
            }
        }

        // One-shot, because `store.url` is a `let` and a tooltip the user is reading must not be
        // rewritten by the status timer. `refreshStatus()` updates only the shortened label.
        editor.setPathTooltip(store.url.path)

        // The list, not the filter: an accidental keystroke should move the selection, not quietly
        // narrow the library to nothing.
        window.initialFirstResponder = sidebar.listTableView
        reloadRows()
        redisplay()
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
        // The panes are their own view controllers now, so they go in the split view directly instead
        // of through `host`. Their titles are set here because the diagnostics pane still gets its
        // title from `host(_:label:)`.
        sidebar.title = "Combos"
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 190
        sidebarItem.preferredThicknessFraction = 0.3
        sidebarItem.canCollapse = false
        splitView.addSplitViewItem(sidebarItem)

        editor.title = "Combo"
        let detail = NSSplitViewItem(viewController: editor)
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

    // MARK: - Editor

    /// Picks the selected combo and hands the editor pane both the combo and the hint. The hint text
    /// stays here: `hint(for:)` reads the whole library for duplicate triggers and uses `TriggerIndex`
    /// for rejections, so it is model logic, not pane logic.
    private func redisplay() {
        let combo = selected()
        editor.display(combo)
        editor.showHint(combo.map(hint(for:)) ?? emptySelectionMessage, failure: false)
    }

    /// The three-way empty-selection copy, unchanged: it depends on `file.combos.isEmpty` and the
    /// filter, neither of which the editor pane knows about.
    private var emptySelectionMessage: String {
        if file.combos.isEmpty {
            return "No combos yet. Choose Add Combo in the toolbar, or press ⌘N."
        } else if sidebar.isEmptyList {
            // The pane's visible list is the filtered one, so this cannot disagree with what the list
            // shows; `filter` is the text behind it.
            return "Nothing matches «\(filter)»."
        }
        return "Select a combo in the sidebar."
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
        sidebar.clearFilter()
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
        // The filter was just cleared, so the list is the whole library in file order and the combo's
        // index in `file.combos` is its row.
        if let row = file.combos.firstIndex(where: { $0.id == combo.id }) {
            sidebar.listTableView.scrollRowToVisible(row)
        }
        redisplay()
        editor.beginTriggerEdit()
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
            self.redisplay()
        }
    }

    @discardableResult
    private func apply() -> Bool {
        do {
            try store.save(file)
        } catch {
            editor.showHint("Could not save — \(error)", failure: true)
            NSSound.beep()
            return false
        }
        coordinator.reload(combos: file.combos)
        refreshStatus()
        return true
    }

    /// Rebuilds the filtered view and hands it to the pane: the controller filters, the pane renders.
    /// The filter matches what a person would type or remember: the trigger, the combo's own name, or
    /// the text it expands to.
    private func reloadRows() {
        let needle = filter.lowercased()
        let matching = needle.isEmpty ? file.combos : file.combos.filter {
            $0.trigger.lowercased().contains(needle) || $0.label.lowercased().contains(needle)
                || $0.preview.lowercased().contains(needle)
        }
        sidebar.setRows(matching, selecting: selectedID)
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
        editor.showPath(short: shortPath())
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
        editor.beginTryEdit()
        SyntheticKeys.selectAll()
        SyntheticKeys.type("addr ") { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self?.refreshStatus() }
        }
    }

    @objc private func testIdleTimeout() {
        show()
        editor.beginTryEdit()
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

private extension NSFont {
    /// The caption size on macOS. Ten points is the platform floor accessibility.md sets; 11 keeps
    /// secondary text legible without competing with the 13-point body.
    static func secondaryLabelFont() -> NSFont { .systemFont(ofSize: 11) }
}
