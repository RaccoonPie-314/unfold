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
///
/// A consequence worth stating for anyone driving these buttons from outside: nil-target dispatch only
/// finds an answer while the pane's window is **key**. `performClick(_:)` and accessibility press routes
/// go through the same dispatch, so any harness that presses one has to make the window key first --
/// otherwise the click is swallowed and nothing is broken in this code.
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

    /// The stack's inset and the glass cluster's padding, spelled once because the button floor below is
    /// **derived from them**: the content's minimum width has to equal the pane's designed width, or the
    /// constraint system is over-determined even at rest and AppKit resolves it by breaking the trailing
    /// pin -- which is what let the cluster hang off the window's right edge mid-reveal.
    static let stackInset: CGFloat = 16
    static let glassPadding: CGFloat = 8

    /// The content's minimum width: exactly `MainWindowController.diagnosticsExpandedWidth`. Measured
    /// before this was spelled out, the floor was 190 + 16 + 32 = **238 pt in a 230 pt pane**.
    static let contentMinimumWidth: CGFloat = MainWindowController.diagnosticsExpandedWidth

    override func loadView() {
        summaryLabel.font = Theme.Font.caption
        summaryLabel.textColor = .labelColor
        summaryLabel.isSelectable = true
        summaryLabel.maximumNumberOfLines = 0
        summaryLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        resultLabel.font = Theme.Font.caption
        resultLabel.textColor = .labelColor
        resultLabel.alignment = .left

        let buttons = buttonRow()
        buttons.forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            buttonCluster.addArrangedSubview($0)
        }
        buttonCluster.orientation = .vertical
        buttonCluster.alignment = .leading
        buttonCluster.spacing = 6
        let buttonMinimum = Self.contentMinimumWidth - 2 * Self.stackInset - 2 * Self.glassPadding
        buttons.forEach { $0.widthAnchor.constraint(greaterThanOrEqualToConstant: buttonMinimum).isActive = true }

        let stack = NSStackView(views: [
            section("Diagnostics"), summaryLabel,
            Glass.wrap(buttonCluster, cornerRadius: Theme.Radius.card, padding: Self.glassPadding),
            resultLabel,
        ])
        stack.orientation = .vertical
        stack.alignment = .width
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(top: Self.stackInset, left: Self.stackInset,
                                        bottom: Self.stackInset, right: Self.stackInset)

        // A plain container, same as the editor pane: `MainWindowController` installs one
        // `.underWindowBackground` material behind the whole split view, and a second one here would
        // double-blur the region its wrapper covers.
        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.widthAnchor.constraint(equalToConstant: Self.contentMinimumWidth),
            // The safe area, not the top edge: this pane also starts under the unified toolbar.
            stack.topAnchor.constraint(equalTo: container.safeAreaLayoutGuide.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor),
        ])
        // **No horizontal pin here, deliberately.** Measured with a per-frame probe on the live window:
        // AppKit gives this view the item's full thickness and parks it at the divider, so mid-travel the
        // wrapper is `884...900` while this view is `884...1114` -- its trailing edge is 214 pt off the right of
        // the window. Pinning the stack to that edge anchors the content to something that travels, which
        // is what made every title hang off the window's right edge and snap into place over the last
        // frames of the reveal. `wireRevealPose(inside:)` makes the horizontal pin against the split view,
        // whose trailing edge is on the window's edge at every sample.
        self.view = container
    }

    /// The pane's horizontal pose, wired once by `MainWindowController` after the split view exists.
    ///
    /// Mid-travel the split item's wrapper is the visible pane (`884...900` on a 900 pt split) while the
    /// item's own view is `884...1114` -- AppKit hands the view the item's full thickness and parks it at the
    /// divider. So the container's trailing edge travels *off the right of the window*, and a stack pinned
    /// to it rides the divider and snaps into place over the last frames of the reveal: that is the
    /// shimmer the user reported on 2026-10-30 ("only while the pane is moving, only the Diagnostics
    /// panel"). The split view's trailing edge is on the window's edge at every sample, so pinning there
    /// holds the content still in window space and lets the divider uncover it.
    ///
    /// The wrapper is also what cuts the content off -- the container cannot, because the content now sits
    /// partly outside it. Called from the window controller rather than `viewDidAppear`, which the test
    /// harness does not reliably deliver and which would leave the stack with no horizontal pin at all.
    func wireRevealPose(inside splitView: NSSplitView) {
        guard let holder = view.superview, let stack = view.subviews.first as? NSStackView else { return }
        holder.wantsLayer = true
        holder.clipsToBounds = true
        guard revealPin == nil else { return }
        let pin = stack.trailingAnchor.constraint(equalTo: splitView.trailingAnchor)
        pin.isActive = true
        revealPin = pin
    }

    private var revealPin: NSLayoutConstraint?

    private func section(_ text: String) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 11, weight: .semibold)
        label.textColor = .labelColor
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
    ///
    /// The order is asserted by name and position in `DiagnosticsPaneTests`, so inserting a button (the
    /// `Motion probe` line took Task 5's reserved slot here) is a deliberate two-file edit, not a slip.
    private func buttonRow() -> [NSButton] {
        [pushButton("Run consistency test", #selector(MainWindowController.runConsistencyTest)),
         pushButton("Stress test (40)", #selector(MainWindowController.runStressTest)),
         pushButton("Self-test", #selector(MainWindowController.runSelfTest)),
         pushButton("Idle timeout", #selector(MainWindowController.testIdleTimeout)),
         pushButton("Ctrl-C in Terminal", #selector(MainWindowController.testControlC)),
         pushButton("Motion probe", #selector(MainWindowController.runMotionProbe)),
         pushButton("Restart tap", #selector(MainWindowController.restartTap)),
         pushButton("Relaunch", #selector(MainWindowController.relaunch)),
         pushButton("Reveal app", #selector(MainWindowController.revealApp))]
    }
}
