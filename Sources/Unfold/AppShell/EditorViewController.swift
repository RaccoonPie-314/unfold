import AppKit
import UnfoldEngine

/// An edit the editor pane wants applied to the selected combo. The pane never touches the model;
/// these are the only things it can report.
enum ComboEdit {
    case trigger(String)
    case replacement(String)
    case insertion(InsertionMode)
    case enabled(Bool)
}

/// The editor pane: the combo form, the hint line, the "Try it" field, and the path to the store file.
///
/// Like the sidebar, the pane renders and reports -- it holds no `Combo` and saves nothing. The window
/// controller owns the file, the mutation and the list reload, so the pane needs no reload callback:
/// `onEdit` is the only way anything leaves it. The hint *text* is model logic too (duplicate triggers
/// and `TriggerIndex` rejections read the whole library), so the controller computes it and hands the
/// pane a string through `showHint(_:failure:)`.
///
/// The layout is hand-pinned anchors, not stack views. Stack views distribute their slack through
/// `.gravityAreas`, which let the caption column drift a few hundred points sideways while still
/// reporting a satisfied layout -- an earlier attempt at this form learned that the hard way. Every
/// constant and priority here exists for a reason recorded at its line.
final class EditorViewController: NSViewController, NSTextFieldDelegate, NSTextViewDelegate {
    /// The only way anything leaves the pane.
    var onEdit: ((ComboEdit) -> Void)?

    private let triggerField = NSTextField(string: "")
    private let replacementScroll = NSScrollView()
    private let replacementView = NSTextView()
    private let insertionPopUp = NSPopUpButton()
    private let enabledCheck = NSButton(checkboxWithTitle: "Enabled", target: nil, action: nil)
    private let editorHint = NSTextField(wrappingLabelWithString: "")
    /// A failure hint is label-colour text with a red glyph, not red text: `systemRed` at 11 pt over a
    /// light window background is 3.57:1, under the floor for meaningful text. The sentence carries the
    /// meaning; the glyph is emphasis.
    private let hintSymbol = NSImageView()
    private let tryScroll = NSScrollView()
    private let tryView = NSTextView()
    private let pathLabel = NSTextField(labelWithString: "")
    private let triggerProxy = ProxyLineView()

    /// `ConsistencyTest` types into this and reads it back.
    var tryTextView: NSTextView { tryView }

    /// The trigger field's frame, in screen coordinates -- where a selection morph lands.
    var triggerFieldFrameInWindow: CGRect? {
        guard let window = view.window else { return nil }
        return window.convertToScreen(triggerField.convert(triggerField.bounds, to: nil))
    }

    /// A 1 pt separator-coloured line laid exactly over the trigger field, **hidden until the morph
    /// needs it**. Task 11 morphs this rather than the field itself: re-laying out a real control
    /// mid-animation is what moved the caret the last time a morph touched something the user was
    /// typing into. It draws nothing while hidden, and its `hitTest` returns nil so it can never eat a
    /// click.
    var triggerFieldProxy: NSView { triggerProxy }

    // MARK: - Construction

    override func loadView() {
        triggerField.delegate = self
        triggerField.placeholderString = "addr"
        triggerField.font = Theme.Font.mono
        triggerField.target = self
        triggerField.action = #selector(commitTrigger)

        configure(replacementView, in: replacementScroll, monospaced: true)
        replacementView.delegate = self

        insertionPopUp.addItems(withTitles: ["Paste", "Type as keystrokes"])
        insertionPopUp.target = self
        insertionPopUp.action = #selector(commitInsertion)
        enabledCheck.target = self
        enabledCheck.action = #selector(commitEnabled)

        editorHint.font = Theme.Font.caption
        editorHint.textColor = .labelColor
        editorHint.maximumNumberOfLines = 2
        editorHint.setContentHuggingPriority(.defaultLow, for: .vertical)

        // The glyph is drawn at the caption's own point size, not at the symbol's natural ~17 pt, so a
        // failure triangle cannot tower over the 11 pt sentence next to it. `imageScaling` matters for
        // the same reason: an `NSImageView` with `image == nil` has no intrinsic size at all, which made
        // the gap in front of the hint a free variable.
        hintSymbol.imageScaling = .scaleProportionallyUpOrDown
        hintSymbol.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: Theme.Font.caption.pointSize, weight: .regular)
        // VoiceOver reads the sentence, not the glyph: the text already says the thing, and the image's
        // hard-coded "Not saved" description would contradict hints that say "Could not save -- ...". The
        // description stays (it travels with the symbol image) but never becomes the a11y label.
        hintSymbol.setAccessibilityElement(false)

        configure(tryView, in: tryScroll, monospaced: false)

        pathLabel.font = Theme.Font.caption
        pathLabel.textColor = .labelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        // Two columns, pinned by hand rather than by stack views: an 82-point caption column that
        // right-aligns, a 12-point gutter, and controls that take everything left over.
        let triggerCaption = caption("Trigger")
        let replacementCaption = caption("Replacement")
        let tryCaption = caption("Try it")
        let container = NSView()
        let views = [triggerCaption, replacementCaption, tryCaption, triggerField, hintSymbol, editorHint,
                     replacementScroll, insertionPopUp, enabledCheck, tryScroll, pathLabel]
        views.forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview($0)
        }
        // Above the field it mirrors, so it draws on top of it -- and hit-tests through to it. Hidden
        // until Task 11's shared-element morph unhides it: nothing before that task has any business
        // drawing a line through the middle of the user's trigger text. The constraints stay, because
        // Task 11 reads this geometry through `triggerFieldFrameInWindow`/`triggerFieldProxy`.
        triggerProxy.translatesAutoresizingMaskIntoConstraints = false
        triggerProxy.isHidden = true
        container.addSubview(triggerProxy)

        let guide = container.safeAreaLayoutGuide
        // Pane padding + the 82-point caption column, and the same plus a 12-point gutter.
        let captionColumn: CGFloat = Theme.Spacing.panePadding + Theme.Spacing.captionColumn
        let controlColumn: CGFloat = captionColumn + Theme.Spacing.gutter

        NSLayoutConstraint.activate([
            triggerCaption.trailingAnchor.constraint(equalTo: guide.leadingAnchor, constant: captionColumn),
            replacementCaption.trailingAnchor.constraint(equalTo: guide.leadingAnchor,
                                                         constant: captionColumn),
            tryCaption.trailingAnchor.constraint(equalTo: guide.leadingAnchor, constant: captionColumn),

            triggerField.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: controlColumn),
            // The hint's glyph column is a fixed 12 pt wide and always there, hidden or not, so the
            // sentence is indented by 12 + its 6 pt spacing in both states. That trades column alignment
            // with the fields above and below -- the hint no longer starts on `controlColumn` -- for
            // geometry that does not move: sizing the column to the image would slide the whole line
            // sideways every time a save was refused and then allowed.
            hintSymbol.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: controlColumn),
            hintSymbol.widthAnchor.constraint(equalToConstant: 12),
            hintSymbol.heightAnchor.constraint(equalToConstant: 12),
            hintSymbol.centerYAnchor.constraint(equalTo: editorHint.centerYAnchor),
            editorHint.leadingAnchor.constraint(equalTo: hintSymbol.trailingAnchor, constant: 6),
            replacementScroll.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: controlColumn),
            insertionPopUp.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: controlColumn),
            tryScroll.leadingAnchor.constraint(equalTo: guide.leadingAnchor, constant: controlColumn),
            triggerField.trailingAnchor.constraint(equalTo: guide.trailingAnchor,
                                                   constant: -Theme.Spacing.panePadding),
            editorHint.trailingAnchor.constraint(equalTo: guide.trailingAnchor,
                                                 constant: -Theme.Spacing.panePadding),
            replacementScroll.trailingAnchor.constraint(equalTo: guide.trailingAnchor,
                                                        constant: -Theme.Spacing.panePadding),
            tryScroll.trailingAnchor.constraint(equalTo: guide.trailingAnchor,
                                                constant: -Theme.Spacing.panePadding),
            pathLabel.leadingAnchor.constraint(equalTo: guide.leadingAnchor,
                                               constant: Theme.Spacing.panePadding),
            pathLabel.trailingAnchor.constraint(equalTo: guide.trailingAnchor,
                                                constant: -Theme.Spacing.panePadding),

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

            triggerProxy.leadingAnchor.constraint(equalTo: triggerField.leadingAnchor),
            triggerProxy.trailingAnchor.constraint(equalTo: triggerField.trailingAnchor),
            triggerProxy.centerYAnchor.constraint(equalTo: triggerField.centerYAnchor),
            triggerProxy.heightAnchor.constraint(equalToConstant: 1),
        ])
        for scroll in [replacementScroll, tryScroll] {
            scroll.setContentHuggingPriority(.defaultLow, for: .vertical)
            scroll.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        }
        self.view = container
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
        textView.font = monospaced ? Theme.Font.mono : Theme.Font.body
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
        label.font = Theme.Font.caption
        label.textColor = .labelColor
        label.alignment = .right
        return label
    }

    // MARK: - Display

    /// Shows a combo, or resets the form for an empty selection. The empty *message* comes from the
    /// controller through `showHint` -- it depends on the whole library and the filter, not on this
    /// pane's controls.
    func display(_ combo: Combo?) {
        guard let combo else {
            triggerField.stringValue = ""
            replacementView.string = ""
            triggerField.isEnabled = false
            replacementView.isEditable = false
            insertionPopUp.isEnabled = false
            enabledCheck.state = .off
            return
        }
        triggerField.isEnabled = true
        replacementView.isEditable = true
        insertionPopUp.isEnabled = true
        triggerField.stringValue = combo.trigger
        replacementView.string = Template.serialize(combo.parts)
        insertionPopUp.selectItem(withTitle: combo.insertion == .paste ? "Paste" : "Type as keystrokes")
        enabledCheck.state = combo.enabled ? .on : .off
    }

    /// Renders the hint the controller computed. Failure is the red-glyph case ("Not saved -- ...",
    /// "Could not save -- ..."); the text itself stays `labelColor` either way.
    func showHint(_ text: String, failure: Bool) {
        editorHint.stringValue = text
        editorHint.textColor = .labelColor
        hintSymbol.isHidden = !failure
        hintSymbol.contentTintColor = .systemRed
        hintSymbol.image = failure
            ? NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Not saved")
            : nil
    }

    /// The full store path, shown as this label's tooltip. The window owns the path; the pane renders
    /// it. Set **once** at wiring time -- `store.url` never changes -- and deliberately not from the
    /// per-second `refreshStatus()`: re-assigning `toolTip:` on a view whose tooltip is currently open
    /// dismisses it and starts it again, so the user could never finish reading it.
    func setPathTooltip(_ path: String) {
        pathLabel.toolTip = path
    }

    /// The `~`-shortened store path on the label -- what `refreshStatus()` updates every second. Written
    /// only when the text actually changed, so the timer does not force a display pass on a label whose
    /// path is the same as it was a second ago. The full path stays in the tooltip.
    func showPath(short: String) {
        guard pathLabel.stringValue != short else { return }
        pathLabel.stringValue = short
    }

    // MARK: - Focus

    func beginTriggerEdit() {
        view.window?.makeFirstResponder(triggerField)
        triggerField.selectText(nil)
    }

    /// Focus the "Try it" field and clear it -- what the self-test buttons do before typing into it.
    func beginTryEdit() {
        view.window?.makeFirstResponder(tryView)
        tryView.string = ""
    }

    // MARK: - Commits

    func controlTextDidEndEditing(_ notification: Notification) {
        if (notification.object as? NSControl) === triggerField {
            onEdit?(.trigger(triggerField.stringValue))
        }
    }

    /// "Saves as you type" is the promise the hint makes, so the replacement commits on change rather
    /// than on focus loss. It deliberately does not reload the editor: rewriting the string under a
    /// caret that is mid-word moves the caret to the end.
    func textDidChange(_ notification: Notification) {
        guard (notification.object as? NSTextView) === replacementView else { return }
        onEdit?(.replacement(replacementView.string))
    }

    @objc private func commitTrigger() {
        onEdit?(.trigger(triggerField.stringValue))
    }

    @objc private func commitInsertion() {
        let mode: InsertionMode = insertionPopUp.indexOfSelectedItem == 0 ? .paste : .keys
        onEdit?(.insertion(mode))
    }

    @objc private func commitEnabled() {
        onEdit?(.enabled(enabledCheck.state == .on))
    }
}

/// The proxy the Task 11 morph animates in place of the trigger field. It draws a semantic separator
/// line (so it re-resolves on appearance change), and hit-tests to nil so the real field underneath
/// stays clickable. It is created hidden -- Task 11 is the only thing that shows it -- and draws nothing
/// while hidden, so a line that is standing by can never paint over the trigger text.
private final class ProxyLineView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard !isHidden else { return }
        NSColor.separatorColor.setFill()
        dirtyRect.fill()
    }
}

private extension NSLayoutConstraint {
    /// Sets the priority inline, so a list of activated constraints reads with its own breakability.
    func withPriority(_ priority: Float) -> NSLayoutConstraint {
        self.priority = NSLayoutConstraint.Priority(priority)
        return self
    }
}
