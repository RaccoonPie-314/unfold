import AppKit
import CoreGraphics
import UnfoldEngine
import XCTest
@testable import UnfoldMac

/// A stand-in clipboard for the injector's rules. It keeps the pasteboard item by item, logs every
/// operation in order, and runs no timer.
///
/// It is not `NSPasteboard.general`: that object is the live clipboard of the workstation this runs
/// on, and a test that wrote it would destroy whatever was already copied. The real
/// `post(tap: .cgSessionEventTap)` is likewise confined here, because a synthetic Cmd+V pastes
/// into whatever app has focus. `SystemClipboard` holds both, and no test constructs it.
private final class FakeClipboard: ClipboardServing {
    /// The pasteboard's contents, item by item. A `nil` payload models content the owning app promised
    /// but has not rendered -- the case where a data read answers nil.
    var contents: [[(NSPasteboard.PasteboardType, String?)]] = []
    private(set) var ops: [String] = []
    /// Every item written since the test began, in order, so an assertion can name the sequence.
    private(set) var appends: [ClipboardItem] = []
    private(set) var changeCount = 0
    private(set) var posted: [CGEvent] = []
    private(set) var restoreDelays: [TimeInterval] = []
    private var pending: [() -> Void] = []

    // MARK: ClipboardServing

    var itemCount: Int { contents.count }

    func types(forItem index: Int) -> [NSPasteboard.PasteboardType] { contents[index].map(\.0) }

    func data(forItem index: Int, type: NSPasteboard.PasteboardType) -> Data? {
        ops.append("read(\(type.rawValue))")
        return contents[index].first { $0.0 == type }?.1.map { Data($0.utf8) }
    }

    func clearContents() {
        ops.append("clear")
        contents = []
        changeCount += 1 // `NSPasteboard.clearContents()` moves the changeCount along, too.
    }

    func appendItem(_ payloads: ClipboardItem) {
        ops.append("append(" + payloads.map { "\($0.0.rawValue)=\(String(decoding: $0.1, as: UTF8.self))" }
            .joined(separator: ", ") + ")")
        appends.append(payloads)
        contents.append(payloads.map { ($0.0, String(decoding: $0.1, as: UTF8.self)) })
        changeCount += 1
    }

    func scheduleRestore(after delay: TimeInterval, _ work: @escaping () -> Void) {
        restoreDelays.append(delay)
        pending.append(work)
    }

    func post(_ event: CGEvent) { posted.append(event) }

    // MARK: Test controls

    /// Time passing on the real clipboard means the main queue eventually getting to the deferred
    /// restore. Here it is a call, so the order a test asserts on is chosen rather than raced.
    func fireAllRestores() {
        while let work = pending.first {
            pending.removeFirst()
            work()
        }
    }

    /// The oldest scheduled restore only -- time passing for one expansion's timer, not the next one's.
    func fireNextRestore() {
        guard !pending.isEmpty else { return }
        pending.removeFirst()()
    }

    var scheduledRestoreCount: Int { pending.count }

    /// The single string the pasteboard holds, or nil when it holds anything else.
    var stringPayload: String? {
        guard contents.count == 1, contents[0].count == 1, contents[0][0].0 == .string else { return nil }
        return contents[0][0].1
    }

    /// The `.string` of each appended item, in the order they were appended.
    var appendedStrings: [String] {
        appends.compactMap { payload in
            guard payload.count == 1, payload[0].0 == .string else { return nil }
            return String(decoding: payload[0].1, as: UTF8.self)
        }
    }
}

private let fileURLType = NSPasteboard.PasteboardType("public.file-url")
private let tiffType = NSPasteboard.PasteboardType.tiff

final class InjectorTests: XCTestCase {
    private func clipboard(_ contents: [[(NSPasteboard.PasteboardType, String?)]] = []) -> FakeClipboard {
        let fake = FakeClipboard()
        fake.contents = contents
        return fake
    }

    // MARK: - Rule 1: item boundaries survive capture and restore

    /// A two-item copy -- two files, or a range of spreadsheet cells -- is two pasteboard items. The
    /// pre-fix capture collected every *type* on the board into one flat list, so the restore handed
    /// back one item holding both payloads: the target app then sees a single file where the user
    /// copied two.
    func testATwoItemCopyComesBackAsTwoItemsEachKeepingItsOwnTypes() {
        let board = clipboard([
            [(fileURLType, "/tmp/alpha.txt"), (NSPasteboard.PasteboardType.string, "alpha.txt")],
            [(tiffType, "thumbnail-bytes")],
        ])
        let injector = Injector(clipboard: board)

        injector.insert("snippet", mode: .paste)
        board.fireAllRestores()

        XCTAssertEqual(board.contents.count, 2,
                       "two copied items must not come back as one item with both payloads merged")
        // Compared as whole arrays rather than by indexing: this assertion is the one that fails on
        // the pre-fix capture, and a `contents[1]` would trap instead of reporting.
        XCTAssertEqual(board.contents.map { $0.map(\.0) }, [[fileURLType, .string], [tiffType]])
        XCTAssertEqual(board.contents.map { $0.compactMap(\.1) },
                       [["/tmp/alpha.txt", "alpha.txt"], ["thumbnail-bytes"]],
                       "the second item's image must stay in the second item")
    }

    // MARK: - Rule 2: nothing captured means nothing to clear

    /// Every payload readable on the board is a promise the owning app has not rendered yet, so the
    /// capture yields nothing. Restoring "nothing" the old way meant `clearContents()` with no writes
    /// after it -- an empty pasteboard, and the user's next Cmd+V pastes nothing at all.
    func testAnEmptyCaptureLeavesThePasteboardAloneInsteadOfEmptyingIt() {
        let board = clipboard([[(fileURLType, nil)]])
        let injector = Injector(clipboard: board)

        injector.insert("snippet", mode: .paste)
        board.fireAllRestores()

        XCTAssertFalse(board.ops.suffix(1).contains("clear"),
                       "with nothing captured the restore must not clear: \(board.ops)")
        XCTAssertEqual(board.contents.count, 1,
                       "an empty capture must leave the pasteboard holding what it holds, not empty it")
        XCTAssertEqual(board.stringPayload, "snippet")
    }

    // MARK: - Rule 3: a second expansion may not capture the first snippet

    /// Two expansions inside the restore delay. Without a synchronous flush the second capture reads
    /// the *first snippet's* text off the board and restores that, so the user's own payload is gone
    /// for good. Flushing the pending restore first means the second capture sees the original.
    func testASecondExpansionInsideTheRestoreWindowRestoresTheUsersPayloadBeforeItCaptures() {
        let board = clipboard([[(NSPasteboard.PasteboardType.string, "the user's own copy")]])
        let injector = Injector(clipboard: board)

        injector.insert("first snippet", mode: .paste)
        injector.insert("second snippet", mode: .paste)

        XCTAssertEqual(board.appendedStrings, ["first snippet", "the user's own copy", "second snippet"],
                       "the pending restore must be flushed between the two expansions: \(board.ops)")

        board.fireAllRestores()
        XCTAssertEqual(board.stringPayload, "the user's own copy",
                       "the user's copy must still be on the pasteboard after both expansions")
    }

    /// The flush above leaves the first expansion's timer still scheduled -- a closure that, without a
    /// generation, would run whatever restore is pending when it fires. Two expansions 0.1 s apart put
    /// the second snapshot on the first timer's clock: it restores the user's copy after 0.15 s, before
    /// the target app's 0.25 s read window for the second snippet is up. Only the timer that belongs to
    /// the pending snapshot may run it.
    func testTheFirstExpansionsTimerCannotRestoreTheSecondExpansionsSnapshotEarly() {
        let board = clipboard([[(NSPasteboard.PasteboardType.string, "the user's own copy")]])
        let injector = Injector(clipboard: board)

        injector.insert("first snippet", mode: .paste)
        injector.insert("second snippet", mode: .paste)
        XCTAssertEqual(board.scheduledRestoreCount, 2, "each expansion schedules its own restore")

        // Time passes for the first expansion's timer only. Its restore was flushed already, so this
        // firing has nothing of its own left to do.
        board.fireNextRestore()
        XCTAssertEqual(board.stringPayload, "second snippet",
                       "a stale timer must not put the user's copy back before the second paste is read")
        XCTAssertEqual(board.scheduledRestoreCount, 1)

        board.fireAllRestores()
        XCTAssertEqual(board.stringPayload, "the user's own copy")
    }

    // MARK: - Rules the seam refactor must not disturb

    /// R-P2-4: the restore stands down when the target app wrote the pasteboard itself. The changeCount
    /// guard is the whole reason the restore is deferred, and it now runs on the flush path too.
    func testTheRestoreStandsDownWhenTheAppWroteThePasteboardItself() {
        let board = clipboard([[(NSPasteboard.PasteboardType.string, "the user's own copy")]])
        let injector = Injector(clipboard: board)

        injector.insert("snippet", mode: .paste)
        // The user copies something of their own before the delay expires.
        board.clearContents()
        board.appendItem([(.string, Data("the app's own new copy".utf8))])

        board.fireAllRestores()
        XCTAssertEqual(board.stringPayload, "the app's own new copy",
                       "a restore that lands after the user's own copy would throw it away")
    }

    func testAPasteInsertionWritesTheSnippetAsOneStringItemAndPostsPaste() {
        let board = clipboard([[(NSPasteboard.PasteboardType.string, "the user's own copy")]])
        let injector = Injector(clipboard: board)

        injector.insert("snippet", mode: .paste)

        XCTAssertEqual(board.stringPayload, "snippet", "the replacement goes on the board alone")
        XCTAssertEqual(board.posted.count, 2, "Cmd+V is a press and a release")
        XCTAssertEqual(board.posted.first?.getIntegerValueField(.keyboardEventKeycode), 9,
                       "the paste shortcut is V")
        XCTAssertTrue(board.posted.first?.flags.contains(.maskCommand) ?? false)
        XCTAssertEqual(board.restoreDelays, [0.25], "the restore is deferred past the app's read")
    }

    /// `.keys` types the replacement instead of pasting it, so it must never take the clipboard's
    /// contents down at all.
    func testAKeysInsertionDoesNotTouchThePasteboard() {
        let board = clipboard([[(NSPasteboard.PasteboardType.string, "the user's own copy")]])
        let injector = Injector(clipboard: board)

        injector.insert("ab", mode: .keys)

        XCTAssertEqual(board.ops, [], "typing a replacement neither reads nor rewrites the clipboard")
        XCTAssertEqual(board.stringPayload, "the user's own copy")
        XCTAssertEqual(board.posted.count, 4, "two scalars, each a press and a release")
        XCTAssertEqual(board.scheduledRestoreCount, 0, "nothing deferred, so nothing to restore")
    }

    // MARK: - Rule 4: a .keys insertion is marked for the tap's short-circuit

    /// The tap is a head-insert session tap, so every event `.keys` posts travels through it on the
    /// way to the target app. If those events are unmarked the tap decodes them and hands them to the
    /// matcher as if the user had typed them -- the replacement re-enters matching, and a combo like
    /// `sig` → `sig ` (its own trigger plus a delimiter) fires itself again. The injector must tag
    /// each one with the same marker the source checks before anything else.
    func testEveryEventAKeysInsertionPostsCarriesTheRepostMark() {
        let board = clipboard()
        let injector = Injector(clipboard: board)

        injector.insert("ab", mode: .keys)

        XCTAssertEqual(board.posted.count, 4, "two scalars, each a press and a release")
        XCTAssertTrue(board.posted.allSatisfy(KeystrokeSource.isReposted),
                      "every synthetic keystroke must carry the mark the tap's short-circuit checks")
    }

    /// The reviewer's regression, pinned at the seam. `Injector` has no matcher of its own, so this
    /// is only provable as a composition: the injector's mark is fed to the source's short-circuit,
    /// with the handler standing in for "dispatch to the matcher". Nothing may reach that handler.
    ///
    /// `sig` → `sig ` is the shape that recursed: the replacement contains the trigger plus a
    /// delimiter, so each decoded pass re-enters `insert`. The tap is not started -- no bridge call is
    /// reachable here -- so this pins the decision, not the delivery.
    func testAKeysInsertionOfItsOwnTriggerIsShortCircuitedBeforeTheMatcher() {
        let board = clipboard()
        let injector = Injector(clipboard: board)
        injector.insert("sig ", mode: .keys)

        var dispatched: [CGEvent] = []
        let source = KeystrokeSource(
            handler: { _, _, event in
                dispatched.append(event)
                return .swallow
            },
            bridge: KeystrokeSource.TapBridge(create: { _, _ in nil },
                                              enable: { _ in false },
                                              disable: { _ in },
                                              isEnabled: { _ in false })
        )

        for event in board.posted {
            let returned = source.handle(type: .keyDown, event: event)
            XCTAssertTrue(returned?.takeUnretainedValue() === event,
                          "a marked synthetic keystroke is forwarded untouched, never swallowed")
        }

        XCTAssertTrue(dispatched.isEmpty,
                      "the replacement reached the matcher; sig → sig  would recurse on the next pass")
    }
}
