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
    /// Internal rather than private: `SelectionOverlayTests` read `selectedRowFrame` through the real
    /// pane the controller assembled to know where the morph's source rect is. Nothing outside this
    /// file drives the panes.
    let sidebar = SidebarViewController()
    /// Internal for the same reason as `sidebar`: the tests pin the morph's landing to the trigger
    /// field's own frame, which only the pane can answer.
    let editor = EditorViewController()
    private let diagnostics = DiagnosticsViewController()
    /// The selection morph's line (Ruling AG): a 1 pt separator hosted by the window's **own content
    /// view** -- the common unclipped ancestor of the sidebar and the editor -- rather than a proxy
    /// inside the editor pane. The pane version was clipped: `MotionDriverTests`-style measurement in
    /// Task 11b §5.2 found the split view's `_NSSplitViewItemViewWrapper` has `masksToBounds == true`,
    /// and this morph's `k ≈ 40` start pose is a row-sized bar sitting on the *sidebar*, so the pane
    /// cut it and the line popped in at the pane's left edge instead of travelling. Internal rather
    /// than private because the overlay tests read this view's geometry; only this controller installs
    /// and morphs it.
    let selectionOverlay = SelectionOverlayLineView()
    /// The single source of the filter text. The pane holds no copy of it, so `addCombo` clearing the
    /// filter and the empty-state copy cannot disagree with what the list shows.
    private var filter = ""

    private var diagnosticsItem: NSSplitViewItem!
    private var pauseItem: NSToolbarItem?
    private var statusLabel: NSTextField?
    private var statusSymbol: NSImageView?
    /// The pill's symbol + label, kept so `statusMorph` can animate the surface whose width changes.
    private var statusStack: NSStackView?
    private var statusItem: NSToolbarItem?
    private var addRemoveItems: [NSToolbarItem] = []
    private var statusTimer: Timer?
    /// The status the pill was last rendered for. `refreshStatus` runs once a second; this is what
    /// lets an unchanged tick skip the pill's rewrite instead of re-setting identical values.
    private var lastRenderedStatus: MenuStatus?

    // MARK: - Identity

    private static let add = NSToolbarItem.Identifier("unfold.add")
    private static let remove = NSToolbarItem.Identifier("unfold.remove")
    private static let pause = NSToolbarItem.Identifier("unfold.pause")
    private static let status = NSToolbarItem.Identifier("unfold.status")
    private static let diagnostics = NSToolbarItem.Identifier("unfold.diagnostics")

    /// The status pill's glyph size, spelled once: `buildStatusItem` starts with it and `refreshStatus`
    /// composes the status colour onto the same value instead of re-typing the numbers.
    private static let statusSymbolSize = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)

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
        // `initialFirstResponder`, the pane closures below, the consistency test and the first
        // `refreshStatus()` (which assigns both diagnostics strings) all do. Loading them here makes
        // that a contract instead of an accident of `assembleSplitView()` touching `splitView.view`
        // first.
        sidebar.loadViewIfNeeded()
        editor.loadViewIfNeeded()
        diagnostics.loadViewIfNeeded()

        assembleSplitView()
        installToolbar()
        restoreFrame(window)

        // The plumbing between the panes and the state they render. Installed before the first
        // `reloadRows()`, because that call puts a selection on screen and the controller has to hear
        // about it.
        sidebar.onSelect = { [weak self] id in
            guard let self else { return }
            self.morphSelectionIntoTriggerField()
            self.selectedID = id
            self.redisplay()
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
        // Order matters and is not incidental: this is the only call that puts the full path in the
        // tooltip at all, so it has to stay ahead of the first `refreshStatus()` below.
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

    private func assembleSplitView() {
        // All three panes are view controllers of their own now, so they go into the split view
        // directly; their titles are set here because the split view item takes it from the controller.
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

        diagnostics.title = "Diagnostics"
        diagnosticsItem = NSSplitViewItem(viewController: diagnostics)
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
        // Ruling AG: install the selection line at the window level, above the split view. The content
        // view is the common unclipped ancestor of both panes (`SelectionOverlayTests` measures that
        // its layer does not clip; the per-pane `_NSSplitViewItemViewWrapper` does). It ships hidden
        // (Ruling R) and every morph re-pins its frame before installing the pose, so there is no
        // autoresizing to maintain -- a resting overlay draws nothing either way.
        if let content = window?.contentView {
            selectionOverlay.isHidden = true
            content.addSubview(selectionOverlay)
        }
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
        symbol.symbolConfiguration = Self.statusSymbolSize
        symbol.setContentHuggingPriority(.required, for: .horizontal)
        let text = NSTextField(labelWithString: "…")
        text.font = .systemFont(ofSize: 11, weight: .medium)
        let stack = NSStackView(views: [symbol, text])
        stack.orientation = .horizontal
        stack.spacing = 5
        statusSymbol = symbol
        statusLabel = text
        statusStack = stack

        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = "Status"
        item.paletteLabel = "Status"
        item.view = Glass.wrap(stack, cornerRadius: Theme.Radius.pill, padding: 6)
        statusItem = item
        // Toolbar customization can rebuild this item after the fact, and the fresh stack shows "..."
        // until something rewrites it. The change-memo would otherwise wait for the status to differ,
        // so clear it and render once now: the pill self-heals like it did before the memo existed.
        lastRenderedStatus = nil
        refreshStatus()
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

    // MARK: - Motion

    /// `selectionMorph` -- the one transition whose source and destination live in different panes, so it
    /// runs from here: the sidebar row the user just picked is the source, the editor's trigger field is
    /// the destination, and neither pane can see the other.
    ///
    /// It animates the window-level `selectionOverlay` (Ruling AG), never a control. The overlay is a
    /// 1 pt separator line whose only layout is the frame written here at morph time -- the field-wide,
    /// 1 pt-tall, centre-line rect the pane-hosted proxy used to get from its constraints -- and re-laying
    /// out a real control the user may be typing into is what moved the caret the last time a morph
    /// touched an editor control. It ships hidden (Ruling R), is unhidden before the pose is installed
    /// and put back by `Motion.morph`'s identity-guarded completion, so a fast series of selections
    /// hides the line exactly once, at the end, and an interrupted morph's completion never hides the
    /// one that replaced it. That pairing is the whole reason the completion is passed to `Motion.morph`
    /// rather than chased by a second timer.
    private func morphSelectionIntoTriggerField() {
        guard let morph = MotionPlan.lookup(.selectionMorph),
              let from = sidebar.selectedRowFrame,
              let to = editor.triggerFieldFrameInWindow,
              to != from,
              let window, window.isVisible,
              let host = selectionOverlay.superview else { return }
        // Both accessors answer in *screen* coordinates, because they cross panes; what the driver needs
        // is each rect in the space the overlay's own `frame` lives in -- `MotionGeometry.morph` compares
        // the two rects, so a screen-space rect beside a superview-space one would fling the pose a whole
        // window-height away from where the user is looking. Down through the window, then into the host.
        let source = host.convert(window.convertFromScreen(from), from: nil)
        let landing = host.convert(window.convertFromScreen(to), from: nil)
        selectionOverlay.frame = CGRect(x: landing.minX, y: landing.midY - 0.5,
                                        width: landing.width, height: 1)
        selectionOverlay.isHidden = false
        Motion.morph(selectionOverlay, source: source, transition: morph) { [weak self] in
            self?.selectionOverlay.isHidden = true
        }
    }

    /// `statusMorph`: the pill's *width* is the motion -- the label re-measures when the status changes --
    /// so the morph only runs on a tick that both changed the status (the memo in `refreshStatus` handles
    /// that) and actually re-measured the pill. Two statuses share `Tap off`, and a status whose symbol
    /// changes but whose text does not has no geometry to travel, so this returns without animating rather
    /// than installing an identity→identity clip.
    ///
    /// - Parameter previous: the pill stack's frame *before* the label and glyph were rewritten.
    private func morphStatusPill(from previous: CGRect?) {
        guard let morph = MotionPlan.lookup(.statusMorph),
              let stack = statusStack,
              let previous,
              stack.window?.isVisible == true else { return }
        // The pill's width is re-measured by the toolbar, not by the stack: measured here, a synchronous
        // `layoutSubtreeIfNeeded()` straight after the label change still reported the *old* 43 pt frame,
        // and the new 188.5 pt one only appeared one main-queue turn later. Morphing onto a rect the view
        // is about to leave is the jump `Motion` exists to prevent, so the landing rect is read after the
        // turn that produces it. This defers a *measurement*; the animation still retargets whatever is
        // in flight, which is `Motion.morph`'s own interrupt behaviour.
        DispatchQueue.main.async { [weak stack] in
            guard let stack else { return }
            let final = stack.frame
            guard final != previous,
                  previous.width > 0, previous.height > 0,
                  final.width > 0, final.height > 0 else { return }
            Motion.morph(stack, source: previous, transition: morph)
        }
    }

    // MARK: - Status

    private func startStatusTimer() {
        statusTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.refreshStatus()
        }
    }

    private func refreshStatus() {
        // One status vocabulary, two surfaces (Ruling B): the pill used to re-derive its own
        // `(symbol, text, color)` from the same inputs by a second switch, which could -- and did
        // drift in colour -- from the menu's tested decision. `MenuStatus.evaluate` is now the only
        // place the shell decides what the status means; everything below only renders it.
        let status = MenuStatus.evaluate(isTrusted: PermissionFlow.isTrusted,
                                         isPaused: coordinator.isPaused,
                                         tapState: coordinator.tapState,
                                         isTapEnabled: coordinator.isTapEnabled)
        // `refreshStatus` runs once a second; the pill's visible parts are rewritten only when the
        // status actually changed, so an unchanged second costs nothing and Task 11's later
        // `statusMorph` can fire off this same inequality without ever animating on a no-op tick.
        if status != lastRenderedStatus {
            // The pill's frame *before* the rewrite is the morph's source: `statusMorph` is a width
            // change, and the width that matters is the one the user was looking at a moment ago.
            let previousFrame = statusStack?.frame
            lastRenderedStatus = status
            statusSymbol?.image = NSImage(systemSymbolName: status.symbolName,
                                          accessibilityDescription: status.text)
            // The vocabulary's colour spent twice on the same glyph: as the image view's tint (approved in
            // Ruling B's rendering) and as the symbol's hierarchical colour, so the replacement reads as
            // one glyph morphing into the next rather than two images swapping.
            statusSymbol?.symbolConfiguration = Self.statusSymbolSize.applying(
                NSImage.SymbolConfiguration(hierarchicalColor: status.emphasisColor))
            statusSymbol?.contentTintColor = status.emphasisColor
            statusLabel?.stringValue = status.shortText
            // Monochrome label: the label has to be readable on its own, and only red clears the
            // glyph floor in Light mode, so the broken states are coloured and the working ones
            // are not.
            statusLabel?.textColor = .labelColor
            morphStatusPill(from: previousFrame)
        }
        // Counts move under an unchanged status, so the tooltip refreshes every tick as before.
        statusItem?.toolTip = "\(status.text) — \(coordinator.keystrokesSeen) keystrokes, "
            + "\(coordinator.tapDisableObservations) tap switch-offs"
        pauseItem?.image = NSImage(systemSymbolName: coordinator.isPaused ? "play.fill" : "pause.fill",
                                   accessibilityDescription: coordinator.isPaused ? "Resume" : "Pause")
        pauseItem?.label = coordinator.isPaused ? "Resume" : "Pause"
        editor.showPath(short: shortPath())
        // The strings are built here, not in the pane: they come from the coordinator, which the pane
        // does not know exists. The pane renders the two it is given.
        diagnostics.summary =
            "Keystrokes seen \(coordinator.keystrokesSeen)\n"
            + "Tap switched off by macOS \(coordinator.tapDisableObservations)×\n"
            + "Combos \(coordinator.activeCount) live, \(coordinator.inactivePlaceholderCount) need the prompt UI\n"
            + "Last event \(coordinator.lastRouting ?? "none")\n"
            + "Last expansion \(coordinator.lastExpansion.map { "«\($0.replacingOccurrences(of: "\n", with: "⏎"))»" } ?? "—")"
        diagnostics.testResult = consistencyTest.summary
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
        let wasCollapsed = diagnosticsItem.isCollapsed
        diagnosticsItem.isCollapsed.toggle()
        // Only the *reveal* has content to grow; closing the pane hides content, and `Motion.morph` always
        // lands on `view.frame`, so there is nothing to animate toward.
        guard wasCollapsed, let reveal = MotionPlan.lookup(.paneReveal), window?.isVisible == true else { return }
        let content = diagnostics.view
        // The divider keeps `NSSplitViewController`'s own animation; what morphs is the pane's *content*.
        // Flushing the tile first is not decoration: `content.frame` has to be the rect the divider is
        // travelling to, or the grow pose lands on the collapsed width and animates nothing.
        splitView.view.layoutSubtreeIfNeeded()
        let final = content.frame
        guard final.width > 0, final.height > 0 else { return }
        // `growFromEdge`: a zero-width rect on the pane's own leading edge -- the divider side, since this
        // is the rightmost item -- so the content unfolds away from the divider rather than from a generic
        // baseline the way a row does.
        Motion.morph(content, source: CGRect(x: final.minX, y: final.minY, width: 0, height: final.height),
                     transition: reveal)
    }

    @objc func revealCombos(_ sender: Any?) {
        NSWorkspace.shared.activateFileViewerSelecting([store.url])
    }

    // The nine diagnostics actions below (`revealApp`, `restartTap`, `relaunch` and the six under
    // "Diagnostics actions") are internal rather than private: `DiagnosticsViewController`'s buttons
    // reference them with `#selector(MainWindowController.runSelfTest)`-style selectors and are sent
    // with a nil target, so the pane needs them visible at compile time and the responder chain needs
    // to reach them at runtime.

    @objc func revealApp() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    @objc func restartTap() {
        _ = coordinator.restartTap()
        refreshStatus()
    }

    @objc func relaunch() {
        let path = Bundle.main.bundlePath
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", "sleep 0.6; /usr/bin/open \"\(path)\""]
        try? helper.run()
        NSApp.terminate(nil)
    }

    // MARK: - Diagnostics actions

    @objc func runSelfTest() {
        show()
        editor.beginTryEdit()
        SyntheticKeys.selectAll()
        SyntheticKeys.type("addr ") { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { self?.refreshStatus() }
        }
    }

    @objc func testIdleTimeout() {
        show()
        editor.beginTryEdit()
        SyntheticKeys.type("ad") { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + 9.5) {
                self?.refreshStatus()
                launchLog("idle timeout test survived")
            }
        }
    }

    @objc func testControlC() {
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

    @objc func runConsistencyTest() {
        show()
        consistencyTest.start(roundsPerCase: 2) { [weak self] summary in
            self?.diagnostics.testResult = summary
        }
    }

    @objc func runStressTest() {
        show()
        consistencyTest.start(stressRounds: 40) { [weak self] summary in
            self?.diagnostics.testResult = summary
        }
    }

    /// Measures the motion rather than admiring it: runs every planned transition on the real
    /// diagnostics button cluster and logs the presentation geometry through `launchLog`, so the live
    /// pass greps numbers out of `/tmp/unfold-launch.log` instead of asking whether something "felt"
    /// animated. The probe host is the cluster itself -- `diagnostics.loadViewIfNeeded()` ran in `init`,
    /// so the view exists whether or not the pane is currently expanded.
    @objc func runMotionProbe(_ sender: Any?) {
        MotionProbe.runAll(on: diagnostics.containerForMotionProbe) { line in launchLog("motion: \(line)") }
    }
}

/// The window-level line `selectionMorph` travels from a sidebar row to the editor's trigger field
/// (Ruling AG). It fills its bounds with the semantic separator colour -- the same colour the
/// pane-hosted proxy used, so it re-resolves on appearance change and spends no new colour -- draws
/// nothing while hidden, and its `hitTest` returns nil so an overlay covering the whole window can
/// never eat a click.
///
/// Owned by `MainWindowController` because its two rects live in different panes; internal rather
/// than private only so the overlay tests can read the real view's geometry.
final class SelectionOverlayLineView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard !isHidden else { return }
        NSColor.separatorColor.setFill()
        dirtyRect.fill()
    }
}
