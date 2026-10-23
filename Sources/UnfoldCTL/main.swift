import Foundation
import UnfoldEngine

func expandTilde(_ path: String) -> String {
    if path.hasPrefix("~/") {
        return NSHomeDirectory() + String(path.dropFirst(1))
    }
    return path
}

/// The combos path, plus whether the caller named one. `--combos <path>` that does not exist is a
/// typo or a moved file, not a first run: the tool has to fail rather than report an empty library
/// and exit 0 on a CI gate. No flag at all still means the default location on a first run.
func combosURL(from arguments: [String]) -> (url: URL, explicitlyRequested: Bool) {
    if let flag = arguments.firstIndex(of: "--combos"), flag + 1 < arguments.count {
        return (URL(fileURLWithPath: expandTilde(arguments[flag + 1])), true)
    }
    return (Store.defaultURL(), false)
}

func describe(_ action: MatchAction, for character: Character) -> String {
    switch action {
    case .emit(let emitted):
        return "  emit    `\(emitted)`"
    case .swallow:
        return "  swallow `\(character)`"
    case .expand(let combo):
        return "  EXPAND  `\(combo.trigger)` -> \(Template.serialize(combo.parts))"
    }
}

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data("unfoldctl: \(message)\n".utf8))
    exit(code)
}

guard CommandLine.arguments.count >= 3 else {
    fail("usage: unfoldctl <check|match> <argument> [--combos <path>]", code: 64)
}

let command = CommandLine.arguments[1]
let argument = CommandLine.arguments[2]
let combos = combosURL(from: CommandLine.arguments)
let store = Store(url: combos.url)

if combos.explicitlyRequested, !FileManager.default.fileExists(atPath: store.url.path) {
    fail("no such file: \(store.url.path)", code: 66)
}

let file: CombosFile
do {
    file = try store.load()
} catch {
    fail("cannot read \(store.url.path): \(error)", code: 66)
}

let index = TriggerIndex(combos: file.combos)

switch command {
case "check":
    for rejection in index.rejections {
        print("rejected `\(rejection.combo.trigger)`: \(rejection.problem)")
    }
    print("\(index.accepted.count) trigger(s) active, \(index.rejections.count) rejected")
    if !index.rejections.isEmpty { exit(1) }

case "match":
    var matcher = Matcher(index: index)
    for character in argument {
        for action in matcher.feed(character) {
            print(describe(action, for: character))
        }
    }
    for action in matcher.releasePending() {
        print(describe(action, for: " "))
    }
    print("buffer after input: `\(matcher.buffer)`")

default:
    fail("unknown command `\(command)`; expected check or match", code: 64)
}
