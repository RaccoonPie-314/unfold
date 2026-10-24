import AppKit
import UnfoldEngine
import UnfoldMac

/// What the status line says, decided as a value so the menu's one job -- telling the truth about
/// whether expansion can happen -- is testable without a status item, a tap, or a permission prompt.
///
/// The order is the whole point. No permission outranks everything, because nothing else can work;
/// the user's own pause outranks the tap's state, because a paused tap is off on purpose. A given-up
/// budget and a detached tap each name their own reason before the live check is consulted. Only a
/// trusted, unpaused, attached tap whose port reads enabled *now* may say "Listening" -- the cached
/// `TapState` alone is not enough, because it can say `.live` for a tap macOS silently invalidated.
enum MenuStatus: Equatable {
    case notPermitted
    case paused
    case tapGivenUp
    case notReceivingKeystrokes
    case tapInterrupted
    case tapDetached
    case listening

    static func evaluate(isTrusted: Bool,
                         isPaused: Bool,
                         tapState: ExpansionCoordinator.TapState,
                         isTapEnabled: Bool) -> MenuStatus {
        if !isTrusted { return .notPermitted }
        if isPaused { return .paused }
        switch tapState {
        case .givenUp:
            return .tapGivenUp
        case .detached:
            // No port exists, so "attached but silent" would be the wrong story: nothing is attached.
            return .tapDetached
        case .live, .disabled:
            // The live read is the last word for a tap that exists. A cached `.live` is exactly what
            // lied before; a cached `.disabled` whose port still reads enabled is the stale-cache
            // case in the other direction, and the interrupted text is the honest one there.
            guard isTapEnabled else { return .notReceivingKeystrokes }
            return tapState == .live ? .listening : .tapInterrupted
        }
    }

    var text: String {
        switch self {
        case .notPermitted:
            return "Not permitted — allow Accessibility in Settings"
        case .paused:
            return "Paused"
        case .tapGivenUp:
            return "Stopped — macOS disabled the tap; choose Pause, then Resume"
        case .notReceivingKeystrokes:
            return "not receiving keystrokes — a password field or Secure Input can block expansion"
        case .tapInterrupted:
            return "Interrupted — the tap is off; choose Pause, then Resume"
        case .tapDetached:
            return "Off — keyboard access is not attached; choose Pause, then Resume"
        case .listening:
            return "Listening"
        }
    }
}

final class StatusItemController: NSObject, NSMenuDelegate {
    private let coordinator: ExpansionCoordinator
    private let comboLoadFailure: String?
    private let statusItem: NSStatusItem
    private let menu = NSMenu()

    init(coordinator: ExpansionCoordinator, comboLoadFailure: String? = nil) {
        self.coordinator = coordinator
        self.comboLoadFailure = comboLoadFailure
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        statusItem.button?.title = "⌁"
        menu.delegate = self
        statusItem.menu = menu
        refresh()
    }

    /// Rebuilds the menu now. `menuNeedsUpdate` runs the same body when the menu opens, so a tap
    /// that died since the last refresh is never described as "Listening" -- the status line is
    /// recomputed at the only moment the user can read it.
    func refresh() {
        rebuild(menu)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuild(menu)
    }

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()

        let status = NSMenuItem(title: statusLine(), action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        menu.addItem(.separator())

        let pauseItem = NSMenuItem(title: coordinator.isPaused ? "Resume Expansion" : "Pause Expansion",
                                   action: #selector(togglePause), keyEquivalent: "p")
        pauseItem.target = self
        menu.addItem(pauseItem)

        // Finding 3: a budget that gave up used to have no explicit way back from the menu, and the
        // report's claim that Resume reached `restartTap()` was false (Pause detaches, so Resume
        // creates a fresh tap). This item calls the coordinator's restart path directly, while the
        // latched source still holds its port.
        if coordinator.tapState == .givenUp {
            let restartItem = NSMenuItem(title: "Restart Keyboard Access",
                                         action: #selector(restartKeyboardAccess), keyEquivalent: "")
            restartItem.target = self
            menu.addItem(restartItem)
        }

        // Finding 4: a corrupt or unreadable combos.json used to be swallowed by `try?` and rendered
        // as "0 combos active" -- an empty library instead of a load failure. The failure now takes
        // the count's place, and Open Combos File stays available to fix the file.
        if let comboLoadFailure {
            let failure = NSMenuItem(title: "Combos could not be loaded — \(comboLoadFailure)",
                                     action: nil, keyEquivalent: "")
            failure.isEnabled = false
            menu.addItem(failure)
        } else {
            menu.addItem(NSMenuItem(title: "\(coordinator.activeCount) combos active",
                                    action: nil, keyEquivalent: ""))
        }

        let inactive = coordinator.inactivePlaceholderCount
        if inactive > 0 {
            let note = NSMenuItem(title: "\(inactive) inactive (need the prompt UI)",
                                  action: nil, keyEquivalent: "")
            note.isEnabled = false
            menu.addItem(note)
        }

        menu.addItem(.separator())
        let openItem = NSMenuItem(title: "Open Combos File",
                                  action: #selector(openCombosFile), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)
        let permissionItem = NSMenuItem(title: "Allow Keyboard Access…",
                                        action: #selector(requestPermission), keyEquivalent: "")
        permissionItem.target = self
        menu.addItem(permissionItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Unfold",
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    /// Brings expansion in line with the current permission. Called once at launch and again on
    /// every observed grant/revocation, so the menu changes without a relaunch.
    func applyPermission() {
        if PermissionFlow.isTrusted {
            startExpansion()
        } else {
            coordinator.pause()
            coordinator.detachTap()
        }
        refresh()
    }

    private func statusLine() -> String {
        MenuStatus.evaluate(isTrusted: PermissionFlow.isTrusted,
                            isPaused: coordinator.isPaused,
                            tapState: coordinator.tapState,
                            isTapEnabled: coordinator.isTapEnabled).text
    }

    @objc private func togglePause() {
        if coordinator.isPaused {
            startExpansion()
        } else {
            // pause() already re-posts what it released through the coordinator's sink; calling
            // post() again here would type the user's half-finished trigger a second time.
            coordinator.pause()
            coordinator.detachTap()
        }
        refresh()
    }

    /// Trust is checked here as well as inside `attachTap()`. The coordinator's injected predicate is
    /// the guarantee; this guard keeps an untrusted click from even calling into the coordinator and
    /// leaves the menu's own not-permitted status untouched.
    ///
    /// The coordinator starts paused, so `resume()` comes first; attaching a paused coordinator is
    /// the trusted-but-deaf state this ordering exists to avoid. Both menu paths that get here have
    /// just detached (Pause, or a revocation), so `attachTap()` builds a fresh source -- there is no
    /// latched port for `restartTap()` to recover, which is why the explicit Restart item owns that
    /// path instead of a fallback here.
    @discardableResult
    private func startExpansion() -> Bool {
        guard PermissionFlow.isTrusted else { return false }
        coordinator.resume()
        return coordinator.attachTap()
    }

    /// The explicit recovery for a re-enable budget that gave up. `restartTap()` clears the budget and
    /// switches the still-registered port back on; `attachTap()` cannot, because `start()` answers
    /// from that port instead of reaching creation. Refuses while untrusted, so a revoked permission
    /// cannot be bypassed by a stale menu item.
    @objc private func restartKeyboardAccess() {
        guard PermissionFlow.isTrusted else {
            refresh()
            return
        }
        coordinator.resume()
        _ = coordinator.restartTap()
        refresh()
    }

    @objc private func openCombosFile() {
        NSWorkspace.shared.activateFileViewerSelecting([Store.defaultURL()])
    }

    @objc private func requestPermission() {
        PermissionFlow.prompt()
        PermissionFlow.openAccessibilitySettings()
    }
}
