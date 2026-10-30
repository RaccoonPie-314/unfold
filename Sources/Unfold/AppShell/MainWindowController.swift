import AppKit
import QuartzCore
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
    private let diagnostics = DiagnosticsViewController()
    /// The single source of the filter text. The pane holds no copy of it, so `addCombo` clearing the
    /// filter and the empty-state copy cannot disagree with what the list shows.
    private var filter = ""

    private var diagnosticsItem: NSSplitViewItem!
    private var pauseItem: NSToolbarItem?
    private var statusLabel: NSTextField?
    private var statusSymbol: NSImageView?
    /// The pill surface the toolbar sizes. Internal rather than private because
    /// `StatusPillWidthTests` measures its fitting size across all seven `MenuStatus` states -- the
    /// property the user asked for on 2026-10-29 is that this view's width never changes -- and nothing
    /// outside this file drives it. It used to be the surface the pill-width transition sprang its width on; that
    /// transition is gone because the width it animated must now never exist as a change.
    var statusPill: NSView?
    /// The Diagnostics pane's **on-screen** width: 0 while the item is collapsed, otherwise the split view
    /// item's wrapper intersected with the split view's bounds. Every part of that is measured. The
    /// wrapper alone cannot carry the claim: after a close it keeps its last thickness (230 pt) and AppKit
    /// parks it either just *beyond* `bounds.maxX` or back at the open position *inside* the bounds, hidden
    /// -- both states were seen depending on whether a layout pass ran after the last resize -- and before
    /// `prewarmDiagnosticsCollapsePose(_:)` the pane's own view had no superview at all, so
    /// `view.frame.width` reported 0 for a pane that was about to fly in. `isCollapsed` is the
    /// authoritative state, so it gates the measurement -- as does the wrapper's own `isHidden`, which was
    /// true on every closed pose measured here -- and the bounds clamp handles the travel.
    /// Internal for `DiagnosticsDividerTests` and `FirstExpandPoseTests`, which measure where the divider
    /// actually stopped.
    var diagnosticsPaneWidth: CGFloat {
        guard let diagnosticsItem, !diagnosticsItem.isCollapsed,
              let wrapper = diagnostics.view.superview, !wrapper.isHidden,
              let split = splitViewView else { return 0 }
        return max(0, min(wrapper.frame.maxX, split.bounds.maxX)
                      - max(wrapper.frame.minX, split.bounds.minX))
    }
    /// The collapse state the toggle leaves behind -- same test seam, same reason.
    var diagnosticsPaneCollapsed: Bool { diagnosticsItem?.isCollapsed ?? true }
    /// The window's real `NSSplitView`, resolved through the same `splitViewView` lookup production
    /// uses. Internal for `DiagnosticsDividerTests`, which asserts the sidebar's 218 pt divider position
    /// landed -- the exact fact the old nil `view as? NSSplitView` cast silently skipped.
    var splitViewForProbe: NSSplitView? { splitViewView }
    /// Test seams for `WindowHierarchyTests`: the split view controller itself (the structural fact the
    /// divider-clipping hierarchy is asserted through -- the window's `contentViewController` **is** this
    /// object), and the editor/diagnostics panes so their views' safe-area insets can be measured.
    var splitViewControllerForProbe: NSSplitViewController { splitView }
    var editorPaneForProbe: EditorViewController { editor }
    var diagnosticsPaneForProbe: DiagnosticsViewController { diagnostics }
    private var statusItem: NSToolbarItem?
    /// The appearance control, kept so choosing a preference can rewrite *its* tooltip without hunting
    /// the toolbar for it. Reassigned whenever the toolbar rebuilds the item, same as `statusItem`.
    private var appearanceItem: NSToolbarItem?
    private var statusTimer: Timer?
    /// The status the pill was last rendered for. `refreshStatus` runs once a second; this is what
    /// lets an unchanged tick skip the pill's rewrite instead of re-setting identical values.
    private var lastRenderedStatus: MenuStatus?

    // MARK: - Identity

    private static let add = NSToolbarItem.Identifier("unfold.add")
    private static let remove = NSToolbarItem.Identifier("unfold.remove")
    private static let pause = NSToolbarItem.Identifier("unfold.pause")
    private static let appearance = NSToolbarItem.Identifier("unfold.appearance")
    private static let status = NSToolbarItem.Identifier("unfold.status")
    private static let diagnostics = NSToolbarItem.Identifier("unfold.diagnostics")

    /// The status pill's glyph size, spelled once: `buildStatusItem` starts with it and `refreshStatus`
    /// composes the status colour onto the same value instead of re-typing the numbers.
    private static let statusSymbolSize = NSImage.SymbolConfiguration(pointSize: 12, weight: .semibold)

    /// The pill's label font, spelled once because the width reservation below measures the seven
    /// states **in this font** -- a second spelling would let the reservation and the rendered text
    /// drift apart.
    private static let statusLabelFont = NSFont.systemFont(ofSize: 11, weight: .medium)

    /// The width every status label is pinned to: the widest `MenuStatus.shortText` rendered in
    /// `statusLabelFont`. The pill the user sees is therefore one fixed box across all seven states --
    /// "i want it a fixed size without changing when toggling it" -- and `StatusPillWidthTests` asserts
    /// the fitting size is identical for every state, which is only true because of this reservation.
    /// The glyph half was measured too: all seven symbols at `statusSymbolSize` render 15 pt wide, so
    /// the label is the only axis that needed pinning.
    private static let statusLabelReservedWidth: CGFloat = ceil(
        MenuStatus.allPillStates.map {
            ($0.shortText as NSString).size(withAttributes: [.font: statusLabelFont]).width
        }.max() ?? 0)

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
        // that a contract instead of an accident of `assembleSplitView()` loading `splitView.view`
        // when it installs the split view controller as the window's content view controller.
        sidebar.loadViewIfNeeded()
        editor.loadViewIfNeeded()
        diagnostics.loadViewIfNeeded()

        assembleSplitView()
        installToolbar()
        restoreFrame(window)
        prewarmDiagnosticsCollapsePose(window)

        // The plumbing between the panes and the state they render. Installed before the first
        // `reloadRows()`, because that call puts a selection on screen and the controller has to hear
        // about it.
        sidebar.onSelect = { [weak self] id in
            guard let self else { return }
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

    /// The window's designed content size, spelled once: `restoreFrame` opens the window at it (before any
    /// autosaved frame replaces it) and `prewarmDiagnosticsCollapsePose(_:)` hands that same frame back
    /// after the warm-up. Internal for `FirstExpandPoseTests`, which asserts the warm-up does not leave the
    /// window padded by the Diagnostics pane's thickness; nothing else outside this file reads it.
    static let designedContentSize = NSSize(width: 900, height: 580)

    /// Setting `contentViewController` resizes the window to the split view's fitting size -- the sum
    /// of the pane minimums, which is the smallest legal window, not the designed one. So the design
    /// size and the saved frame are applied first, and the sidebar's divider position is applied
    /// **last**: `setFrameAutosaveName` re-runs the split view's layout when it restores a saved frame
    /// (measured -- the sidebar fell back to its 190 pt minimum), so a `setPosition` issued before it is
    /// clobbered. Placing it after the frame settles makes the 218 pt intent the final word.
    private func restoreFrame(_ window: NSWindow) {
        window.setContentSize(Self.designedContentSize)
        if !window.setFrameAutosaveName("UnfoldMainWindow") {
            window.center()
        }
        // 218 pt for the sidebar -- and this is now the **second** reason the `splitViewView` lookup
        // exists: the old `splitView.view as? NSSplitView` was nil on this SDK (measured), so the
        // sidebar has been opening at its 190 pt minimum ever since, which live-pass item 2 was
        // supposed to catch. The lookup makes the intent real.
        splitViewView?.setPosition(218, ofDividerAt: 0)
    }

    /// Establishes, **before anything can animate**, the pose a collapsed trailing pane is supposed to
    /// be parked in.
    ///
    /// The defect this removes (user report of 2026-10-30: *"the initial expanding ... it doesn't just
    /// slide out, it flew from the left side awkwardly, after that it expand normal smoothly"*): an
    /// `NSSplitViewItem` inserted **already collapsed** is first laid out at the *leading* edge, not the
    /// trailing one. Measured on a launch-closed Diagnostics pane in a 900 pt window -- the wrapper is
    /// `(0, 0, 230, 0)` with `isHidden = true`, its divider is at `x = -2`, and the pane's own view is
    /// not in the hierarchy at all (`view.superview == nil`, frame `(0, 0, 0, 0)`, safe-area insets 0,
    /// so the stack pinned to the safe area has never been placed either). AppKit replaces that stale
    /// pose with the real parked one -- wrapper at `(bounds.maxX, 0, 230, H)`, divider at
    /// `bounds.maxX − 3`, the pane's view attached, laid out, and carrying its 52 pt safe-area top --
    /// only *during the first uncollapse*. Since `60c5a4e` the reveal is a divider move inside one
    /// `NSAnimationContext` with implicit animation on, so that first pass interpolates the wrapper and
    /// its material from the leading edge across the whole window: the fly-in. Every later expansion
    /// starts from the pose the first one established, which is exactly why it happens once.
    ///
    /// `5576ff0` did not introduce it -- the same launch pose measures identically on the pre-hierarchy
    /// tree (`60c5a4e`: wrapper `(0, 0, 230, 0)`, divider `x = -2`, pane view with no superview), and
    /// the material view is only the thing being dragged, not the cause.
    ///
    /// The pre-warm is the production collapse path, run synchronously: open, then close. It ends in the
    /// pose measured after a manual open/close cycle, so the first animated expansion starts where the
    /// second does. Open-then-close and not close-only because close-only is a no-op here (measured:
    /// `setPosition(bounds.maxX, ofDividerAt: 1)` on an item that has never been open leaves the
    /// wrapper, the divider and the detached pane view exactly where they were). This pre-warms the
    /// layout; it does not suppress, shorten or special-case the first animation.
    ///
    /// Runs after `restoreFrame`, for both halves of the reason: the pose is expressed against
    /// `split.bounds.maxX` (which the autosaved frame re-runs the layout for), and the geometry laid out
    /// during the warm-up has to be the geometry the pane is finally displayed in -- measured, warming up
    /// *before* the design size lands leaves the pane at the pre-resize height (wrapper 480 pt tall in a
    /// 580 pt split view, stack at y 24 instead of y 124), which is a smaller but real version of the same
    /// defect: the first expansion animates a resize and a content shift.
    ///
    /// The open step grows the window, because AppKit sizes a `contentViewController` window to its
    /// content's fitting size (measured: 900 × 580 → 1131 × 580) and the close step does not shrink it
    /// back -- so the frame `restoreFrame` settled is re-applied afterwards. The pane keeps the geometry the
    /// close established (full height, thickness 230, laid out, hidden); where the hidden wrapper sits
    /// after that -- just past `bounds.maxX`, or back at the open position inside the bounds -- is AppKit's
    /// choice and is not what the fly-in was: the defect was starting at `x = 0` with a zero-height,
    /// never-laid-out pane view, and neither of those is reachable from here.
    private func prewarmDiagnosticsCollapsePose(_ window: NSWindow) {
        guard diagnosticsItem?.isCollapsed == true, splitViewView != nil else { return }
        let settledFrame = window.frame
        setDiagnosticsCollapsed(false, animated: false)
        setDiagnosticsCollapsed(true, animated: false)
        if window.frame != settledFrame {
            window.setFrame(settledFrame, display: false)
        }
    }

    /// The divider index of the Diagnostics pane: sidebar, editor, diagnostics makes it item 2 and
    /// therefore divider 1 (dividers are indexed between items).
    private static let diagnosticsDividerIndex = 1
    /// The pane width `toggleDiagnostics` opens to. It is deliberately the same number as the
    /// item's `minimumThickness`: the target sits exactly where AppKit's clamp will let it sit, so
    /// the divider travels to the pane's designed width instead of overshooting into a clamp.
    static let diagnosticsExpandedWidth: CGFloat = 230

    /// The window's actual `NSSplitView`.
    ///
    /// **Measured, because the assumption was wrong:** `NSSplitViewController.view` is *not* the split
    /// view on this SDK -- it is a plain `NSView` that contains the `NSSplitView` as a subview (printed
    /// in `DiagnosticsDividerTests`' environment while writing it). Every `view as? NSSplitView` cast
    /// therefore silently returns nil, which is how the pre-existing sidebar `setPosition(218, ...)` in
    /// `restoreFrame` opened at the 190 pt minimum instead -- the old cast was a no-op the whole time.
    /// Everything divider-shaped goes through this lookup.
    private var splitViewView: NSSplitView? {
        if let direct = splitView.view as? NSSplitView { return direct }
        return splitView.view.subviews.first { $0 is NSSplitView } as? NSSplitView
    }

    /// The plan's divider curve, expressed as the one thing `NSAnimationContext` can be handed: four
    /// control points. A spring is not available to AppKit's divider animation, which is why
    /// `MotionPlan.dividerCurve` is the approved ease-out and `MotionPlanTests` refuses anything else
    /// for it; the fallback keeps the switch honest, not reachable.
    private static var dividerTiming: CAMediaTimingFunction {
        if case .easeOut(let x1, let y1, let x2, let y2) = MotionPlan.dividerCurve {
            return CAMediaTimingFunction(controlPoints: Float(x1), Float(y1), Float(x2), Float(y2))
        }
        return CAMediaTimingFunction(name: .easeOut)
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
        // The item keeps AppKit's own collapse mechanics -- measured necessity: `setPosition` behaves
        // as a drag (`NSSplitView.h:83`), and a drag is *allowed to collapse* an adjacent item but is
        // clamped against the pane's content fitting size (~146 pt here, 16 pt inset + the buttons'
        // intrinsic width) when the item cannot collapse, so a plain item could never fully close --
        // that dead end is what the earlier `minimumThickness = 0` experiment hit. What changed on
        // 2026-10-29 is not *who* collapses the pane but *what rides the clock*:
        // `toggleDiagnostics` puts every divider move inside one `NSAnimationContext` (the plan's
        // divider duration and the approved curve, implicit animation on), so the divider, the
        // arriving pane and the middle pane's re-truncating text share a single pass, and the pane's
        // content is no longer separately transformed -- that transform was the "line", and it is
        // deleted, not dormant.
        diagnosticsItem = NSSplitViewItem(viewController: diagnostics)
        diagnosticsItem.minimumThickness = 230
        diagnosticsItem.canCollapse = true
        diagnosticsItem.isCollapsed = true
        splitView.addSplitViewItem(diagnosticsItem)

        // The standard hierarchy: **the split view controller is the window's content view controller**,
        // so AppKit owns the titlebar/toolbar/sidebar chrome and clips the pane dividers below the
        // toolbar. The previous layout wrapped it in a plain root view controller carrying a window-wide
        // `Glass.windowBackground()` -- measured before the change, that made the `NSSplitView` span
        // 0...480 pt while the titlebar+toolbar band is 52 pt (`contentLayoutRect` height 428 of a 480
        // window), so the editor/diagnostics divider drew straight up through the translucent unified
        // toolbar (the user's "the separator on the diagnose bar is overlapping", 2026-10-29).
        // The window-wide material was load-bearing -- the hand-placed glass pill needs something
        // translucent behind the controls to refract -- so it moves to the content layer instead: the
        // editor and diagnostics panes each back themselves with `Glass.windowBackground()`. Measured,
        // both are required: after the root went away, a subtree scan of the window's content view found
        // behind-window material only wherever a pane container was one -- a plain container left its pane
        // region with no material at all, and the window is non-opaque with a clear background.
        // `NSSplitViewController` has no
        // `init(splitView:)` on this SDK (compile-checked: `type 'NSSplitViewController' has no member
        // 'init(splitView:)'`), so a custom split view subclass could only be installed through the
        // `splitView` property before the view loads -- a strictly worse route than the standard
        // hierarchy, which fixes the chrome itself.
        window?.contentViewController = splitView
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
        case Self.appearance:
            return buildAppearanceItem(identifier)
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
    ///
    /// The label's width is **reserved** to `statusLabelReservedWidth` before the stack is wrapped, so
    /// the glass box the toolbar sizes is the same for all seven states and no width motion can exist
    /// (the user asked for a fixed pill on 2026-10-29; the transition that sprang a width change is
    /// deleted at the same time as this reservation is added).
    private func buildStatusItem(_ identifier: NSToolbarItem.Identifier) -> NSToolbarItem {
        let symbol = NSImageView()
        symbol.symbolConfiguration = Self.statusSymbolSize
        symbol.setContentHuggingPriority(.required, for: .horizontal)
        let text = NSTextField(labelWithString: "…")
        text.font = Self.statusLabelFont
        text.translatesAutoresizingMaskIntoConstraints = false
        text.widthAnchor.constraint(equalToConstant: Self.statusLabelReservedWidth).isActive = true
        let stack = NSStackView(views: [symbol, text])
        stack.orientation = .horizontal
        stack.spacing = 5
        statusSymbol = symbol
        statusLabel = text

        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = "Status"
        item.paletteLabel = "Status"
        item.view = Glass.wrap(stack, cornerRadius: Theme.Radius.pill, padding: 6)
        statusItem = item
        // The wrapped glass view is the pill the user reads; `StatusPillWidthTests` measures it.
        statusPill = item.view
        // Toolbar customization can rebuild this item after the fact, and the fresh stack shows "..."
        // until something rewrites it. The change-memo would otherwise wait for the status to differ,
        // so clear it and render once now: the pill self-heals like it did before the memo existed.
        lastRenderedStatus = nil
        refreshStatus()
        return item
    }

    /// The appearance override's control.
    ///
    /// Three states, with Match System first and reachable from the same control: the failure mode of an
    /// in-app switch is that a person gets stuck in it, which is exactly what `dark-mode.md` warns about.
    /// A menu rather than a two-state button for the same reason -- and the menu is a system menu, so it
    /// picks up the current appearance and its own open animation for free.
    ///
    /// **Honest limit:** this changes `NSApp.appearance`, so it reaches Unfold's windows, panels, sheets
    /// and alerts. The `NSStatusItem` menu is drawn by the system menu bar and follows the *system*
    /// appearance, not this override -- an app cannot restyle the menu bar. Restated at `apply()`.
    private func buildAppearanceItem(_ identifier: NSToolbarItem.Identifier) -> NSToolbarItem {
        // Read once, not twice: the tooltip and the checked entry are the same fact, so they cannot
        // disagree about which choice is in force even if the defaults change between the two lines.
        let current = AppearancePreference.read()
        // `NSMenuToolbarItem`, not a plain `NSToolbarItem`: the SDK's `NSToolbarItem` has **no** `menu`
        // property any more (the plan's snippet does not compile -- `value of type 'NSToolbarItem' has no
        // member 'menu'`), and this is the class AppKit provides for an item that opens a menu. It is
        // still bordered, still takes the same symbol, label and palette label, and still shows the
        // system menu -- nothing about the control's shape changes.
        let item = NSMenuToolbarItem(itemIdentifier: identifier)
        item.label = "Appearance"
        item.paletteLabel = "Appearance"
        item.toolTip = current.tooltip
        item.image = NSImage(systemSymbolName: "circle.lefthalf.filled", accessibilityDescription: "Appearance")
        item.isBordered = true
        item.menu = appearanceMenu(current: current)
        appearanceItem = item
        return item
    }

    /// The three choices, with the stored one checked. Internal rather than private only so the checked
    /// entry can be asserted for **all three** preferences: the item itself reads
    /// `UserDefaults.standard`, and `swift test` runs in the shared `com.apple.dt.xctest.tool` domain
    /// (measured), so a test that stored a choice would strand an appearance override in a domain this
    /// repo does not own. The preference is a parameter here instead, and `buildAppearanceItem` is the
    /// one production caller.
    func appearanceMenu(current: AppearancePreference) -> NSMenu {
        let menu = NSMenu()
        for preference in AppearancePreference.allCases {
            let entry = NSMenuItem(title: preference.menuTitle,
                                   action: #selector(selectAppearance(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = preference.rawValue
            entry.state = preference == current ? .on : .off
            menu.addItem(entry)
        }
        return menu
    }

    /// Re-points the checkmark on the entry the user picked and names it in the tooltip, **without
    /// rebuilding the menu**: the entries keep their object identity, so a menu that is already open
    /// cannot be swapped out from under the pointer mid-click.
    ///
    /// Split out of `selectAppearance(_:)` because the two statements above it persist and apply -- the
    /// `UserDefaults.standard` write `swift test` must not make -- while this one touches no defaults and
    /// is therefore the half that gets asserted.
    func refreshAppearanceSelection(_ sender: NSMenuItem, preference: AppearancePreference) {
        sender.menu?.items.forEach { $0.state = $0 === sender ? .on : .off }
        appearanceItem?.toolTip = preference.tooltip
    }

    @objc private func selectAppearance(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let preference = AppearancePreference(rawValue: raw) else { return }
        preference.write()
        preference.apply()
        refreshAppearanceSelection(sender, preference: preference)
        refreshStatus()
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, Self.add, Self.remove,
         .flexibleSpace, Self.pause, Self.appearance, Self.status, Self.diagnostics]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.toggleSidebar, .sidebarTrackingSeparator, Self.add, Self.remove, Self.pause, Self.appearance,
         Self.status, Self.diagnostics, .flexibleSpace, .space]
    }

    func toolbar(_ toolbar: NSToolbar, validateItem item: NSToolbarItem) {
        if item.itemIdentifier == Self.remove || item.itemIdentifier == Self.add {
            item.isEnabled = true
        }
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
        // One status vocabulary, two surfaces (Ruling B): the pill used to re-derive its own
        // `(symbol, text, color)` from the same inputs by a second switch, which could -- and did
        // drift in colour -- from the menu's tested decision. `MenuStatus.evaluate` is now the only
        // place the shell decides what the status means; everything below only renders it.
        let status = MenuStatus.evaluate(isTrusted: PermissionFlow.isTrusted,
                                         isPaused: coordinator.isPaused,
                                         tapState: coordinator.tapState,
                                         isTapEnabled: coordinator.isTapEnabled)
        // `refreshStatus` runs once a second; the pill's visible parts are rewritten only when the
        // status actually changed, so an unchanged second costs nothing.
        if status != lastRenderedStatus {
            lastRenderedStatus = status
            statusSymbol?.image = NSImage(systemSymbolName: status.symbolName,
                                          accessibilityDescription: status.text)
            // The vocabulary's colour spent twice on the same glyph: as the image view's tint (approved in
            // Ruling B's rendering) and as the symbol's hierarchical colour, so the replacement reads as
            // one glyph rather than a recoloured second image.
            statusSymbol?.symbolConfiguration = Self.statusSymbolSize.applying(
                NSImage.SymbolConfiguration(hierarchicalColor: status.emphasisColor))
            statusSymbol?.contentTintColor = status.emphasisColor
            statusLabel?.stringValue = status.shortText
            // Monochrome label: the label has to be readable on its own, and only red clears the
            // glyph floor in Light mode, so the broken states are coloured and the working ones
            // are not.
            statusLabel?.textColor = .labelColor
            // **The symbol swap stays static, measured.** The seven states' glyphs all render 15 pt
            // wide at `statusSymbolSize` and the label's width is reserved, so no replacement animation
            // would move the pill even if AppKit provided one -- and this SDK's AppKit has no
            // image-replacement transition on `NSImageView` to ask for (grep for one in the framework
            // headers comes back empty; SwiftUI's `contentTransition` is not available to an AppKit
            // shell that forbids `NSHostingView`). Adding a crossfade would be a second hand-drawn
            // motion on a control the spec says the system already owns, so the swap is the plain one.
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

    /// Opens or closes the Diagnostics pane by **moving the divider on one clock** -- the single motion
    /// the user asked for on 2026-10-29 ("when it expand there is just a line there and the animation
    /// is awkward. When the text shrink ... it shrink instantly awkwardly too"). The content transform
    /// that used to ride beside the divider (the "line") is deleted, so `NSSplitView`'s own divider
    /// move is the only motion, and the middle pane's re-truncating text re-lays-out on the same pass.
    ///
    /// The move is `setDiagnosticsCollapsed(_:animated: true)`: a collapsible `NSSplitViewItem`
    /// collapses *purely from a constraint animation* at its `holdingPriority` (`NSSplitViewItem.h:32`),
    /// so the collapse is lifted/lowered around `setPosition(_:ofDividerAtIndex:)` -- the only divider-
    /// positioning API on this SDK (`NSSplitView.h:81`, 10.5+; there is no animated variant) -- and both
    /// run inside one `NSAnimationContext` (the plan's divider duration and the approved curve, implicit
    /// animation on). Lifting the collapse is what lets the position travel open (measured: a
    /// `setPosition` against a still-collapsible pane flips the flag but leaves the divider parked at
    /// the trailing edge); driving the position to `bounds.maxX − diagnosticsExpandedWidth` is what
    /// lands the pane on the designed 230 pt instead of whatever thickness the item last remembered.
    @objc func toggleDiagnostics(_ sender: Any?) {
        setDiagnosticsCollapsed(!(diagnosticsItem?.isCollapsed ?? true), animated: true)
    }

    /// The one implementation of the Diagnostics divider move, shared by `toggleDiagnostics` and the
    /// test seam so the geometry target is never a constant the production path does not use.
    ///
    /// `animated == true` is the one-clock `NSAnimationContext` pass the user sees. `animated == false`
    /// performs the identical collapse and divider move synchronously -- the same state mutation, only
    /// without the easing.
    ///
    /// **Measured harness limit** (why the seam exists): the constraint glide is driven by Core
    /// Animation's display-link commit cycle, which the command-line `swift test` run loop does not
    /// pump. An animated `setDiagnosticsCollapsed` therefore flips `isCollapsed` immediately but leaves
    /// the divider at its start pose until the first real on-screen frame -- reproduced with the window
    /// both off-screen and on the built-in display. So `DiagnosticsDividerTests` measures the *target*
    /// geometry through `animated: false` (the pane lands at its `minimumThickness`, which `assembleSplitView`
    /// sets equal to `diagnosticsExpandedWidth`), and the smoothness of the eased travel -- and, in a
    /// fixture where the uncollapse alone reaches that width, *which* divider the position names -- are
    /// live-pass observations, not something the harness can see.
    func setDiagnosticsCollapsed(_ collapsed: Bool, animated: Bool) {
        guard let split = splitViewView, let diagnosticsItem else { return }
        split.layoutSubtreeIfNeeded()
        let open = !collapsed
        let target = open ? split.bounds.maxX - Self.diagnosticsExpandedWidth : split.bounds.maxX
        let move: () -> Void = {
            // Lift the collapse before the position can travel open; lower it after the position
            // reaches the trailing edge when closing (a drag to the edge auto-collapses the item).
            if open { diagnosticsItem.isCollapsed = false }
            split.setPosition(target, ofDividerAt: Self.diagnosticsDividerIndex)
            if !open { diagnosticsItem.isCollapsed = true }
        }
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = MotionPlan.dividerDuration
                context.timingFunction = Self.dividerTiming
                context.allowsImplicitAnimation = true
                move()
            }
        } else {
            move()
            split.layoutSubtreeIfNeeded()
        }
    }

    /// Test seam: resolve the Diagnostics divider move synchronously so the harness can measure where
    /// the divider lands without a display link to finish the animation. Production calls
    /// `toggleDiagnostics` (animated); nothing outside `DiagnosticsDividerTests` reaches this.
    func setDiagnosticsCollapsedForProbe(_ collapsed: Bool) {
        setDiagnosticsCollapsed(collapsed, animated: false)
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
