import AppKit
import UnfoldEngine
import UnfoldMac

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: StatusItemController?
    private var permissionTimer: Timer?
    private var idleTimer: Timer?
    private var focusObserver: NSObjectProtocol?
    private var coordinator: ExpansionCoordinator?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A missing file is a normal first run; a corrupt or unreadable one is not. The failure is
        // carried into the menu instead of being swallowed into an empty library, which used to read
        // "0 combos active" -- the same screen as a healthy install with nothing configured.
        let file: CombosFile
        let comboLoadFailure: String?
        do {
            file = try Store(url: Store.defaultURL()).load()
            comboLoadFailure = nil
        } catch {
            file = CombosFile(formatVersion: CombosFile.currentFormatVersion, combos: [])
            comboLoadFailure = String(describing: error)
        }
        let coordinator = ExpansionCoordinator(combos: file.combos,
                                                isTrusted: { PermissionFlow.isTrusted })
        self.coordinator = coordinator
        let statusItem = StatusItemController(coordinator: coordinator,
                                              comboLoadFailure: comboLoadFailure)
        self.statusItem = statusItem

        // Task 6's idle drain runs on the main run loop, the thread that hosts the tap. Without it a
        // half-typed trigger stays buffered until the next keystroke or focus change.
        idleTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak coordinator] _ in
            _ = coordinator?.handleIdle()
        }

        // Plan 1 residual R3: switching apps releases the buffered prefix instead of stranding it
        // inside a tap that no longer sees the field it was typed into.
        focusObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak coordinator] _ in
            _ = coordinator?.handleFocusChange()
        }

        // `onChange` runs once immediately and then on every observed grant or revocation, which is
        // what makes the menu's status line change without a relaunch.
        permissionTimer = PermissionFlow.waitUntilTrusted { [weak statusItem] _ in
            statusItem?.applyPermission()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // release, then detach: `pause()` re-posts the buffer through the injected sink, and only
        // then does `detachTap()` take the tap down.
        coordinator?.pause()
        coordinator?.detachTap()
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
