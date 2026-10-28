# Unfold Liquid Glass, Appearance and Motion Design

**Date:** 2026-10-29
**Branch:** `task/unfold-keyboard-layer`
**Predecessors:** `2026-10-23-macos-text-expander-design.md` (product spec),
`plans/2026-10-23-unfold-engine.md` (Plan 1), `plans/2026-10-23-unfold-keyboard-layer.md` (Plan 2).
**Scope:** the AppKit shell, the appearance contract, the motion contract, and the placeholder prompt
panel Plan 2 deferred as R-P2-2.

## Goal

Make Unfold look and move like a macOS 26 application: real Liquid Glass in the layer Apple puts it
in, correct rendering in both appearances with a user-visible override, and native-feeling geometric
motion for every transition the system cannot animate by itself. While doing that, ship the missing
placeholder prompt so combos containing `{{name}}` actually fire.

## Non-goals

- No SwiftUI, no `NSHostingView`. Decided in the tradeoff round below.
- No third-party dependencies. The product spec forbids them and this pass does not need one.
- No hand-drawn glass, blur or vibrancy anywhere. `references/hig/liquid-glass.md` treats an
  imitated glass surface as worse than none, and the app already runs on a system that provides it.
- No app icon, no brand color, no onboarding, no per-application filters.
- No behavior change to matching, the event tap, or injection beyond the two rules in
  "The prompt path" and "A combo with nothing to insert".

## Decisions taken

| Question | Decision | Why |
|---|---|---|
| UI stack | Stay AppKit; retrofit. | The working editor (live commit with caret preservation) and the keyboard harness get re-hosted for nothing under SwiftUI. On macOS 26+ the stock AppKit toolbar, sidebar, controls, sheets and menus already render the real material; the highest-fidelity path is to stop overriding it. |
| Motion architecture | Motion as data (`MotionPlan`, AppKit-free) + one driver. | Matches the `MenuStatus` precedent: the decision is a testable value, the OS call is thin. Keeps timings in one place and makes "is this transition geometry or a fade?" an assertion. |
| Platform floor | `platforms: [.macOS(.v26)]`, `LSMinimumSystemVersion` 26.0. | Glass does not exist before 26; the fallback path is unmaintainable and untestable on this machine, and it produced a look that is not the product's identity. Every macOS 26 *fallback* branch in the shell is deleted. **One guard survives by necessity:** `effectIsInteractive` is `API_AVAILABLE(macos(27.0))` while the floor is 26, so it stays behind `if #available(macOS 27.0, *)` and below 27 the glass is static -- its documented default. Raising the floor to 27 would delete that guard, at the cost of excluding every Tahoe Mac; the floor stays 26. |
| Appearance | Follow the system **and** offer an explicit override in the toolbar, defaulting to "Match System". | See "Appearance" for the HIG conflict and how it is mitigated. |
| Prompt presentation | A floating key `NSPanel`, not a sheet. | The app is `LSUIElement`/`.accessory`. A sheet needs a parent window, and the window the text belongs to is another app's. |
| Reduce Motion | No branch. Motion stays unconditional. | The user's standing instruction: a reduced-motion fallback is what previously made animation invisible to them. Recorded as a deliberate exception to the HIG checklist item. |

## Platform facts this design rests on

Verified against `/Applications/Xcode.app/.../MacOSX27.0.sdk/System/Library/Frameworks/AppKit.framework/Headers`
on 2026-10-29, not from memory:

- `NSGlassEffectView` is `API_AVAILABLE(macos(26.0))`; `effectIsInteractive` is `macos(27.0)`; the
  header states the default is `NO` and that it "should be enabled for glass that is used as the
  background for interactive controls". Enabling it is what supplies Apple's own press/lens response.
- `NSGlassEffectContainerView` (26.0) merges nearby descendant glass views and batches them for
  performance. Its `spacing` controls the proximity at which merging starts; the documented default
  of zero batches without distorting unrelated views.
- `NSAnimationEffect` (`NSGraphics.h:239`) is `API_DEPRECATED(..., macos(10.3, 14.0))`. The old
  `NSTableView` row-insert effect is a dead end, so row motion is written by hand.
- There is no `NSAnimationTimingFunction` in AppKit. Curves come from `CAMediaTimingFunction` and
  springs from `CASpringAnimation` (QuartzCore). AppKit's own hooks are `NSAnimationContext`, the
  `.animator` proxy, `NSAnimatablePropertyContainer`, and `NSAnimationTriggerOrderIn`/`OrderOut`.
- `NSScrollEdgeEffectStyle` (`NSScrollEdgeEffect.h:16`) is `API_AVAILABLE(macos(26.1))`, so explicit
  edge styles need a `#available(macOS 26.1)` guard. The behavior used here is the automatic one, so
  the shell keeps no availability branches at all.
- `swift build` cannot compile an asset catalog (`actool` is not run for SwiftPM resources), so a
  Color Set is not available. Every color must be a semantic `NSColor` or an
  `NSColor(name:dynamicProvider:)` that resolves per appearance.
- `platforms: [.macOS(.v26)]` does **not** compile under the current
  `// swift-tools-version: 6.0` -- `v26` was introduced in PackageDescription 6.2. Probing
  `swift build` on 2026-10-29: tools-version 6.0 rejects it with `'v26' is unavailable`, and only
  `// swift-tools-version: 6.2` accepts it. The floor bump therefore carries a manifest-version bump,
  which is verified below by `vtool` rather than assumed.
- `NSAppearance(named:)` is failable, and `NSAppearanceName` is spelled `NSAppearance.Name` in Swift.
- Semantic label colors are **translucent**: `secondaryLabelColor` resolves to white/black with an
  alpha, so a contrast instrument that ignores alpha reports it as 21:1 -- identical to `labelColor`.
  Measured with the alpha composited over the backing on 2026-10-29:

  | Pair | Aqua | Dark Aqua |
  |---|---|---|
  | `labelColor` / `windowBackgroundColor` | 14.94:1 | 12.23:1 |
  | `secondaryLabelColor` / `windowBackgroundColor` | **3.95:1** | 5.89:1 |
  | `tertiaryLabelColor` / `windowBackgroundColor` | 1.88:1 | 2.26:1 |
  | `systemRed` / `windowBackgroundColor` | **3.57:1** | 4.86:1 |
  | `systemGreen` / `windowBackgroundColor` | **2.22:1** | 8.25:1 |
  | `systemOrange` / `windowBackgroundColor` | **2.31:1** | 7.47:1 |

  So the app is *more* legible in Dark than in Light, and Light mode is where the floor is missed.
  `.secondaryLabelColor` at 11 pt is the shell's caption color today -- captions, the hint line, the
  diagnostics block, the path label and the row preview line -- and 3.95:1 is under the 4.5:1 floor
  this design commits to. `systemGreen` and `systemOrange` as symbols are under the 3:1 graphic floor
  in Light too. See "Contrast conformance" for what changes as a result.

  This corrects the earlier draft's claim that secondary label measures "about 4.6:1".
- `UIDesignRequiresCompatibility` is ignored when building for macOS 27 or later
  (`liquid-glass.md` §SwiftUI, UIKit, and AppKit). It stays out of `Resources/Info.plist`.

## Architecture

Ten units. `MotionPlan` deliberately imports Foundation only, exactly like `MenuStatus`, so the
motion table is testable in `Tests/UnfoldTests` without touching a view.

| Unit | One job | Depends on |
|---|---|---|
| `Sources/Unfold/Design/MotionPlan.swift` | The transition table as values: name, duration, curve, geometry kind. | Foundation |
| `Sources/Unfold/Design/Motion.swift` | Translate one `MotionPlan` entry into Core Animation on layer-backed views; provide the FLIP helper and the retarget-and-stop rules. | MotionPlan, QuartzCore, AppKit |
| `Sources/Unfold/Design/Theme.swift` | Corner radii, spacing scale, type scale, the appearance-preference enum and its persistence. | AppKit |
| `Sources/Unfold/Design/Glass.swift` | `wrap(_:cornerRadius:padding:interactive:)` and a container for grouped controls. The `tint:` parameter is deleted: no call site uses it, and color on glass is a budget spent only on status symbols. | `NSGlassEffectView` |
| `Sources/Unfold/AppShell/SidebarViewController.swift` | Source list, filter, selection landing, row insert/remove motion, `ComboRowView`. | Theme, Motion |
| `Sources/Unfold/AppShell/EditorViewController.swift` | The editor form, the commit-as-you-type paths, the hint line. Moved from `MainWindowController` verbatim. | Theme, Motion |
| `Sources/Unfold/AppShell/DiagnosticsViewController.swift` | The counters block, the glass test-button cluster, the test result line. | Theme, Glass |
| `Sources/Unfold/AppShell/MainWindowController.swift` | Window, toolbar, split assembly, appearance toggle, wiring between panes. Target: ~150 lines. | the four panes |
| `Sources/Unfold/AppShell/PromptPanelController.swift` | The `NSPanel` that collects placeholder values and hands them back. | `Prompt`, Motion, Theme |
| `Sources/UnfoldEngine/Prompt.swift` | Pure: `Combo.parts` → ordered `PromptField`s; submitted values → composed `[Part]`; refusal rules. In the engine, not `UnfoldMac`, because composing a replacement is the engine's job and this way `UnfoldCTL` and `Tests/UnfoldEngineTests` reach it without a GUI target. | Foundation, `Template` |

Dependency direction is one-way: `AppShell` → `Design`, `AppShell` → `UnfoldMac` → `UnfoldEngine`.
No pane reaches into another pane; the controller owns the cross-pane messages
(`selectionChanged`, `commit`, `reloadRequested`) as closures it installs, which is how the panes
become testable in isolation and how the 963-line file stops existing.

`UnfoldEngine` continues to import Foundation only, enforced by the build graph.

## Glass placement

Per `liquid-glass.md`, glass is the **functional layer** only, standard components pick it up on
their own, and the count of custom glass surfaces is itself a defect. The two-layer audit:

| Surface | Today | After |
|---|---|---|
| Unified toolbar, sidebar, window material | System-drawn over `.underWindowBackground`, `isOpaque = false` | Unchanged. This is the glass; nothing is added on top of it. |
| Toolbar status pill | `Glass.wrap(stack, cornerRadius: 13, padding: 6)` | Inside `NSGlassEffectContainerView`, `effectIsInteractive = true`. |
| Diagnostics button cluster | `Glass.wrap(column, cornerRadius: 10, padding: 8)` | Same container, so the buttons merge into one slab instead of eight separate panes. |
| Combo list rows, editor fields, counters | Ordinary content on ordinary materials | Unchanged -- and stays unchanged. Glass behind list rows would put the material in the content layer and make contrast unguaranteeable. |
| Sidebar scroll edge | `sidebarScroll.automaticallyAdjustsContentInsets = false` ([MainWindowController.swift:141](../../../Sources/Unfold/AppShell/MainWindowController.swift)) | Restored to `true`. Suppressing it removed the system scroll-edge effect, which is exactly the thing the HIG prescribes in place of a solid background under a bar. The magnifier/placeholder collision that motivated it is fixed with the search field's own content inset, not by killing the edge effect. |
| Search field, push buttons, pop-up, checkbox | Stock controls | Stock controls. On 26+ these already are the glass treatment; re-skinning them is how the earlier attempts in this repo lost their insets and their selection colors. |
| Prompt panel | does not exist | Ordinary materials for the fields, one glass container for the action bar. |

Color budget: the app has one place that spends color -- the status indicator -- and it spends it on the
symbol, never on the glass and never on the pill's label. `tintColor` is not set on any surface. Because
`systemGreen` and `systemOrange` measure 2.22:1 and 2.31:1 over a light window background, only the
broken states are coloured red; *red means not working, monochrome means working*, and the label is
`labelColor` in every state so the pill reads over a bright or a dark desktop alike.

## Appearance

**Default: match the system, including Auto (time-of-day) switching.** `NSApp.appearance` is left
`nil` unless the user chooses otherwise, so semantic colors, materials, glass and the sheet all track
the system with no code.

**The override.** The HIG says *"Avoid offering an app-specific appearance setting"*
(`dark-mode.md`), and the user asked for a toggle anyway. It is built so the cost the HIG names is
small:

- A toolbar item (`unfold.appearance`) whose symbol is `circle.lefthalf.filled`, opening a three-item
  `NSMenu`: **Match System**, **Light**, **Dark**. A menu rather than a two-state button because the
  system default must remain reachable from the same control -- the failure mode of an in-app switch
  is that a person gets stuck in it.
- The current choice is marked with a checkmark, and the item's `toolTip` names it.
- The menu is a system menu: it picks up the current appearance and its own open animation for free.
- Persisted in `UserDefaults` under `unfold.appearancePreference` (`system` / `light` / `dark`),
  read once at startup in `main.swift` before any window exists, so the first frame is already right.
- Applied by setting `NSApp.appearance` to `NSAppearance(named: .aqua)` / `.darkAqua`, or back to
  `nil` for Match System. App-level rather than window-level, so the prompt panel, alerts and sheets
  match the main window instead of disagreeing with it.
- **Honest limit, stated rather than discovered later:** the `NSStatusItem` menu is drawn in the
  system menu bar and follows the *system* appearance, not this override. An app cannot restyle the
  menu bar. The override therefore changes Unfold's windows, panels and alerts only.

**Contrast is a test, not an opinion.** `Tests/UnfoldTests/ContrastTests.swift` resolves every
(text color, backing color) pair under both `.aqua` and `.darkAqua`, **composites the label's alpha
over the backing** -- which the measurement above proved is not optional -- and asserts the floor the
HIG sets: ≥4.5:1 for body and caption text up to 17 pt, ≥3:1 for symbols and large text. The pairs
are enumerated from one table the views read from, so a new label has to be added to the table to
render at all.

**Contrast conformance, given the measured numbers.** Light mode misses the floor in three places, so
this pass changes what carries the hierarchy:

- Meaningful text moves from `.secondaryLabelColor` to `.labelColor`: the three form captions, the
  hint line, the diagnostics block, the test-result line, the path label, the sidebar row's preview
  line, and the toolbar status pill's label. Hierarchy is then carried by **size and weight**
  (11 pt caption against 13 pt body, medium against regular), which is what `typography.md` and
  `color.md` both prefer over a color step that fails legibility. Disabled-row triggers keep
  `.secondaryLabelColor`, because "disabled" is the one case where reduced contrast *is* the message,
  and the slash symbol plus the tooltip say it without color.
- The empty/save-failure hint moves to `.labelColor` text with a `exclamationmark.triangle.fill`
  symbol carrying the red. The red becomes emphasis on a glyph rather than the sole carrier of an
  11 pt sentence.
- Status color is spent on the **symbol only**, and only where it can be seen: red for the five broken
  states, `labelColor` for `listening` and `paused`. Writing the contrast table found this -- green at
  2.22:1 and orange at 2.31:1 fail even the 3:1 graphic floor in Light, so a coloured "Ready" glyph would
  have been a faint smudge on the appearance most Mac users still have. Colouring it only in Dark would
  give the app two identities, so monochrome is chosen in both. `MenuStatus` already decides symbol and
  text together, and the same table now feeds both surfaces.
- No custom color is invented. The alternative -- a dynamic `systemGreen` darkened until it clears 3:1
  -- would put a hand-tuned RGB in the shell, and `dark-mode.md` is explicit that hardcoded values are
  the thing to avoid. If that trade is ever wanted, it is a separate decision with its own numbers.

Two pairs a unit test cannot decide, so they are measured on pixels instead:
- **Label on glass.** The pill samples whatever is behind the window. Checked with screenshots of the
  installed app over a deliberately light and a deliberately dark desktop picture.
- **Increase Contrast / Reduce Transparency.** Both are handled by the real materials, which is the
  argument for keeping the material system-supplied; each gets one screenshot pass rather than code.

## Motion

`MotionPlan` is a `[Transition]` where each `Transition` carries `id`, `duration`, a
`Curve` (`.spring(damping:response:)` or `.easeOut(controlPoints:)`) and a `Kind`
(`.scale(from:to:)`, `.translate`, `.morph`, `.positionCrossfade`). `Motion.run(_:)` is the only code
that touches Core Animation.

| id | Trigger | Geometry | Duration | Curve |
|---|---|---|---|---|
| `rowInsert` | `+`, or a filter that reveals a row | FLIP: the new row unfolds out of a zero-height gap at the baseline above it; neighbours reflow | 260ms | spring, damping 0.85, ~5% overshoot |
| `rowRemove` | confirmed delete | the row collapses onto its successor and the gap closes | 220ms | easeOut |
| `selectionMorph` | sidebar selection change | the Trigger caption and field position-crossfade from the row's rect to the form's rect (shared element) | 200ms | easeOut |
| `paneReveal` | stethoscope → Diagnostics | the pane's content grows from the divider edge; the divider itself moves through `NSSplitViewController`'s own animation | 280ms | spring |
| `statusMorph` | tap state change | SF Symbol replacement animation plus the pill's width springing to fit the new label | 240ms | easeOut |
| `promptPresent` | a placeholder combo fires | the panel scales out of the caret's screen rect | 220ms | spring |
| `promptDismiss` | confirm or cancel | reverse into the caret rect | 180ms | easeOut |

Rules, all of them derived from a correction the user already made:

- **Geometry carries the motion.** Opacity is used only as an anti-flash ramp inside the first ~20%
  of a timeline. `MotionPlanTests` asserts that no transition's `Kind` is opacity-only.
- **No front-loaded curves on short transitions.** `cubic-bezier(0.33, 1, 0.68, 1)` at 200-300ms,
  not `(0.22, 1, 0.36, 1)`: the earlier curve had spent 76% of its change by 45ms and read as
  nothing. The test asserts every duration lands in 150-320ms.
- **Motion is interruptible.** Setting a new target on a property mid-flight retargets from the
  current presentation value; a zero-duration context stops it. Fast sidebar clicks must never queue
  a backlog of animations. This is `liquid-glass.md` checklist item 5's "let people cancel motion".
- **Nothing animates more than once per interaction.** Button presses, pop-up menus, the focus ring,
  the sheet slide and the sidebar toggle are left to the system. Re-animating a system-animated
  control is how the earlier glass attempts in this repo ended up fighting their own insets.
- **No Reduce Motion branch**, per the decision table. If that is revisited, the guard shortens
  geometry and keeps the morph; it does not substitute a fade.

## The prompt path

Closes R-P2-2. The product spec's "Insertion and the placeholder prompt" defines the contract; two
steps of it predate the render-then-rewrite amendment and are corrected here.

**Amendment 1 -- no re-emission.** The spec's step 3 says to "re-emit the original trigger characters
verbatim" on cancel. That belongs to the deleted hold-and-release ledger. Under the current model the
trigger is *already in the document*, because typing always renders:

- on **confirm**: `DocumentTriggerEraser` reads the focused field, verifies that the characters before
  the caret are exactly this trigger, selects that range and pastes the composed text onto it;
- on **cancel or close**: do nothing. The document reads the trigger verbatim already, so the
  byte-identical outcome step 3 asked for arrives for free, with no event replay.

**Amendment 2 -- the panel is the key window.** Sequence, and who decides each step:

1. The matched combo is registered, so `Matcher` returns `MatchAction.expand(combo)` for it. The
   engine's output vocabulary does not change. What changes is the adapter's: `EventRouter` answers
   `RoutingDecision.promptThenPass(Combo, [Int])` -- the same shape as the existing
   `expandThenPass(Combo, [Int])` -- when the matched combo has a placeholder segment, and
   `expandThenPass` when it is all literal. `RoutingDecision` is the only place the two diverge.
2. `KeystrokeSource` is disabled. Not bookkeeping: an active tap eats keystrokes aimed at Unfold's own
   fields, which is the reason the panel could not be typed into.
3. `Prompt.fields(from: combo.parts)` produces one field per placeholder segment, in document
   order, labelled by its `id`, seeded with the segment's `options` and accepting free text.
4. `PromptPanelController` captures the frontmost app and the caret's screen rect, then makes the
   panel key and focuses the first field. `promptPresent` runs.
5. On ⌘↩ (default button) or Cancel/Escape: `Prompt.compose(parts:values:)` yields the resolved
   `[Part]`, or nil for cancel.
6. The captured app is reactivated. If it is gone, or the document text before the caret is no longer
   this trigger, the coordinator **stands down**: the source is re-enabled and the typed trigger is
   left exactly as it is. Overwriting text the user never typed stays the worse outcome.
7. `Injector` runs the existing clipboard-swap plus `Cmd+V` (or `.keys` for that combo), then
   `KeystrokeSource` is re-enabled. The spec's order -- inject, then re-enable -- is kept.

**Registration changes both ways.** `ExpansionCoordinator.library(for:)`
([ExpansionCoordinator.swift:120](../../../Sources/UnfoldMac/Platform/ExpansionCoordinator.swift))
currently registers only combos whose parts are all `.text`, and counts the rest as `awaitingPrompt`.
That filter is replaced by two rules in the same function:

- A combo with a placeholder segment **is** registered now -- that is the whole point of the prompt --
  and routes to `promptThenPass`.
- A combo with `parts.isEmpty` is **not** registered. `addCombo` already creates `parts: []` (the
  uncommitted 2026-10-27 fix), so today an unfilled combo is live in the index with nothing to
  insert, and typing `new` + space deletes those characters until it is renamed or filled. Refusing
  to register it is what makes a half-built combo harmless.

`inactivePlaceholderCount` is therefore no longer a count of "waiting for UI that does not exist". It
becomes `emptyComboCount`, and the two places that print it change together:
`MainWindowController.swift:763` ("N need the prompt UI" → "M empty, nothing to insert") and
`StatusItemController.swift:146`. Keeping the counter rather than deleting it is deliberate -- it is
the sentinel that shows a combo the user can see is not reachable from the keyboard.

This closes the last of the two open items from the 2026-10-27 live verification. The other,
post-delete selection, is fixed in the next section.

**Selection after delete.** `reloadRows` currently selects row 1 when the selected combo is gone, so
two fast deletes with the alert unread destroy the wrong combo. The sidebar keeps the deleted row's
index and selects `min(index, count-1)` -- the neighbour -- which is also what `rowRemove`'s collapse
target needs to know. Both are the same change.

Panel layout: captions left of fields, `⌘↩` confirm, Escape cancel, Tab order top-to-bottom, the
action bar in one glass container. The panel is not resizable, is `.floating` level so it survives
the app being an accessory, and closes on Escape regardless of focus.

## Menu bar and alerts

The `NSStatusItem` menu keeps its system-drawn appearance (see the honest limit under Appearance).
What changes is the vocabulary: the menu's status line and the window's status pill use the same
symbol name and the same `NSColor` for a given `MenuStatus`, produced from one table so they cannot
drift apart. The delete confirmation keeps its system sheet slide, and its `informativeText` names
the file it writes, which it already does.

## Error handling

| Failure | Outcome |
|---|---|
| Prompt open, target app quits or hides | Stand down. Trigger stays typed, source re-enabled, Diagnostics records `prompt cancelled: target gone`. |
| Prompt open, caret text no longer the trigger | Stand down. No overwrite. |
| Placeholder left blank | Allowed -- an empty value composes to nothing. The field is not validated, because a person may legitimately want `{{suffix}}` to resolve to "". |
| Panel fails to become key (Secure Input in the target app) | The trigger stays typed, the tap is off, and the status pill says so. The prompt is not retried silently. |
| Store refuses a write | Existing behaviour is kept and covered by the current tests: the hint turns red, the added or deleted combo rolls back, and the list reloads from the rolled-back file. |
| Appearance preference unreadable or unknown value | Treated as `system`, which is the HIG's own default. |

## Testing

- `MotionPlanTests` (`Tests/UnfoldTests`) -- Foundation-only: seven ids present, every `Kind`
  geometric, durations in 150-320ms, no curve steeper than the approved control points, springs
  positive. This is where "native animation for every component" becomes a checkable claim.
- `ContrastTests` (`Tests/UnfoldTests`) -- the color-pair table resolved under `.aqua` and
  `.darkAqua`; ≥4.5:1 text, ≥3:1 symbols.
- `PromptTests` (`Tests/UnfoldEngineTests`) -- one field per segment in order; options carried;
  free text accepted; compose with all values, with a blank value, and with none; cancel yields nil;
  the empty-parts refusal.
- `EventRouterTests` -- a placeholder combo yields `.promptThenPass` and an all-literal combo still
  yields `.expandThenPass`, with the same `[Int]` typed-ahead count in both. An empty combo is a
  registration question, not a routing one, so it is covered in `ExpansionCoordinatorTests`: an empty
  combo never appears in the index at all.
- Store and rollback tests from the 2026-10-27 round stay green, plus a test that post-delete
  selection lands on the neighbour rather than row 1.
- The existing suite must pass unchanged: **186 test methods, 0 failures** (71 `UnfoldEngineTests`,
  106 `UnfoldMacTests`, 9 `UnfoldTests`), measured on 2026-10-29 rather than recalled. `swift test`
  prints an `Executed N tests` line per target, so grepping for one number reports green even when a
  different target failed -- use `swift test --list-tests | grep -c /` for the count and a
  `Test Suite 'All tests' failed|with [1-9][0-9]* failures` grep for the verdict. `UnfoldEngine` stays
  Foundation-only: `grep -rn "^import " Sources/UnfoldEngine/ | grep -v Foundation` must stay empty.
- The floor bump is verified on the Mach-O, not on a log line:
  `vtool -show-build .build/debug/Unfold` reports `minos 14.0` today and must report `minos 26.0`
  afterwards. `swift test`'s `Target Platform: arm64e-apple-macos14.0` line is **not** a valid signal --
  measured 2026-10-29, it still printed `macos14.0` after the floor was raised, because it names the
  testing library's own target rather than this package's.

**Live verification**, on the bundle from `Scripts/make-app-bundle.sh` driven through Accessibility by
PID, because both the tap and the materials are the parts a unit test cannot reach:

1. **`MotionProbe`, measured in-process.** A Diagnostics button runs each transition on a real view and
   logs the layer's *presentation* bounds and transform offset at eight timestamps to the launch log, so
   motion is reported as numbers -- a transition that logs one size eight times is not animating. Chosen
   over a window-capturing shell script because it samples the animation's own intermediate state rather
   than a screenshot that may land between frames, and because it does not have to raise a window to read
   one. `promptPresent` and `promptDismiss` are excluded until Plan 4 builds the panel they morph from.
2. Screenshots of every surface in both appearances, produced by flipping the *system* setting and
   then by the toolbar toggle, to prove both paths land on the same pixels.
3. One prompt round in a real Chromium address bar and one in TextEdit -- the two targets that have
   previously disagreed about backspaces.
4. The self-test, stress test and idle-timeout buttons still pass after the pane split, since they
   hold references to `tryView`, which moves into the editor pane.

## Plan split

This is one spec and two implementation plans, because they touch different halves of the build graph
and each has its own verification surface:

- **Plan 3 -- Glass, appearance, motion.** `Sources/Unfold` only. The floor bump, the pane split,
  `Design/`, the seven transitions, the appearance toggle, `MotionPlanTests`, `ContrastTests`,
  screenshots. Nothing in `UnfoldMac` or `UnfoldEngine` changes, so the keyboard layer stays
  document-verified and untouched.
- **Plan 4 -- The placeholder prompt.** `UnfoldEngine` (`Prompt`), `UnfoldMac` (`RoutingDecision`,
  `ExpansionCoordinator.library(for:)`) plus `PromptPanelController`. This is the plan Plan 2 named
  and deferred as R-P2-2, and it is the part that can eat the user's keystrokes if it is wrong.

Plan 3 goes first: the prompt panel is built on the design system rather than retrofitted into it.

## Deliberately not done

- SwiftUI, in any dose, including one hosted view.
- An in-app appearance override that hides "Match System".
- Glass in the content layer, glass on list rows, glass behind the editor, or any custom blur.
- Custom colors, an asset catalog, a brand accent.
- A Reduce Motion branch.
- Re-animating controls the system already animates.

## Corrections to carry into the product spec

- "this machine has Command Line Tools only, no Xcode.app" is stale: `/Applications/Xcode.app` with
  SDK 27.0 is present. `make-app-bundle.sh` remains the build path; the sentence goes.
- `LSMinimumSystemVersion` moves 14.0 → 26.0, and the platform decision's cost changes: the app no
  longer runs on Sonoma or Sequoia.
- "Insertion and the placeholder prompt" step 3 gains the amendment above.
