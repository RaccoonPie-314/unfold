import AppKit
import UnfoldEngine
import UnfoldMac

/// What the status line says, decided as a value so the menu's one job -- telling the truth about
/// whether expansion can happen -- is testable without a status item, a tap, or a permission prompt.
///
/// The order is the whole point. No permission outranks everything, because nothing else can work;
/// the user's own pause outranks the tap's state, because a paused tap is off on purpose. Only a
/// trusted, unpaused, live tap may say "Listening" -- every other combination names its reason.
enum MenuStatus: Equatable {
    case notPermitted
    case paused
    case tapGivenUp
    case tapInterrupted
    case tapDetached
    case listening

    static func evaluate(isTrusted: Bool,
                         isPaused: Bool,
                         tapState: ExpansionCoordinator.TapState) -> MenuStatus {
        if !isTrusted { return .notPermitted }
        if isPaused { return .paused }
        switch tapState {
        case .live: return .listening
        case .givenUp: return .tapGivenUp
        case .disabled: return .tapInterrupted
        case .detached: return .tapDetached
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
        case .tapInterrupted:
            return "Interrupted — the tap is off; choose Pause, then Resume"
        case .tapDetached:
            return "Off — keyboard access is not attached"
        case .listening:
            return "Listening"
        }
    }
}

final class StatusItemController: NSObject, NSMenuDelegate {
    private let coordinator: ExpansionCoordinator
    private let statusItem: NSStatusItem
    private let menu = NSMenu()

    init(coordinator: ExpansionCoordinator) {
        self.coordinator = coordinator
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
        menu.addItem(NSMenuItem(title: "\(coordinator.activeCount) combos active",
                                action: nil, keyEquivalent: ""))

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
                            tapState: coordinator.tapState).text
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

    /// Trust is refused here, before a tap can exist. `ExpansionCoordinator.attachTap()` lives in
    /// `UnfoldMac`, which cannot see `PermissionFlow`, so the shell is the layer that enforces it.
    ///
    /// The coordinator starts paused, so `resume()` comes first; attaching a paused coordinator is
    /// the trusted-but-deaf state this ordering exists to avoid. If `attachTap()` fails on a tap
    /// whose re-enable budget has latched, `restartTap()` is the documented recovery -- `start()`
    /// cannot reach a port that is still registered.
    @discardableResult
    private func startExpansion() -> Bool {
        guard PermissionFlow.isTrusted else { return false }
        coordinator.resume()
        if coordinator.attachTap() { return true }
        return coordinator.restartTap()
    }

    @objc private func openCombosFile() {
        NSWorkspace.shared.activateFileViewerSelecting([Store.defaultURL()])
    }

    @objc private func requestPermission() {
        PermissionFlow.prompt()
        PermissionFlow.openAccessibilitySettings()
    }
}
