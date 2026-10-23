# Unfold -- macOS Text Expander: Design

Date: 2026-10-23
Status: approved in conversation, pending implementation plan
Name: **Unfold**. "Combo" stays the domain word for a trigger/replacement pair, so the `Combo`,
`CombosFile` types and `combos.json` filename keep their names.

## Goal

An open-source, GUI-first text expander for macOS. Type a short trigger, get replacement text.
The replacement may contain one or more placeholders that prompt the user for a value before the
text lands.

Beeftext occupies exactly this role on Windows and is MIT-licensed, but it has no macOS build --
the macOS version was dropped years ago. Unfold fills that gap rather than competing with it.

## Non-goals for v1

- Cloud sync, accounts, telemetry, team sharing.
- Scripted or conditional expansions.
- Per-application filters (Beeftext "Filters"). Deferred deliberately: they need frontmost-app
  detection plus a rule matcher, and they are not required for the trigger→text loop to be useful.
- A Windows build. See "Portability" for what v1 does to keep that door open.

## Platform decision

macOS first, native Swift, no cross-platform toolkit.

The decision was made against Tauri, Qt, Flutter, and a shared-Rust-core design. The reason those
lose for v1 is that **no framework shares the keystroke-capture layer** -- macOS requires a
`CGEventTap` or Accessibility API, Windows requires `WH_KEYBOARD_LL`. Cross-platform stacks
therefore share the UI and the engine while still carrying two native shims. For a
trigger→replacement engine, that shared UI is the only part worth sharing, and it is not worth
the webview runtime or the C++ iteration loop.

Build environment constraint: this machine has Command Line Tools only, no Xcode.app, so
`xcodebuild` is unavailable. The project is a SwiftPM package and the `.app` bundle is assembled
by `Scripts/make-app-bundle.sh`.

## Architecture

Six modules. The split is the design: the product's logic is pure and permission-free, and the OS
surface is two thin adapters.

| Module | Purity | Responsibility |
|---|---|---|
| `KeystrokeSource` | OS-specific | Owns the `CGEventTap`. Decodes keycodes to characters with `UCKeyTranslate` against the current layout. Publishes a character stream. Can be **disabled at will**. |
| `Matcher` | pure | Character buffer + combo table → `exact` / `potential` / `none`. No OS calls. |
| `Template` | pure | Replacement text ⇄ ordered `[Part]` of literal and placeholder segments. |
| `Injector` | OS-specific | Writes into the frontmost app: clipboard-swap plus `Cmd+V`, or synthesized keystrokes. |
| `Store` | pure | `CombosFile` ⇄ JSON on disk, atomic write. |
| `AppShell` | UI | `NSStatusItem` menu, combo management window, the placeholder prompt panel. |

`Matcher`, `Template`, and `Store` live in the `UnfoldEngine` target and are unit-testable on a
machine that has never granted an accessibility permission. That boundary is enforced by the
build graph, not by convention.

### Portability, the cheap way

Windows stays possible because `Template`, `Matcher`, and the on-disk JSON carry no Apple types.
A later Windows build swaps `KeystrokeSource` and `Injector` for hook- and `SendInput`-based
implementations and keeps the engine and the user's snippet files verbatim. The cost of keeping
that option open today is zero, because it is a consequence of the module split rather than extra
work.

## App form

A menu-bar agent: `LSUIElement`, no Dock icon, `NSStatusItem` menu (Manage / New combo / Pause /
Quit) and one window holding the combo list and editor. This is Beeftext's shape translated to
what a Mac expects from a resident utility.

## Matching

Amended 2026-10-23 after writing the implementation plan. The original rule -- "fire immediately,
no trailing delimiter required" -- is broken for the spec's own example: with `add`→`address` defined
and no `address` trigger, an immediate fire turns `added` into `addressed`. Expansion therefore
requires a delimiter.

A trigger **word character** is a Unicode letter or digit; anything else -- space, punctuation,
Return, Tab, emoji -- is a **delimiter**. The state machine consumes one decoded character at a time:

1. Word character, and `buffer + character` is a prefix of some enabled trigger, and the character
   preceding `buffer` was a boundary → swallow the key and extend `buffer`.
2. Word character that cannot extend `buffer`, and `buffer` was empty → pass the key through.
3. Word character that cannot extend a non-empty `buffer` → release `buffer` verbatim, then re-decide
   that same character from an empty buffer. Typing `added` releases `add` and emits all six
   characters, so nothing fires.
4. Delimiter arriving while `buffer` equals an enabled trigger → **expand**, then pass the delimiter
   through so the typed space or punctuation still lands.
5. Delimiter arriving while `buffer` holds a partial, non-matching prefix → release `buffer` verbatim,
   then pass the delimiter.
6. A match may only begin after a boundary: absent, delimiter, or a completed expansion. `padding`
   never fires `add`, because `a` follows the word character `p`.
7. If the user stops typing, `buffer` holds swallowed characters that have not been emitted. The
   adapter owns an idle timer and calls `releasePending()` to emit them verbatim, so a partial prefix
   can never be silently lost.

Rule 4 means a trigger at the very end of a line expands on the next keystroke rather than on its
own. That is the accepted cost of not firing inside words, and it is how Beeftext and espanso behave.

Expansion means the tap returns `nil` for the trigger's events, so the trigger never renders in the
target document and no synthetic backspaces are ever sent. Released characters are re-posted as
new key events by the adapter, which is why `release` and `expand` are distinct actions in the engine's
output.

## Insertion and the placeholder prompt

On fire:

1. Disable `KeystrokeSource`. This is not optional bookkeeping -- an active tap swallows keystrokes
   aimed at the app's own prompt field, so the user cannot type into the dialog.
2. Build the prompt panel from the combo's `placeholder` segments, one field each, top to bottom.
   Each field is a combobox: it offers the segment's predefined `options` and accepts free text.
3. On confirm, compose literal + resolved values. On Escape or window close, cancel and re-emit
   the original trigger characters verbatim, leaving the target document byte-identical.
4. `Injector` saves the pasteboard, writes the composed text, posts `Cmd+V`, restores the
   pasteboard, then re-enables `KeystrokeSource`.

Paste is the default because it is atomic and survives emoji, accented characters, and any
keyboard layout. `insertion: "keys"` is the per-combo escape hatch for the handful of apps that
reject synthetic paste.

## Storage

`~/Library/Application Support/io.github.raccoonpie314.unfold/combos.json`, written atomically via
a temporary file and rename. No SQLite, so the file stays diffable, syncable by the user's own
cloud folder, and importable from Beeftext JSON.

`Part` uses the tagged-union shape that `Codable` synthesizes for an enum with associated values:

```json
{
  "formatVersion": 1,
  "combos": [
    {
      "id": "6C9C0A1E-2D2B-4E37-9A6B-5C1F0D8E3A11",
      "trigger": "addr",
      "label": "Home address",
      "enabled": true,
      "parts": [
        { "text": "I love " },
        { "placeholder": { "id": "city", "options": ["Shanghai", "Tokyo"] } },
        { "text": " restaurant" }
      ],
      "insertion": "paste"
    }
  ]
}
```

A `Placeholder` carries only `id` and `options`. Amended 2026-10-23: an earlier draft also had
`prompt` and `defaultValue`, but the plain-text form below cannot express them, so hand-editing a
snippet would have silently destroyed those fields. The prompt panel labels each field by its `id`.

The editor's plain-text mode round-trips with `parts`:

- `{{name}}` -- a placeholder with no preset options.
- `{{name:Shanghai,Tokyo}}` -- a placeholder whose options are comma-separated. An option cannot
  itself contain a comma; that is a v1 limitation, reported rather than silently mangled.
- `\{{` -- an escaped literal `{{`.
- Placeholder `id`s must be unique within one combo, contain no braces or colon, and be non-empty.

A trigger must be non-empty, contain no whitespace, and end in a word character -- otherwise the
loader rejects it with a stated reason. Triggers ending in punctuation are the "partial matching"
case Beeftext handles per-combo, and they are out of scope for v1.

## Failure modes

- **Secure Input.** Any focused password field, or Terminal's secure keyboard entry, makes the
  tap receive nothing at all. This is a macOS protection and cannot be worked around. The app
  watches for tap-disabled callbacks and surfaces a status-item warning instead of silently
  appearing broken.
- **Permission denied.** Missing Accessibility/Input Monitoring is detected with
  `AXIsProcessTrustedWithOptions` on every launch and offered as a deep link to the correct
  System Settings pane.
- **Tap torn down by the system.** The tap is re-created on timeout or disable, with a bounded
  retry count so a hostile environment cannot spawn taps in a loop.
- **Apps that ignore synthetic events.** Per-combo `insertion: "keys"` override.
- **Corrupt or future-version JSON.** Load refuses, keeps the file, and reports which combo failed
  rather than discarding the user's library.

## Testing

**Blocked on a prerequisite.** This machine has Command Line Tools only. Apple distributes both
XCTest and swift-testing exclusively inside Xcode.app, so `swift test` cannot build any test
target here -- verified: no `XCTest.framework`, no `Testing` module, no `/Applications/Xcode*.app`.
Installing Xcode and running `sudo xcode-select -s /Applications/Xcode.app` is a hard requirement
before the test plan below is executable. `Tests/UnfoldEngineTests/CombosFileTests.swift` is
written and correct; it cannot compile until then.

- `Matcher`: exhaustive table-driven cases for all seven rules above, plus multi-trigger prefix
  collisions and non-Latin layouts. Highest-value test surface in the project; needs no
  permissions.
- `Template`: parse/serialize round-trips, escapes, adjacent placeholders, empty option lists.
- `Store`: round-trip, atomic write, corrupt file, `formatVersion` too new.
- `KeystrokeSource` and `Injector`: too thin to unit-test meaningfully. A manual checklist against
  TextEdit, Safari, Mail, and Terminal, including one password field to confirm the Secure Input
  warning.

## Distribution

GitHub, MIT license. Developer ID signing, `notarytool` submission, and staple on every release --
required for a free app too, since Gatekeeper blocks unsigned downloads regardless of price.
Sparkle for updates, which will add entitlements. The first-run flow requests the accessibility
permission before asking for any trust.

## Open questions

1. Does a combobox remember values the user typed past its `options`, and surface them as
   suggestions? Useful, but it is a history feature and not in v1.
2. Beeftext import in v1, or as a fast follow?
3. What distinguishes Unfold from Typefire and Snippety, which already advertise a free macOS text
   expander? The defensible answer is the GUI-first combo table plus MIT licensing, but it needs to
   be stated in the project description rather than assumed.
