import AppKit
import UnfoldEngine
import UnfoldMac

/// The app's only visible surface. It exists because a menu-bar-only agent is unfalsifiable: when
/// nothing expands, the user cannot tell whether permission is missing, the tap is dead, or the tap
/// is fine and the typed text simply did not match. Those are three different bugs with three
/// different fixes, and this window separates them without a log file.
final class StatusWindowController: NSWindowController, NSWindowDelegate {
    private let coordinator: ExpansionCoordinator

    private let permissionValue = NSTextField(labelWithString: "")
    private let tapValue = NSTextField(labelWithString: "")
    private let keysValue = NSTextField(labelWithString: "")
    private let combosValue = NSTextField(labelWithString: "")
    private let lastValue = NSTextField(labelWithString: "")
    private let routingValue = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(wrappingLabelWithString: "")
    private let pauseButton = NSButton(title: "Pause", target: nil, action: nil)
    private let grantButton = NSButton(title: "Grant Accessibility Access", target: nil, action: nil)

    private var refreshTimer: Timer?

    init(coordinator: ExpansionCoordinator) {
        self.coordinator = coordinator

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 360),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Unfold"
        window.center()
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self

        buildContent()
        refresh()
        startTimer()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func show() {
        // Reopening after a close must resume live updates; the timer is torn down on close.
        if refreshTimer == nil { startTimer() }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    private func startTimer() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    func windowWillClose(_ notification: Notification) {
        // Closing hides the window; the app keeps working. The menu can bring it back.
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    private func buildContent() {
        let title = NSTextField(labelWithString: "Unfold")
        title.font = .systemFont(ofSize: 20, weight: .semibold)

        let subtitle = NSTextField(wrappingLabelWithString:
            "Type a trigger — addr then a space — in any app. It is replaced the moment it completes, and every keystroke you type is visible while you type it.")
        subtitle.textColor = .secondaryLabelColor

        let grid = NSGridView(views: [
            [rowLabel("Accessibility"), permissionValue],
            [rowLabel("Keyboard tap"), tapValue],
            [rowLabel("Keystrokes seen"), keysValue],
            [rowLabel("Combos"), combosValue],
            [rowLabel("Last event"), routingValue],
            [rowLabel("Last expansion"), lastValue],
        ])
        grid.rowSpacing = 8
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing

        hintLabel.textColor = .secondaryLabelColor
        hintLabel.stringValue = ""

        pauseButton.target = self
        pauseButton.action = #selector(togglePause)
        pauseButton.bezelStyle = .rounded

        let restartButton = NSButton(title: "Restart Tap", target: self, action: #selector(restartTap))
        restartButton.bezelStyle = .rounded

        // macOS evaluates the accessibility grant when a process launches, and a grant made while the
        // app is running is often ignored. This does the quit-and-reopen the user would otherwise do
        // by hand -- on the same binary, so no re-grant is needed for *this* action.
        let relaunchButton = NSButton(title: "Relaunch", target: self, action: #selector(relaunch))
        relaunchButton.bezelStyle = .rounded

        // The one button that matters on a fresh install. Raising the system's own accessibility
        // prompt is what actually adds this app to the list -- deep-linking to the pane alone leaves
        // the user hunting for the app in a file picker.
        grantButton.target = self
        grantButton.action = #selector(grantAccess)
        grantButton.bezelStyle = .rounded
        grantButton.keyEquivalent = "\r"

        // Puts the .app in a Finder window, so it can be dragged straight into the Accessibility list
        // instead of being found by path.
        let revealAppButton = NSButton(title: "Reveal App", target: self, action: #selector(revealApp))
        revealAppButton.bezelStyle = .rounded

        let combosButton = NSButton(title: "Reveal Combos File", target: self, action: #selector(revealCombos))
        combosButton.bezelStyle = .rounded

        // Automation cannot test this app from outside: posting CGEvents needs a trusted process, and
        // accessibility-driven typing never produces events at all. So the app tests itself -- from
        // inside, against the real tap.
        let selfTestButton = NSButton(title: "Run Self-Test", target: self, action: #selector(runSelfTest))
        selfTestButton.bezelStyle = .rounded

        // The safety check that matters most: a keyboard layer that eats Ctrl-C is worse than no
        // expander. Only real Control-C events prove the tap lets them through.
        let controlCButton = NSButton(title: "Test Ctrl-C in Terminal", target: self, action: #selector(testControlC))
        controlCButton.bezelStyle = .rounded

        let quitButton = NSButton(title: "Quit", target: self, action: #selector(quit))
        quitButton.bezelStyle = .rounded

        let primaryButtons = NSStackView(views: [grantButton, pauseButton, relaunchButton, restartButton])
        primaryButtons.orientation = .horizontal
        primaryButtons.spacing = 8

        let secondaryButtons = NSStackView(views: [selfTestButton, controlCButton, revealAppButton, combosButton, quitButton])
        secondaryButtons.orientation = .horizontal
        secondaryButtons.spacing = 8

        let buttons = NSStackView(views: [primaryButtons, secondaryButtons])
        buttons.orientation = .vertical
        buttons.alignment = .leading
        buttons.spacing = 8

        let stack = NSStackView(views: [title, subtitle, grid, hintLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.translatesAutoresizingMaskIntoConstraints = false

        guard let content = window?.contentView else { return }
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
        ])
    }

    private func rowLabel(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.textColor = .secondaryLabelColor
        return label
    }

    private func refresh() {
        let trusted = PermissionFlow.isTrusted

        permissionValue.stringValue = trusted ? "granted" : "NOT granted — click Grant Accessibility Access"
        permissionValue.textColor = trusted ? .labelColor : .systemRed

        if trusted {
            grantButton.title = "Accessibility Granted"
            grantButton.isEnabled = false
            grantButton.keyEquivalent = ""
        } else {
            grantButton.title = "Grant Accessibility Access"
            grantButton.isEnabled = true
            grantButton.keyEquivalent = "\r"
        }

        switch coordinator.tapState {
        case .live:
            tapValue.stringValue = coordinator.isTapEnabled ? "attached and enabled" : "attached but DISABLED"
            tapValue.textColor = coordinator.isTapEnabled ? .labelColor : .systemOrange
        case .givenUp:
            tapValue.stringValue = "gave up after repeated timeouts — use Restart Tap"
            tapValue.textColor = .systemRed
        case .disabled:
            tapValue.stringValue = "not attached"
            tapValue.textColor = .systemOrange
        case .detached:
            tapValue.stringValue = "detached (paused or not permitted)"
            tapValue.textColor = .secondaryLabelColor
        }

        let seen = coordinator.keystrokesSeen
        if let last = coordinator.lastEventAt {
            let ago = Date().timeIntervalSince(last)
            keysValue.stringValue = "\(seen)  (last \(String(format: "%.1f", ago))s ago)"
            keysValue.textColor = .labelColor
        } else {
            keysValue.stringValue = "\(seen)  — none yet"
            keysValue.textColor = seen == 0 ? .systemOrange : .labelColor
        }

        let inactive = coordinator.inactivePlaceholderCount
        combosValue.stringValue = inactive == 0
            ? "\(coordinator.activeCount) active"
            : "\(coordinator.activeCount) active, \(inactive) need the prompt UI"

        lastValue.stringValue = coordinator.lastExpansion.map { "«\($0.replacingOccurrences(of: "\n", with: "⏎"))»" } ?? "—"
        routingValue.stringValue = coordinator.lastRouting ?? "—"

        pauseButton.title = coordinator.isPaused ? "Resume" : "Pause"

        // The hint names the one check that tells the user which link is broken.
        if !trusted {
            hintLabel.stringValue = "Click Grant Accessibility Access, then switch Unfold on in the list that opens. If it still says not granted afterwards, click Relaunch — macOS evaluates the grant at launch."
        } else if coordinator.keystrokesSeen == 0 {
            hintLabel.stringValue = "Permission is on but no keystrokes have arrived. Click into a text field and type; if the counter stays at 0, the tap is not receiving."
        } else if coordinator.lastExpansion == nil {
            hintLabel.stringValue = "Keystrokes are arriving. Type addr followed by a space to check matching."
        } else {
            hintLabel.stringValue = "Working. Keystrokes arrive and expansions fire."
        }
    }

    @objc private func togglePause() {
        if coordinator.isPaused {
            coordinator.resume()
            _ = coordinator.attachTap()
        } else {
            coordinator.pause()
            coordinator.detachTap()
        }
        refresh()
    }

    @objc private func restartTap() {
        _ = coordinator.restartTap()
        refresh()
    }

    @objc private func relaunch() {
        // Spawn the reopen detached from this process, then terminate: an in-process restart cannot
        // re-register with LaunchServices, and it is the fresh launch that re-evaluates the grant.
        let path = Bundle.main.bundlePath
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", "sleep 0.6; /usr/bin/open \"\(path)\""]
        try? helper.run()
        NSApp.terminate(nil)
    }

    @objc private func runSelfTest() {
        // Hide first so our own window cannot be the paste target, then type into TextEdit through
        // the same path a person's fingers use: real CGEvents, unmarked, so the tap sees them.
        window?.orderOut(nil)

        let textEdit = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.TextEdit").first
        textEdit?.activate(options: [.activateIgnoringOtherApps])

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            // Reproduce the reported sequence: select-all first, then the trigger. ⌘A renders no
            // text, so it must not be mistaken for typed input.
            StatusWindowController.postSelectAll()
            StatusWindowController.postKeystrokes("addr ")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.show()
                self?.refresh()
            }
        }
    }

    @objc private func testControlC() {
        window?.orderOut(nil)
        let terminal = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Terminal").first
        terminal?.activate(options: [.activateIgnoringOtherApps])
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            StatusWindowController.postControlC()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
                self?.show()
                self?.refresh()
            }
        }
    }

    private static func postControlC() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 8, keyDown: false)
        down?.flags = .maskControl
        up?.flags = .maskControl
        down?.post(tap: .cgSessionEventTap)
        usleep(30_000)
        up?.post(tap: .cgSessionEventTap)
    }

    private static func postSelectAll() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cgSessionEventTap)
        usleep(30_000)
        up?.post(tap: .cgSessionEventTap)
        usleep(30_000)
    }

    private static func postKeystrokes(_ text: String) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for character in text {
            let units = Array(String(character).utf16)
            let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
            down?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false)
            up?.keyboardSetUnicodeString(stringLength: units.count, unicodeString: units)
            // A source with `.combinedSessionState` carries whatever modifiers are down right now, and
            // the first self-test run arrived with Command attached -- which the modifier gate then
            // correctly ignored. A test that types must not pretend to hold Command.
            down?.flags = []
            up?.flags = []
            down?.post(tap: .cgSessionEventTap)
            usleep(40_000)
            up?.post(tap: .cgSessionEventTap)
            usleep(40_000)
        }
    }

    @objc private func revealApp() {
        NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
    }

    @objc private func grantAccess() {
        // The system prompt is what registers this app in the Accessibility list. The pane is opened
        // as well so the toggle is in front of the user once the alert is dismissed.
        PermissionFlow.prompt()
        PermissionFlow.openAccessibilitySettings()
        refresh()
    }

    @objc private func revealCombos() {
        NSWorkspace.shared.activateFileViewerSelecting([Store.defaultURL()])
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
