import CoreGraphics
import Foundation

/// What the tap callback should do with the event in hand, expressed at the CoreGraphics boundary:
/// forward an event, drop it, or re-post the buffered ones first and optionally forward another.
public enum TapOutcome {
    case pass(CGEvent)
    case swallow
    case repost([CGEvent], thenPass: CGEvent?)
}

/// Owns the system-wide CGEventTap: creation, the C callback bridge, and teardown.
///
/// This type is deliberately transport-only -- every decision comes from the `handler` Task 6's
/// coordinator supplies. It must never be started (no `start()` call, no live `CGEvent.tapCreate`)
/// until turning a system-wide tap on is approved; that is Task 7's gate.
public final class KeystrokeSource {
    /// keyDown for characters, keyUp so swallowed presses do not leave keys stuck down in the
    /// target app, flagsChanged so a modifier press can drop a half-typed trigger.
    static let interestedMask: CGEventMask =
        (1 << CGEventType.keyDown.rawValue) |
        (1 << CGEventType.keyUp.rawValue) |
        (1 << CGEventType.flagsChanged.rawValue)

    // MARK: - The re-post mark

    /// The value written into `kCGEventSourceUserData` ("a field that contains the event source
    /// user-supplied data, up to 64 bits") of every event this type posts -- CoreGraphics' tagged
    /// per-event user data, the one facility on a `CGEvent` that survives the trip out and back.
    /// The "UNFL" spelling is deliberate: a field value caught in a crash log or a debugger names the
    /// process that tagged it. Probed on this SDK: the field is 0 on a freshly constructed event and
    /// setting it on one event leaves every other event at 0.
    ///
    /// THE MARK MUST BE SET BEFORE `post(tap:)`, NOT AFTER. `CGEventPost` documents that it "posts
    /// the specified event immediately before any event taps instantiated for that location, and the
    /// event passes through any such taps" -- for a head-insert session tap, that includes the tap
    /// whose callback is running right now. The re-entrant delivery can therefore land before the
    /// line after `post` executes, so a mark applied afterwards is a race with the callback it is
    /// meant to protect. What happens if the order is wrong is the failure this field exists to
    /// prevent: the re-entrant `handle` reads an unmarked event, sends the released prefix back to the
    /// handler, the handler swallows it again, the repost arm posts it again, and each pass re-enters
    /// this callback -- duplicated keystrokes escalating until macOS disables the tap for being slow,
    /// mid-sentence, with the user's own text in the stream.
    static let repostMark: Int64 = 0x554E_464C

    static func markAsReposted(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: repostMark)
    }

    static func isReposted(_ event: CGEvent) -> Bool {
        event.getIntegerValueField(.eventSourceUserData) == repostMark
    }

    // MARK: - Scalars that are not text

    /// The control scalars that genuinely are part of typing, checked before the inert ranges so they
    /// survive the sweep: Tab, Line Feed, Carriage Return, Space. Tab and Return close a trigger the
    /// same way they close it in the app, and Space is the word boundary.
    private static let keptControlScalars: Set<UInt32> = [0x0009, 0x000A, 0x000D, 0x0020]

    /// General Category Cc -- the C0 controls plus DEL through C1.
    private static let controlRanges: [ClosedRange<UInt32>] = [0x0000...0x001F, 0x007F...0x009F]

    /// General Category Cf: invisible shapers (soft hyphen, zero-width and bidi controls, word
    /// joiners, the annotation anchors, tag characters). No keyboard layout puts one of these in a
    /// payload that means prose, and none of them can be a character of a trigger.
    private static let formatRanges: [ClosedRange<UInt32>] = [
        0x00AD...0x00AD, 0x0600...0x0605, 0x061C...0x061C, 0x06DD...0x06DD,
        0x070F...0x070F, 0x0890...0x0891, 0x08E2...0x08E2, 0x180E...0x180E,
        0x200B...0x200F, 0x202A...0x202E, 0x2060...0x2064, 0x2066...0x206F,
        0xFEFF...0xFEFF, 0xFFF9...0xFFFB, 0x110BD...0x110BD, 0x13430...0x1343F,
        0x1BCA0...0x1BCA3, 0x1D173...0x1D17A, 0xE0001...0xE0001, 0xE0020...0xE007F,
    ]

    /// General Category Co, the private-use planes. The BMP block already contains Apple's
    /// function/arrow scalars, which are spelled out below because they are what a real arrow key
    /// actually reports.
    private static let privateUseRanges: [ClosedRange<UInt32>] = [
        0xE000...0xF8FF, 0xF0000...0xFFFFD, 0x100000...0x10FFFD,
    ]

    /// Apple's function- and arrow-key block (NSUpArrowFunctionKey and friends).
    private static let appleFunctionRanges: [ClosedRange<UInt32>] = [0xF700...0xF7FF]

    /// True for a decoded scalar that must never be offered to the matcher.
    ///
    /// The reason this exists is that an unmapped key is not silence: this SDK hands back a
    /// per-keycode stand-in -- arrows U+001C/U+001D/U+001E/U+001F, Home U+0001, End U+0004, F1
    /// U+0010, Backspace U+0008, Escape U+001B, forward-delete U+007F -- and a real arrow or function
    /// key reports U+F700...U+F7FF. Each is a single non-word `Character`, so fed to the matcher it acts
    /// as a delimiter and FIRES an expansion: pressing Backspace or Escape halfway through typing a
    /// trigger rewrote the user's text. `route` turns them into `.other`, which makes the router
    /// release the buffered prefix and pass the key through.
    ///
    /// Two categories are worth stating how they are reached rather than pretended away:
    ///  - DEL (U+007F) is written out even though it is inside a Cc range, because it is not a C0
    ///    control and it is the most destructive member of the set -- it is forward-delete.
    ///  - Cs (surrogates) cannot be tested here at all: `Unicode.Scalar` refuses to hold a value in
    ///    U+D800...U+DFFF, so a lone surrogate in a UTF-16 payload has already degraded to U+FFFD by the
    ///    time `KeyboardDecoder` returns a `String`. U+FFFD is listed because it means exactly that --
    ///    the payload lied about being text.
    private static func isInertScalar(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        if keptControlScalars.contains(value) { return false }
        if value == 0x007F || value == 0xFFFD { return true }
        for ranges in [controlRanges, formatRanges, privateUseRanges, appleFunctionRanges] {
            if ranges.contains(where: { $0.contains(value) }) { return true }
        }
        return false
    }

    // MARK: - Routing

    static func route(into event: CGEvent, type: CGEventType) -> RoutedEvent {
        switch type {
        case .keyDown:
            // Auto-repeat carries flag bit 0x400, which has no named member in CGEventFlags. A
            // repeated keydown is not a new keystroke: a trigger is a sequence of distinct presses,
            // and one burst produces a single keyup for many keydowns, which is exactly the shape
            // the ledger cannot reconcile. Treat repeats as uninterpretable so the buffer releases.
            if event.flags.contains(CGEventFlags(rawValue: 0x400)) { return .other }
            guard let character = KeyboardDecoder.character(from: event) else { return .other }
            // Decoding succeeded is not the same as being text; see `isInertScalar`.
            if character.unicodeScalars.contains(where: isInertScalar) { return .other }
            return .keyDown(character, KeyboardDecoder.keyCode(from: event))
        case .keyUp:
            return .keyUp(KeyboardDecoder.keyCode(from: event))
        default:
            return .other
        }
    }

    /// The release half of a swallowed keydown, synthesized for re-posting. See the repost arm of the
    /// tap callback for why a bare re-posted press is not enough.
    static func releaseEvent(matching event: CGEvent) -> CGEvent? {
        CGEvent(keyboardEventSource: nil,
                virtualKey: CGKeyCode(KeyboardDecoder.keyCode(from: event)),
                keyDown: false)
    }

    /// The exact list the repost arm hands to `post(tap:)`: each buffered press, in the order it was
    /// eaten, immediately followed by its synthesized release -- and every one of them marked.
    ///
    /// Split out of the callback so that the marking is unit-testable while the posting is not. The
    /// mark is written into the coordinator's own event objects; that is deliberate, because the
    /// object we post is the object whose re-dispatch must be recognized (see `repostMark` for why
    /// the mark has to be on it before `post` runs). They are leaving the ledger with this call and
    /// nothing else reads this field, so mutating in place cannot mislabel a keystroke to come.
    static func eventsToPost(forRepost earlier: [CGEvent]) -> [CGEvent] {
        var outgoing: [CGEvent] = []
        for original in earlier {
            markAsReposted(original)
            outgoing.append(original)
            if let release = releaseEvent(matching: original) {
                markAsReposted(release)
                outgoing.append(release)
            }
        }
        return outgoing
    }

    // MARK: - Retention

    /// Which side owns the event the tap callback hands back.
    enum CallbackOwnership: Equatable {
        /// The object is the one CoreGraphics handed in: it stays CG's, so the callback returns
        /// `Unmanaged.passUnretained`.
        case coreGraphicsStillOwnsIt
        /// A different object, substituted in its place: the callback returns `Unmanaged.passRetained`
        /// and the +1 it hands over is balanced by the release CG performs on the return value.
        case callbackTookOwnership
    }

    /// Retention is decided by identity, never by which arm of the switch produced the event.
    ///
    /// Arm-based rules are what was wrong here before: `.pass` returned `passUnretained` even when the
    /// handler handed back an event it had built (under-retain -- CG's release over-releases an object
    /// its owner still holds), and `.repost`'s tail returned `passRetained` even when the tail was the
    /// very object CoreGraphics passed in (over-retain -- one leaked `CGEvent` per release). Both bugs
    /// are the same question, so both arms now ask it once.
    ///
    /// Ownership map for the repost arm, which is where the temptation to "just retain everything"
    /// comes from: the buffered events in `earlier` belong to the coordinator and ARC balances them
    /// when the local list goes out of scope; each synthesized release belongs to this function and
    /// dies with it; only the event returned from `handle` crosses the boundary to CoreGraphics, and
    /// only then does identity decide whether we are lending it or giving it.
    static func ownership(of forwarded: CGEvent, comparedTo handedIn: CGEvent) -> CallbackOwnership {
        forwarded === handedIn ? .coreGraphicsStillOwnsIt : .callbackTookOwnership
    }

    /// The one place `Unmanaged` is written, so the two arms of the switch cannot drift apart again.
    private static func handBack(_ forwarded: CGEvent,
                                 handedInByCoreGraphics handedIn: CGEvent) -> Unmanaged<CGEvent> {
        switch ownership(of: forwarded, comparedTo: handedIn) {
        case .coreGraphicsStillOwnsIt: return Unmanaged.passUnretained(forwarded)
        case .callbackTookOwnership: return Unmanaged.passRetained(forwarded)
        }
    }

    // MARK: - Live state

    private let handler: (RoutedEvent, CGEventFlags, CGEvent) -> TapOutcome
    private var tap: CFMachPort?

    /// The run loop that was actually given `runLoopSource`, remembered so `stop()` removes from it
    /// instead of from whatever loop its caller happens to be running.
    private var runLoop: CFRunLoop?
    private var runLoopSource: CFRunLoopSource?
    private(set) var isActive = false

    /// Bounded so a tap that cannot be re-enabled is not retried forever. The count is of consecutive
    /// failures: a re-enable that observably took restores the budget (see `enableAgain`), so unrelated
    /// timeouts spread over an afternoon cannot add up to expansion silently stopping.
    private var reEnableAttempts = 0
    static let maximumReEnableAttempts = 3

    init(handler: @escaping (RoutedEvent, CGEventFlags, CGEvent) -> TapOutcome) {
        self.handler = handler
    }

    /// The tap was created with `Unmanaged.passUnretained(self)` as its refcon, so CoreGraphics holds
    /// an unowned pointer to this object. If the coordinator drops the last reference while the tap is
    /// live, every keystroke that follows dereferences a dangling pointer. Tearing the tap down is the
    /// only thing a deinit here can safely do.
    deinit { stop() }

    /// The callback must be a C function pointer, so state arrives through `refcon`. Nothing here
    /// may throw, allocate unboundedly, or block: a slow callback gets the tap disabled by macOS.
    private static let callback: CGEventTapCallBack = { _, type, event, refcon in
        guard let refcon else { return Unmanaged.passUnretained(event) }
        let source = Unmanaged<KeystrokeSource>.fromOpaque(refcon).takeUnretainedValue()

        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            source.enableAgain()
            return Unmanaged.passUnretained(event)
        case .keyDown, .keyUp, .flagsChanged:
            return source.handle(type: type, event: event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    /// The body of the callback once the out-of-band types have been routed.
    ///
    /// Internal only so the re-entrancy guard and the identity decision are reachable from a test.
    /// The `.repost` arm calls `post(tap:)`, which injects real events into the user's session -- no
    /// test may drive that arm; hand it `.pass` or `.swallow` and keep `start()` uncalled.
    @discardableResult
    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Re-entrancy guard, ahead of every decision: an event this type posted comes straight back
        // through this callback, and the only correct thing to do with it is let it go. See
        // `repostMark` for why it has to be applied before the post.
        if Self.isReposted(event) { return Unmanaged.passUnretained(event) }

        switch handler(Self.route(into: event, type: type), event.flags, event) {
        case .pass(let forwarded):
            return Self.handBack(forwarded, handedInByCoreGraphics: event)
        case .swallow:
            return nil
        case .repost(let earlier, thenPass: let current):
            // Released keystrokes go back first, in the order they were eaten, so the re-posted
            // prefix cannot land after the character that broke it. Each one gets a synthesized
            // release too: its real keyup almost certainly arrived while the keydown was still
            // buffered and was eaten by the ledger, and re-posting a press with no release leaves
            // the target app believing the key is still held down.
            for outgoing in Self.eventsToPost(forRepost: earlier) {
                outgoing.post(tap: .cgSessionEventTap)
            }
            guard let current else { return nil }
            return Self.handBack(current, handedInByCoreGraphics: event)
        }
    }

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return isActive }
        let mask = KeystrokeSource.interestedMask
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: KeystrokeSource.callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        tap = port
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        runLoopSource = source
        // Remember the loop the source was given: `CFRunLoopGetCurrent()` in `stop()` is a different
        // loop when the two run on different threads, and removing from the wrong one leaves a live
        // tap that nothing can take down -- feeding a callback whose refcon may already be gone.
        let loop = CFRunLoopGetCurrent()
        runLoop = loop
        CFRunLoopAddSource(loop, source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        // `CGEventTapEnable` returns nothing, so enablement is read back rather than assumed; a tap
        // that exists but refused to switch on must not report itself active.
        isActive = CGEvent.tapIsEnabled(tap: port)
        reEnableAttempts = 0
        return isActive
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoop, let runLoopSource {
            CFRunLoopRemoveSource(runLoop, runLoopSource, .commonModes)
        }
        tap = nil
        runLoop = nil
        runLoopSource = nil
        isActive = false
    }

    private func enableAgain() {
        guard let tap else { return }
        guard reEnableAttempts < KeystrokeSource.maximumReEnableAttempts else {
            // Out of budget. Correct the claim rather than keep it: an `isActive` that survives here
            // is a menu bar insisting the user's abbreviations are live while nothing expands.
            isActive = false
            return
        }
        reEnableAttempts += 1
        CGEvent.tapEnable(tap: tap, enable: true)
        if CGEvent.tapIsEnabled(tap: tap) {
            // The re-enable observably took, so this disable was a one-off and the consecutive-failure
            // budget starts over. Without the decay, three unrelated timeouts spread over hours add up
            // to expansion permanently stopping -- while the old code kept reporting it as active.
            reEnableAttempts = 0
            isActive = true
        } else {
            isActive = false
        }
    }
}
