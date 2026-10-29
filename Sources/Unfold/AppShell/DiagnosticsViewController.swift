import AppKit

/// The diagnostics pane: the counters, the consistency-test result line, and the cluster of buttons
/// that drive both.
///
/// The pane owns no state. `MainWindowController.refreshStatus()` builds the two strings from the
/// coordinator -- which belongs to the app, not to this pane -- and hands them over through `summary` and
/// `testResult`. The pane renders those strings and nothing else.
///
/// The buttons are the interesting part of the wiring. They are *not* targeted at the pane; they act on
/// the window controller's diagnostics actions, and they reach it through the responder chain with a
/// **nil target** -- the same mechanism `AppMenu` documents ("Commands are sent with a nil target, so
/// they travel the responder chain and land on whatever window is key"). AppKit starts that search at
/// the key window's first responder, walks up through the pane's view, the split view controller, the
/// window and the window controller, and stops at the first object that responds to the selector. The
/// actions therefore have to be `@objc` *and* visible to `#selector`, which is why they are internal
/// methods on `MainWindowController` rather than private ones: a string selector would survive a rename
/// as a dead button, `#selector(MainWindowController.runConsistencyTest)` does not survive it at all.
final class DiagnosticsViewController: NSViewController {
    private let summaryLabel = NSTextField(wrappingLabelWithString: "")
    private let resultLabel = NSTextField(labelWithString: "")
    /// The button cluster, kept as a property so `containerForMotionProbe` can hand out the real view.
    private let buttonCluster = NSStackView()

    /// The counter block. Set once per status tick by the window controller; the pane never computes it.
    var summary: String {
        get { summaryLabel.stringValue }
        set { summaryLabel.stringValue = newValue }
    }

    /// The one-line consistency/stress test summary, written by the controller's `refreshStatus()` and
    /// again by a test run's completion handler.
    var testResult: String {
        get { resultLabel.stringValue }
        set { resultLabel.stringValue = newValue }
    }

    /// The view Task 10 animates to prove its motion is geometric: **the real diagnostics button
    /// cluster**, not a stand-in. A probe on a throwaway view would say nothing about the glass-wrapped
    /// cluster the user actually presses, so this returns the same stack the buttons live in.
    var containerForMotionProbe: NSView { buttonCluster }

    // MARK: - Construction

    override func loadView() {
        summaryLabel.font = Theme.Font.caption
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.isSelectable = true
        summaryLabel.maximumNumberOfLines = 0
        summaryLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        resultLabel.font = Theme.Font.caption
        resultLabel.textColor = .secondaryLabelColor
        resultLabel.alignment = .left

        let buttons = buttonRow()
        buttons.forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            buttonCluster.addArrangedSubview($0)
        }
        buttonCluster.orientation = .vertical
        buttonCluster.alignment = .leading
        buttonCluster.spacing = 6
        buttons.forEach { $0.widthAnchor.constraint(greaterThanOrEqualToConstant: 190).isActive = true }

        let stack = NSStackView(views: [
            section("Diagnostics"), summaryLabel,
            Glass.wrap(buttonCluster, cornerRadius: Theme.Radius.card, padding: 8), resultLabel,
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
        self.view = container
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

    /// `target: nil` is the whole point: the action is dispatched to whatever object in the responder
    /// chain answers it, which is `MainWindowController` while this window is key. See the type comment.
    private func pushButton(_ title: String, _ action: Selector) -> NSButton {
        let button = NSButton(title: title, target: nil, action: action)
        button.bezelStyle = .rounded
        button.controlSize = .small
        return button
    }

    /// The diagnostics commands, in the order they have always appeared. `MainWindowController`'s
    /// diagnostics actions are internal `@objc` methods so the responder chain can find them, and
    /// `#selector` keeps each connection checkable at compile time.
    private func buttonRow() -> [NSButton] {
        [pushButton("Run consistency test", #selector(MainWindowController.runConsistencyTest)),
         pushButton("Stress test (40)", #selector(MainWindowController.runStressTest)),
         pushButton("Self-test", #selector(MainWindowController.runSelfTest)),
         pushButton("Idle timeout", #selector(MainWindowController.testIdleTimeout)),
         pushButton("Ctrl-C in Terminal", #selector(MainWindowController.testControlC)),
         pushButton("Restart tap", #selector(MainWindowController.restartTap)),
         pushButton("Relaunch", #selector(MainWindowController.relaunch)),
         pushButton("Reveal app", #selector(MainWindowController.revealApp))]
    }
}
