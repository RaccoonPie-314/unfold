import AppKit
import CoreGraphics
import UnfoldEngine

public protocol TextInjecting {
    func insert(_ text: String, mode: InsertionMode)
}

/// One pasteboard item as the injector reads it: the types that item carries, with its bytes.
/// The item is the unit, not the type -- a copy of two files is two of these and must come back as
/// two items.
typealias ClipboardItem = [(NSPasteboard.PasteboardType, Data)]

/// The whole outside world `Injector` touches, behind one seam: the general pasteboard's primitives,
/// the restore timer, and the act of injecting an event.
///
/// The seam exists because the half of `insert` worth testing is its *decisions* -- which items to
/// capture, whether a capture is worth restoring, what a second expansion has to flush first, whether
/// the target app has since written the paste itself. None of that can be driven against the real
/// system:
///  - `NSPasteboard.general` is the live clipboard of the workstation this runs on, and a
///    test that writes it destroys whatever was already copied there;
///  - `post(tap: .cgSessionEventTap)` with a synthetic Cmd+V pastes into whatever has focus,
///    at a moment the test chose.
///
/// It is deliberately low level -- the requirements mirror `NSPasteboard` calls one for one -- so that
/// the per-item walk, the empty-capture rule and the flush stay in `Injector`, where the tests reach
/// them. A higher-level `capture()`/`restore()` seam would have moved the item-boundary rule into the
/// fake and tested the fake instead of the rule. Both sides are confined to `SystemClipboard`, which
/// production uses and no test constructs.
protocol ClipboardServing: AnyObject {
    /// How many items are on the pasteboard right now.
    var itemCount: Int { get }
    /// The types the item at `index` declares.
    func types(forItem index: Int) -> [NSPasteboard.PasteboardType]
    /// The bytes the item at `index` carries under `type`, or nil when it cannot be read yet -- a
    /// lazily-rendered promise the owning app has not handed over.
    func data(forItem index: Int, type: NSPasteboard.PasteboardType) -> Data?
    /// Discard everything on the pasteboard.
    func clearContents()
    /// Append one item carrying exactly these types, after whatever previous calls put there.
    func appendItem(_ payloads: ClipboardItem)
    /// The pasteboard's write counter, bumped by every write.
    var changeCount: Int { get }
    /// Run `work` after `delay` on the queue the pasteboard is touched from.
    func scheduleRestore(after delay: TimeInterval, _ work: @escaping () -> Void)
    /// Inject one event into the session.
    func post(_ event: CGEvent)
}

public final class Injector: TextInjecting {
    /// Restoring synchronously races the target app's read, so the restore is deferred and
    /// guarded by changeCount (ruling R-P2-4).
    private static let restoreDelay = 0.25
    private static let vKeyCode = 9

    private let clipboard: ClipboardServing

    /// The restore the previous expansion deferred, still waiting out its delay. Held so the next
    /// expansion can run it *now*, before it looks at the pasteboard.
    ///
    /// The generation is what keeps a stale timer honest: every expansion schedules a firing of its
    /// own, and the one still scheduled after a flush must not restore whatever is pending when it
    /// happens to fire -- that would restore the second snapshot on the first timer's clock, before
    /// the target app has finished reading it. A timer only runs the restore it was scheduled for.
    private var pendingRestore: (generation: Int, restore: () -> Void)?
    private var lastRestoreGeneration = 0

    public convenience init() {
        self.init(clipboard: SystemClipboard())
    }

    /// The injection point. Production never reaches it: the no-argument initializer above hands over
    /// the real system clipboard, and this is how a test hands over a fake instead.
    init(clipboard: ClipboardServing) {
        self.clipboard = clipboard
    }

    public func insert(_ text: String, mode: InsertionMode) {
        switch mode {
        case .paste: paste(text)
        case .keys: type(text)
        }
    }

    private func paste(_ text: String) {
        // Finding E, rule 3: two expansions inside the restore delay used to lose the user's payload
        // for good -- the second capture read the *first snippet* off the board, so the deferred
        // restore put a snippet back and the original was gone. Flushing synchronously here means this
        // capture sees what the first expansion captured.
        flushPendingRestore()
        let saved = capture()
        clipboard.clearContents()
        clipboard.appendItem([(.string, Data(text.utf8))])
        let ourCount = clipboard.changeCount
        postCmdV()

        // Captures the clipboard, the snapshot and the changeCount -- and deliberately not `self`, so
        // holding this in `pendingRestore` is not a cycle.
        lastRestoreGeneration += 1
        let generation = lastRestoreGeneration
        pendingRestore = (generation, { [clipboard] in
            guard clipboard.changeCount == ourCount else { return }
            Injector.restore(saved, to: clipboard)
        })
        // `self` is captured strongly on purpose, and only for the length of the delay: if the
        // coordinator is dropped inside that window the restore still has to land, or the user's
        // payload is the thing that went missing instead.
        clipboard.scheduleRestore(after: Injector.restoreDelay) { self.flushPendingRestore(generation: generation) }
    }

    /// Runs, once, the restore the previous expansion deferred. Idempotent by construction: the timer
    /// and the next expansion both call it, and only the first one finds anything to do. A timer
    /// passes its own generation so a stale one becomes a no-op rather than firing the current
    /// snapshot early; the flush from `paste` passes none and runs whatever is pending.
    private func flushPendingRestore(generation: Int? = nil) {
        guard let pending = pendingRestore else { return }
        if let generation, pending.generation != generation { return }
        pendingRestore = nil
        pending.restore()
    }

    /// Every item, and every type of every item -- not just `.string`: a user who copied an image and
    /// then expanded a snippet must get the image back. Losing their clipboard is a data-loss bug and
    /// outranks tidiness (ruling R-P2-4).
    ///
    /// Finding E, rule 1: the item is the unit. The pre-fix walk flattened `pasteboard.types` -- the
    /// union across every item -- into one list, so a two-item copy (several files, a range of
    /// spreadsheet cells) came back as a single item and the target app saw one file where the user
    /// copied two.
    private func capture() -> [ClipboardItem] {
        var items: [ClipboardItem] = []
        for index in 0..<clipboard.itemCount {
            var payloads: ClipboardItem = []
            for type in clipboard.types(forItem: index) {
                if let data = clipboard.data(forItem: index, type: type) { payloads.append((type, data)) }
            }
            // An item whose payloads are all promises the owner has not rendered yet is skipped rather
            // than restored as a blank item; reading it forced nothing, so there is nothing to write.
            if !payloads.isEmpty { items.append(payloads) }
        }
        return items
    }

    static func restore(_ items: [ClipboardItem], to clipboard: ClipboardServing) {
        // Finding E, rule 2: nothing captured means nothing to put back, and the old unconditional
        // `clearContents()` then left the pasteboard *empty* -- the user's next Cmd+V pastes nothing at
        // all. Stand down instead, and leave whatever is on the board where it is.
        guard !items.isEmpty else { return }
        clipboard.clearContents()
        items.forEach { clipboard.appendItem($0) }
    }

    private func postCmdV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(Injector.vKeyCode), keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(Injector.vKeyCode), keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        if let down { clipboard.post(down) }
        if let up { clipboard.post(up) }
    }

    /// For apps that reject synthetic paste. Setting the unicode string directly sidesteps layout.
    ///
    /// Each event is marked as self-generated *before* it is posted. The tap is a head-insert session
    /// tap, so these events come straight back through `KeystrokeSource`'s callback; unmarked, they
    /// would be decoded and fed to the matcher as if the user had typed them. A combo whose replacement
    /// contains its own trigger plus a delimiter (`sig` → `sig `) would then re-enter `insert` on every
    /// pass and recurse. `markAsReposted` is the same marker the source's re-post path writes, and its
    /// short-circuit at the top of `handle` forwards marked events untouched. Marking must precede the
    /// post, not follow it: re-entrant delivery can land while `post` is still on the stack (see
    /// `KeystrokeSource.repostMark`).
    private func type(_ text: String) {
        let source = CGEventSource(stateID: .combinedSessionState)
        for scalar in text.unicodeScalars {
            // `var` only because `keyboardSetUnicodeString` takes an `inout` array; `let` will not compile.
            var utf16 = Array(String(scalar).utf16)
            let down = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true)
            // The real label on this SDK is `stringLength:`, not `maxLength:` -- the compiler decided.
            down?.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            if let down {
                KeystrokeSource.markAsReposted(down)
                clipboard.post(down)
            }
            if let up = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
                KeystrokeSource.markAsReposted(up)
                clipboard.post(up)
            }
        }
    }
}

/// The real system clipboard: the only type in this file that names `NSPasteboard.general`, and the
/// only one that calls `post(tap:)`. No test constructs it.
final class SystemClipboard: ClipboardServing {
    private let pasteboard = NSPasteboard.general

    var itemCount: Int { pasteboard.pasteboardItems?.count ?? 0 }

    func types(forItem index: Int) -> [NSPasteboard.PasteboardType] {
        pasteboard.pasteboardItems?[index].types ?? []
    }

    func data(forItem index: Int, type: NSPasteboard.PasteboardType) -> Data? {
        pasteboard.pasteboardItems?[index].data(forType: type)
    }

    func clearContents() {
        pasteboard.clearContents()
    }

    func appendItem(_ payloads: ClipboardItem) {
        let item = NSPasteboardItem()
        for (type, data) in payloads { item.setData(data, forType: type) }
        pasteboard.writeObjects([item])
    }

    var changeCount: Int { pasteboard.changeCount }

    func scheduleRestore(after delay: TimeInterval, _ work: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func post(_ event: CGEvent) {
        event.post(tap: .cgSessionEventTap)
    }
}
