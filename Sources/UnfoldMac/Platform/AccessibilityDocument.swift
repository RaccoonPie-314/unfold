import ApplicationServices
import CoreGraphics
import Foundation
import UnfoldEngine

/// The word at the end of a run of text.
enum DocumentWord {
    /// The trailing run of word characters, which is the only part of the text a trigger can be
    /// competing with. Everything before a delimiter is somebody else's word.
    static func trailingWord(_ text: String) -> String {
        String(text.reversed().prefix { isWordCharacter($0) }.reversed())
    }
}

/// The text the user is actually looking at, as the app that owns it reports it.
protocol FocusedTextReading {
    /// The focused field's whole text. Nil when nothing is focused, or the field will not say.
    func value() -> String?
    /// The caret or selection, in UTF-16 units. Nil when the field will not say.
    func selectedRange() -> CFRange?
    /// Select the `units` immediately before the caret, and read the selection back. True only when the
    /// field reports exactly what it was asked for.
    func select(unitsBeforeCaret units: Int) -> Bool

    /// Which of the two reads failed, for the log line that says nothing could be verified. "silent"
    /// alone does not tell us whether the app has no focused element, exposes a caret but no text, or
    /// exposes text but no caret -- and those are three different problems.
    func silenceReport() -> String
}

extension FocusedTextReading {
    /// A scripted field in a test has no process to interrogate.
    func silenceReport() -> String { "scripted field" }
}

/// What the document said about the trigger the user just typed.
enum TriggerErase {
    /// The trigger sat before the caret and the field now has it selected, so the replacement paste
    /// lands on it and nowhere else.
    case selected
    /// The field reported its own contents, and they are not this trigger. Rewriting here would delete
    /// text the user did not type, so the expansion stands down.
    case absent
    /// The field would not say what it holds or where the caret is. Nothing can be confirmed, so the
    /// keystroke tally is all there is to work from.
    case unknown
}

/// The live Accessibility view of the focused field.
///
/// Every messaging call carries a short timeout. These reads happen on the main thread, which is the
/// thread that hosts the event tap: one hung target app would otherwise stall the callback long enough
/// for macOS to switch the tap off mid-sentence.
struct SystemFocusedText: FocusedTextReading {
    private static let messagingTimeout: Float = 0.15

    private func focusedElement() -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        var element: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &element) == .success,
              let element, CFGetTypeID(element) == AXUIElementGetTypeID() else { return nil }
        let focused = element as! AXUIElement
        AXUIElementSetMessagingTimeout(focused, Self.messagingTimeout)
        return focused
    }

    func value() -> String? {
        guard let element = focusedElement() else { return nil }
        return Self.value(of: element)
    }

    private static func value(of element: AXUIElement) -> String? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &raw) == .success else {
            return nil
        }
        return raw as? String
    }

    func selectedRange() -> CFRange? {
        guard let element = focusedElement() else { return nil }
        return Self.selection(of: element)
    }

    func silenceReport() -> String {
        guard let element = focusedElement() else { return "no focused element" }
        let caret = Self.selection(of: element)
        let length = Self.value(of: element)?.utf16.count
        switch (caret, length) {
        case (nil, nil): return "focused element answers neither value nor range"
        case (nil, let value?): return "value only (\(value) units), no caret range"
        case (let range?, nil): return "caret only (\(range.location),\(range.length)), no value"
        case (let range?, let value?): return "both answered (value \(value) units, caret \(range.location))"
        }
    }

    func select(unitsBeforeCaret units: Int) -> Bool {
        guard units > 0, let element = focusedElement(), let caret = Self.selection(of: element),
              caret.location >= units else { return false }
        let requested = CFRange(location: caret.location - units, length: units)
        var payload = requested
        guard let value = AXValueCreate(AXValueType.cfRange, &payload) else { return false }
        guard AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success
        else { return false }
        // Read it back. A field that takes the call and then puts the selection somewhere else -- or
        // extends it past the trigger -- must not be pasted over.
        return Self.selection(of: element).map { $0.location == requested.location
            && $0.length == requested.length } == true
    }

    private static func selection(of element: AXUIElement) -> CFRange? {
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &raw) == .success,
              let raw, CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        let wrapped = raw as! AXValue
        guard AXValueGetType(wrapped) == AXValueType.cfRange else { return nil }
        var range = CFRange(location: 0, length: 0)
        guard AXValueGetValue(wrapped, AXValueType.cfRange, &range) else { return nil }
        return range
    }
}

/// Asks the document -- not the keystroke tally -- whether the trigger is where the replacement is about
/// to go.
///
/// The tally is a promise about events this app saw; it cannot know what the target app did with them.
/// Two real failures come from that gap: a posted backspace spent on something other than a character
/// (Chromium's omnibox uses the first one to drop its inline autocomplete), and a rewrite that runs
/// after the user has already typed the next word, which then deletes that word instead. Both leave
/// part of the trigger on screen, and both were seen live.
struct DocumentTriggerEraser {
    let text: FocusedTextReading

    init(text: FocusedTextReading = SystemFocusedText()) {
        self.text = text
    }

    func erase(trigger: String) -> TriggerErase {
        let units = Array(trigger.utf16)
        guard !units.isEmpty else { return .unknown }
        guard let caret = text.selectedRange(), caret.length == 0, caret.location >= units.count,
              let value = text.value() else { return .unknown }

        let document = Array(value.utf16)
        let start = caret.location - units.count
        // A caret the reported text cannot contain means the two answers came from different states,
        // which is a field that will not answer reliably -- not evidence about the user's text.
        guard caret.location <= document.count else { return .unknown }
        let before = String(decoding: document[start..<caret.location], as: UTF16.self)
        // Case alone does not make it somebody else's text. TextEdit capitalises the first word of a
        // sentence as it is typed, so the trigger the user typed arrives in the document as `Addr`; the
        // matcher only fired because it is ours. Standing down there would lose the expansion.
        guard before == trigger || before.lowercased() == trigger.lowercased() else { return .absent }

        return text.select(unitsBeforeCaret: units.count) ? .selected : .unknown
    }

    /// Why the last answer was `unknown`. Only reached on the failure path, where the extra reads cost
    /// nothing.
    func silenceReport() -> String { text.silenceReport() }
}
