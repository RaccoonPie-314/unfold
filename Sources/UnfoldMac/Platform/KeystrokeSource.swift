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

    static func route(into event: CGEvent, type: CGEventType) -> RoutedEvent {
        switch type {
        case .keyDown:
            // Auto-repeat carries flag bit 0x400, which has no named member in CGEventFlags. A
            // repeated keydown is not a new keystroke: a trigger is a sequence of distinct presses,
            // and one burst produces a single keyup for many keydowns, which is exactly the shape
            // the ledger cannot reconcile. Treat repeats as uninterpretable so the buffer releases.
            if event.flags.contains(CGEventFlags(rawValue: 0x400)) { return .other }
            guard let character = KeyboardDecoder.character(from: event) else { return .other }
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

    private let handler: (RoutedEvent, CGEventFlags, CGEvent) -> TapOutcome
    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private(set) var isActive = false

    /// Bounded so a hostile environment cannot make us respawn taps in a loop.
    private var reEnableAttempts = 0
    static let maximumReEnableAttempts = 3

    init(handler: @escaping (RoutedEvent, CGEventFlags, CGEvent) -> TapOutcome) {
        self.handler = handler
    }

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

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch handler(Self.route(into: event, type: type), event.flags, event) {
        case .pass(let forwarded):
            return Unmanaged.passUnretained(forwarded)
        case .swallow:
            return nil
        case .repost(let earlier, thenPass: let current):
            // Released keystrokes go back first, in the order they were eaten, so the re-posted
            // prefix cannot land after the character that broke it. Each one gets a synthesized
            // release too: its real keyup almost certainly arrived while the keydown was still
            // buffered and was eaten by the ledger, and re-posting a press with no release leaves
            // the target app believing the key is still held down.
            for original in earlier {
                original.post(tap: .cgSessionEventTap)
                Self.releaseEvent(matching: original)?.post(tap: .cgSessionEventTap)
            }
            return current.map { Unmanaged.passRetained($0) } ?? nil
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
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        isActive = true
        reEnableAttempts = 0
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let runLoopSource { CFRunLoopRemoveSource(CFRunLoopGetCurrent(), runLoopSource, .commonModes) }
        tap = nil
        runLoopSource = nil
        isActive = false
    }

    private func enableAgain() {
        guard reEnableAttempts < KeystrokeSource.maximumReEnableAttempts, let tap else { return }
        reEnableAttempts += 1
        CGEvent.tapEnable(tap: tap, enable: true)
    }
}
