import AppKit
import UnfoldEngine
import UnfoldMac

/// End-to-end consistency harness: types each registered trigger into the app's own "Try it" field,
/// reads the field back, and counts the rounds that came out exactly right.
///
/// It exists because "works, but not every time" cannot be fixed by reading code -- it needs a number,
/// and it needs the *document*. The coordinator's log says how many characters it meant to erase; only
/// the field says what was actually left there.
///
/// The field belongs to this app on purpose. Typing into someone else's window needs that app to be
/// front, and activation from an accessory process is not dependable: rounds aimed at whichever window
/// happened to be key reported either nothing or the previous round's text, which is a broken ruler,
/// not a broken expander. Reading our own text view in-process has no such lottery -- and the field is
/// ordinary Cocoa text, so the tap, the matcher and the rewrite are all still on the path.
///
/// Bring-up instrumentation: it writes `/tmp/unfold-selftest.log`.
final class ConsistencyTest {
    struct Case {
        let typed: String
        let expected: String
        /// Seconds between keystrokes. A rewrite that only survives a slow typist is not a rewrite.
        let gap: TimeInterval
        /// Character index → how many auto-repeat keydowns to send while that key is held. The typed
        /// string leaves out the characters the repeats produce, so `typed` is the *presses*, not the
        /// text that lands in the document.
        var repeats: [Int: Int] = [:]
    }

    private static let settleInterval = 0.25
    /// Three reads in agreement. Two can both land in the pause between keystrokes of a round that is
    /// still typing, which scores the middle of a sentence.
    private static let settleAgreement = 3
    private static let settleLimit = 4.0

    private let coordinator: ExpansionCoordinator
    private let textView: NSTextView
    private var cases: [Case] = []

    private(set) var isRunning = false
    private(set) var summary = "not run yet"

    private var passes = 0
    private var failures = 0
    private var total = 0

    init(coordinator: ExpansionCoordinator, textView: NSTextView) {
        self.coordinator = coordinator
        self.textView = textView
    }

    /// Triggers whose doubled letter is typed as one held press. A fast `dd` arrives as a keydown, an
    /// auto-repeat keydown and a single keyup, and the document gains two characters from it -- so the
    /// matcher has to count the repeat or the trigger never completes.
    static func heldCases(from coordinator: ExpansionCoordinator) -> [Case] {
        expandableCombos(from: coordinator).compactMap { combo in
            let letters = Array(combo.trigger)
            guard let doubled = letters.indices.dropLast().first(where: { letters[$0] == letters[$0 + 1] })
            else { return nil }
            var presses = letters
            presses.remove(at: doubled + 1)
            return Case(typed: String(presses) + " ", expected: plainText(combo) + " ",
                        gap: 0.05, repeats: [doubled: 1])
        }
    }

    /// Randomised rounds: typing speed, delimiter and finger shape change every time, because
    /// "sometimes it does not work" is only answerable by a run that varies what "sometimes" means.
    /// Each round is expected to behave in one of three ways -- expand, expand despite a held doubled
    /// letter, or stay literal because a hold put a character in the document that the trigger does
    /// not have.
    static func stressCases(count: Int, from coordinator: ExpansionCoordinator) -> [Case] {
        let combos = expandableCombos(from: coordinator)
        guard !combos.isEmpty else { return [] }
        let delimiters = [" ", ", ", ". ", "\n"]
        return (0..<count).map { index in
            let combo = combos[index % combos.count]
            let delimiter = delimiters[Int.random(in: 0..<delimiters.count)]
            let gap = Double.random(in: 0.02...0.18)
            let replacement = plainText(combo) + delimiter

            if index % 4 == 1, let held = doubledIndex(combo.trigger) {
                // One press of the pair, held past the repeat threshold: the document still reads as
                // the trigger, so this must expand.
                var presses = Array(combo.trigger)
                presses.remove(at: held + 1)
                return Case(typed: String(presses) + delimiter, expected: replacement, gap: gap,
                            repeats: [held: 1])
            }
            if index % 4 == 3, let correction = correctionCases(combo: combo, delimiter: delimiter).first {
                return correction
            }
            if index % 4 == 2 {
                // A hold on the first letter puts a character in the document that the trigger does
                // not have. Nothing should fire, and nothing may be overwritten.
                let letters = Array(combo.trigger)
                let literal = String(letters[0]) + combo.trigger + delimiter
                return Case(typed: combo.trigger + delimiter, expected: literal, gap: gap,
                            repeats: [0: 1])
            }
            return Case(typed: combo.trigger + delimiter, expected: replacement, gap: gap)
        }
    }

    /// Type a word wrong and fix it by hand. Two shapes, because they seed different words: deleting
    /// everything after the mistake and retyping the tail, versus deleting *less* and retyping less --
    /// `adddr`, two backspaces, `r `. The keystroke stream never spells the trigger in order either way,
    /// so this only works if the candidate comes back from the model of the screen. Typing the delimiter
    /// first would hide the bug, which is how an earlier version of this round passed for nothing.
    static func correctionCases(from coordinator: ExpansionCoordinator) -> [Case] {
        expandableCombos(from: coordinator).flatMap { correctionCases(combo: $0, delimiter: " ") }
    }

    private static func correctionCases(combo: Combo, delimiter: String) -> [Case] {
        guard let doubled = doubledIndex(combo.trigger) else { return [] }
        let letters = Array(combo.trigger)
        var typo = letters
        typo.insert(letters[doubled], at: doubled + 1)

        let full = Case(typed: String(typo)
                            + String(repeating: "\u{08}", count: typo.count - (doubled + 1))
                            + String(letters[(doubled + 1)...]) + delimiter,
                        expected: plainText(combo) + delimiter,
                        gap: 0.05)
        let partial = Case(typed: String(typo)
                               + String(repeating: "\u{08}", count: typo.count - letters.count + 1)
                               + String(letters[letters.count - 1]) + delimiter,
                           expected: plainText(combo) + delimiter,
                           gap: 0.05)
        // The shape reported as the one that fails: the wrong word is committed with its delimiter
        // first, and only then deleted back to the divergence and retyped.
        let committed = Case(typed: String(typo) + delimiter
                                 + String(repeating: "\u{08}", count: typo.count + delimiter.count - (doubled + 1))
                                 + String(letters[(doubled + 1)...]) + delimiter,
                             expected: plainText(combo) + delimiter,
                             gap: 0.05)
        return [full, partial, committed]
    }

    private static func doubledIndex(_ trigger: String) -> Int? {
        let letters = Array(trigger)
        return letters.indices.dropLast().first { letters[$0] == letters[$0 + 1] }
    }

    /// The literal complaint: "it works once and that is it." One field, one line, the same trigger
    /// typed back to back with a space between each -- no clearing, no setup between rounds, so anything
    /// the first expansion leaves behind shows up here.
    static func repeatCases(from coordinator: ExpansionCoordinator, times: Int = 5) -> [Case] {
        expandableCombos(from: coordinator).map { combo in
            let unit = combo.trigger + " "
            return Case(typed: String(repeating: unit, count: times),
                        expected: String(repeating: plainText(combo) + " ", count: times),
                        gap: 0.05)
        }
    }

    func start(roundsPerCase: Int = 2, stressRounds: Int = 0, onUpdate: @escaping (String) -> Void) {
        guard !isRunning else { return }
        cases = stressRounds > 0
            ? Self.stressCases(count: stressRounds, from: coordinator)
            : Self.singleTriggerCases(from: coordinator, roundsPerCase: roundsPerCase)
                + Self.proseCases(from: coordinator)
                + Self.heldCases(from: coordinator)
                + Self.correctionCases(from: coordinator)
                + Self.repeatCases(from: coordinator)
        guard !cases.isEmpty else {
            summary = "nothing to test — no text-only combos"
            onUpdate(summary)
            return
        }
        isRunning = true
        passes = 0
        failures = 0
        total = 0
        summary = "running \(cases.count) rounds…"
        onUpdate(summary)
        append("=== \(stamp) \(cases.count) rounds ===")
        runNext(0, onUpdate: onUpdate)
    }

    /// Each combo on its own, fired by a space.
    static func singleTriggerCases(from coordinator: ExpansionCoordinator,
                                   roundsPerCase: Int) -> [Case] {
        let one = expandableCombos(from: coordinator).map { combo in
            Case(typed: combo.trigger + " ", expected: plainText(combo) + " ", gap: 0.04)
        }
        return one.flatMap { Array(repeating: $0, count: roundsPerCase) }
    }

    /// Prose with a trigger inside it: the keystrokes after the delimiter are already on their way while
    /// the rewrite is queued, which is where a rewrite that lands late deletes the wrong characters.
    /// Rounds run at a comfortable speed and a fast one.
    static func proseCases(from coordinator: ExpansionCoordinator) -> [Case] {
        let combos = expandableCombos(from: coordinator)
        guard let first = combos.first else { return [] }
        // Only the filler words are checked for collisions: the round deliberately contains the
        // triggers themselves, and testing the assembled sentence against them blocked every one of
        // these rounds while it looked like it was passing.
        let filler = " and then the rest of the line "
        guard !blocked(by: coordinator, containing: filler) else { return [] }

        var rounds: [(String, String)] = [
            (first.trigger + filler, plainText(first) + filler),
        ]
        let connectives = [", then ", " and finally ", " done "]
        if combos.count > 1, !connectives.contains(where: { blocked(by: coordinator, containing: $0) }) {
            let second = combos[1]
            rounds.append((first.trigger + ", then " + second.trigger + " and finally "
                               + first.trigger + " done ",
                           plainText(first) + ", then " + plainText(second)
                               + " and finally " + plainText(first) + " done "))
        }
        return rounds.flatMap(paced)
    }

    private static func paced(_ round: (String, String)) -> [Case] {
        [Case(typed: round.0, expected: round.1, gap: 0.055),
         Case(typed: round.0, expected: round.1, gap: 0.02)]
    }

    /// A filler word that happens to be somebody's trigger would expand mid-round and make the expected
    /// string wrong for reasons that have nothing to do with the rewrite.
    private static func blocked(by coordinator: ExpansionCoordinator, containing text: String) -> Bool {
        coordinator.registeredTriggers.contains { text.contains($0) }
    }

    private static func expandableCombos(from coordinator: ExpansionCoordinator) -> [Combo] {
        coordinator.active.filter { !$0.parts.isEmpty }
    }

    private static func plainText(_ combo: Combo) -> String {
        combo.parts.reduce(into: "") { result, part in
            if case .text(let value) = part { result += value }
        }
    }

    private func runNext(_ index: Int, onUpdate: @escaping (String) -> Void) {
        guard index < cases.count else {
            isRunning = false
            summary = "\(passes)/\(total) clean, \(failures) wrong"
            append("=== \(stamp) \(summary) ===")
            onUpdate(summary)
            return
        }
        let testCase = cases[index]
        textView.window?.makeFirstResponder(textView)
        // The events this posts go wherever the session says they go. If our own window is not
        // frontmost, "wherever" is whatever the person is actually working in -- so the round waits for
        // the activation, and gives up rather than typing into their document.
        waitUntilOursIsFrontmost(deadline: Date().addingTimeInterval(2.0)) { ours in
            guard ours else {
                self.isRunning = false
                self.summary = "aborted — Unfold is not the frontmost app"
                self.append("\(self.stamp) ABORT front=\(self.frontBundle() ?? "?")")
                onUpdate(self.summary)
                return
            }
            // Clear the field the way a person does -- select everything and delete it -- not by
            // assigning to the text view. Assigning is invisible to the tap, so it leaves the app's own
            // model of the screen holding the previous round and every correction is computed from
            // text that is no longer there. That is precisely the failure this harness has to see.
            SyntheticKeys.selectAll()
            SyntheticKeys.backspace()
            SyntheticKeys.type(testCase.typed, gap: testCase.gap, repeats: testCase.repeats) {
                self.settle(deadline: Date().addingTimeInterval(Self.settleLimit), previous: nil,
                            agreements: 0) { observed in
                    self.record(testCase, observed: observed, index: index, onUpdate: onUpdate)
                }
            }
        }
    }

    private func frontBundle() -> String? { NSWorkspace.shared.frontmostApplication?.bundleIdentifier }

    private func waitUntilOursIsFrontmost(deadline: Date, _ then: @escaping (Bool) -> Void) {
        if frontBundle() == Bundle.main.bundleIdentifier || Date() >= deadline {
            then(frontBundle() == Bundle.main.bundleIdentifier)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.waitUntilOursIsFrontmost(deadline: deadline, then)
        }
    }

    /// Reads until the field stops moving. A fixed wait after the last keystroke is a guess about how
    /// fast the rewrite and the paste finish, and guessing short measures the previous round.
    private func settle(deadline: Date, previous: String?, agreements: Int,
                        completion: @escaping (String) -> Void) {
        let now = textView.string
        let same = now == previous
        if same, agreements + 1 >= Self.settleAgreement {
            completion(now)
            return
        }
        guard Date() < deadline else {
            completion(now)
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleInterval) {
            self.settle(deadline: deadline, previous: now,
                        agreements: same ? agreements + 1 : 1, completion: completion)
        }
    }

    private func record(_ testCase: Case, observed: String, index: Int,
                        onUpdate: @escaping (String) -> Void) {
        // Score only what the run actually controlled. If focus moved while the round was typing -- which
        // is what happens when a shell command activates another app mid-run -- the keystrokes went
        // wherever the session was aimed, and calling that a product failure would be a lie.
        guard frontBundle() == Bundle.main.bundleIdentifier else {
            isRunning = false
            summary = "stopped — focus moved to \(frontBundle() ?? "another app")"
            append("\(stamp) STOP round=\(index + 1) \(summary)")
            onUpdate(summary)
            return
        }
        total += 1
        if observed == testCase.expected {
            passes += 1
        } else {
            failures += 1
            append("\(stamp) FAIL round=\(index + 1)/\(cases.count) gap=\(String(format: "%.3f", testCase.gap))s "
                   + "typed=\(quote(testCase.typed)) expected=\(quote(testCase.expected)) observed=\(quote(observed))")
        }
        summary = "\(passes)/\(total) clean, \(failures) wrong"
        onUpdate(summary)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            self.runNext(index + 1, onUpdate: onUpdate)
        }
    }

    private func quote(_ text: String) -> String {
        "«" + text.replacingOccurrences(of: "\n", with: "⏎") + "»"
    }

    private var stamp: String { Date().formatted(date: .omitted, time: .standard) }

    private func append(_ line: String) {
        let path = "/tmp/unfold-selftest.log"
        guard let data = "\(line)\n".data(using: .utf8) else { return }
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: URL(fileURLWithPath: path))
        }
    }
}
