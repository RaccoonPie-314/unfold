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

Eleven shipped units, plus the two Plan 4 adds (`PromptPanelController.swift`,
`Sources/UnfoldEngine/Prompt.swift`), which are listed here so one architecture covers both plans.
`MotionPlan` and `MotionGeometry` deliberately import Foundation only, exactly like `MenuStatus`, so the
motion table and the morph math are testable in `Tests/UnfoldTests` without touching a view.

| Unit | One job | Depends on |
|---|---|---|
| `Sources/Unfold/Design/MotionPlan.swift` | The transition table as values: name, duration, curve, geometry kind. | Foundation |
| `Sources/Unfold/Design/Motion.swift` | Translate one `MotionPlan` entry into Core Animation on layer-backed views. `Motion.morph(_:source:transition:completion:)` is the only code that touches a `CAAnimation`, and it retargets whatever is in flight instead of queueing one. There is deliberately **no** `Motion.stop` (Ruling E): removing the in-flight animation on the next target *is* the stop, and nothing else calls one until Plan 4's panel dismissal asks for it. The FLIP helper is **not** here -- it is the Foundation-only `MotionGeometry.swift` below, plus the source-pose helpers (`insertionGap`, `collapseGap`, `revealEdge`) the production call sites and `MotionProbe` share. | MotionPlan, MotionGeometry, QuartzCore, AppKit |
| `Sources/Unfold/Design/MotionGeometry.swift` | Pure rect math: two rects → scale + centre displacement (`MorphTransform`), anchor-agnostic by design because `Motion` reads the real layer's anchor. Foundation only, so the morph math is assertable without a view. | Foundation |
| `Sources/Unfold/Design/Theme.swift` | Corner radii, spacing scale, type scale, the appearance-preference enum and its persistence. | AppKit |
| `Sources/Unfold/AppShell/Glass.swift` | `wrap(_:cornerRadius:padding:interactive:)` and `windowBackground()`. The `tint:` parameter is deleted: no call site uses it, and color on glass is a budget spent only on status symbols. **There is no container** -- the `NSGlassEffectContainerView` this section first specified was withdrawn during execution (Ruling V), and the file lives in `AppShell/` because both of its functions build views, not tokens. | `NSGlassEffectView` |
| `Sources/Unfold/Design/Contrast.swift` | The `(element, text color, backing, floor)` table and the WCAG math that reads it. It **certifies**; the panes do not read their colours through it (Ruling AJ9 -- routing them through a lookup is Plan 4's). | AppKit |
| `Sources/Unfold/Design/SelectionOverlayLineView.swift` | The shell's only custom-drawn view: the 1 pt separator line `selectionMorph` travels, `separatorColor` filled, `hitTest` nil so an overlay over the window cannot eat a click. In `Design/` because that is where this spec puts drawing (Ruling AJ2); the *instance* is owned by the coordinator, whose two rects live in different panes. | AppKit |
| `Sources/Unfold/AppShell/SidebarViewController.swift` | Source list, filter, selection landing, row insert/remove motion, `ComboRowView`. | Theme, Motion, MotionGeometry |
| `Sources/Unfold/AppShell/EditorViewController.swift` | The editor form, the commit-as-you-type paths, the hint line. Moved from `MainWindowController` verbatim. | Theme, Motion |
| `Sources/Unfold/AppShell/DiagnosticsViewController.swift` | The counters block, the glass test-button cluster, the test result line. | Theme, Glass |
| `Sources/Unfold/AppShell/MainWindowController.swift` | Window, toolbar, split assembly, appearance toggle, cross-pane wiring, the combo model path, and the diagnostics actions the responder chain reaches. **Measured 798 lines at the tip of this pass, not the "near 570" this row first claimed**: Task 5 did land it at 568, then Tasks 10-12 added 242 lines of cross-pane orchestration -- the three morphs, the shared status vocabulary, the window-level overlay, the appearance item -- reaching 810 at Ruling AJ2's review, and this fix wave then took 12 lines back out (the dead `addRemoveItems` surface deleted, and the shell's only custom-drawing class `SelectionOverlayLineView` moved into `Design/`) to land at 798 -- none of which the row's own "570" arithmetic ever counted. Ruling T's decision stands, and Ruling AJ2 upholds it while overturning only the number: splitting the toolbar delegate into a same-type extension file would move code without moving a responsibility, and is deliberately not done. | the four panes |
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
| Toolbar status pill | `Glass.wrap(stack, cornerRadius: 13, padding: 6)` | One `Glass.wrap`, `effectIsInteractive = true` inside it. **Corrected during execution (Ruling V):** the `NSGlassEffectContainerView` first written here was removed -- it merges *descendant glass views* (`NSGlassEffectView.h:49-59`) and this site has exactly one, so it would have merged nothing while still elevating its descendants' z-order. |
| Diagnostics button cluster | `Glass.wrap(column, cornerRadius: 10, padding: 8)` | Unchanged single `Glass.wrap`, for the same reason. **Open question parked for the live pass, not decided blind:** the eight buttons are `NSButton(bezelStyle: .rounded)`, and their macOS 26 material is drawn inside each control rather than as a descendant glass view -- so the cluster may not need a wrap at all ("standard system components pick up the material automatically"). If pixels show two glass layers, the fix is removing the wrap, not adding a container. |
| Combo list rows, editor fields, counters | Ordinary content on ordinary materials | Unchanged -- and stays unchanged. Glass behind list rows would put the material in the content layer and make contrast unguaranteeable. |
| Sidebar scroll edge | `sidebarScroll.automaticallyAdjustsContentInsets = false`, set in what was then `MainWindowController.buildSidebar()` and now `SidebarViewController.loadView()` (the line anchor moved with the extraction in Plan 3 Task 3; the identifier is now absent from `Sources/`, which is the point) | Restored to `true`. Suppressing it removed the system scroll-edge effect, which is exactly the thing the HIG prescribes in place of a solid background under a bar. The magnifier/placeholder collision that motivated it is fixed with the search field's own content inset -- measured from pixels, never guessed -- and not by killing the edge effect again. Whether the collision still occurs is an open live-pass item. |
| Search field, push buttons, pop-up, checkbox | Stock controls | Stock controls. On 26+ these already are the glass treatment; re-skinning them is how the earlier attempts in this repo lost their insets and their selection colors. |
| Prompt panel | does not exist | Ordinary materials for the fields, one `Glass.wrap` around the action bar -- **not** an `NSGlassEffectContainerView`, which Ruling V removed from the shell for having no second glass descendant to merge. Plan 4 must not re-import it unless the action bar is genuinely two separate glass panes side by side. |

Color budget: the app has **two** places that spend color, both of them a glyph rather than a surface -- the
status indicator and the empty/save-failure hint's `exclamationmark.triangle.fill` (the second is mandated
under "Contrast conformance" below, which is why the count this section first gave was wrong). Neither spends
it on glass or on a label: `tintColor` is not set on any surface. Because
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
  is that a person gets stuck in it. **Correction found while building it:** the item is an
  `NSMenuToolbarItem`, not a plain `NSToolbarItem` -- the macOS 27 SDK's `NSToolbarItem` has no `menu`
  property at all, so the shape this section first spelled does not compile. Same symbol, same label,
  same bordered look; `NSMenuToolbarItem` is the class AppKit provides for an item that opens a menu.
- The current choice is marked with a checkmark, and the item's `toolTip` names it.
- The menu is a system menu: it picks up the current appearance and its own open animation for free.
- Persisted in `UserDefaults` under `unfold.appearancePreference` (`system` / `light` / `dark`),
  read once at startup in `main.swift` before any window exists, so the first frame is already right.
- Applied by setting `NSApp.appearance` to `NSAppearance(named: .aqua)` / `.darkAqua`, or back to
  `nil` for Match System. App-level rather than window-level, so the prompt panel, alerts and sheets
  match the main window instead of disagreeing with it.
- **Nothing in the shell needs an appearance observer** (measured, `AppearanceFlipTests`): a semantic
  colour resolved inside `draw(_:)` re-resolves for that draw -- the window-level selection line paints
  `separatorColor` as black α0.102 in aqua and white α0.122 in darkAqua, exactly what each named
  appearance resolves to -- and flipping `NSApp.appearance` schedules that redraw itself, landing on the
  next display pass (an idle drain repaints 0 times; a real flip 1; an assignment that changes nothing
  effective 0). So the override needs no `viewDidChangeEffectiveAppearance` invalidation anywhere, and
  none was added on belief.
- **Honest limit, stated rather than discovered later:** the `NSStatusItem` menu is drawn in the
  system menu bar and follows the *system* appearance, not this override. An app cannot restyle the
  menu bar. The override therefore changes Unfold's windows, panels and alerts only.

**Contrast is a test, not an opinion.** `Tests/UnfoldTests/ContrastTests.swift` resolves every
(text color, backing color) pair under both `.aqua` and `.darkAqua`, **composites the label's alpha
over the backing** -- which the measurement above proved is not optional -- and asserts the floor the
HIG sets: ≥4.5:1 for body and caption text up to 17 pt, ≥3:1 for symbols and large text. The pairs come
from one table that the **tests certify**, both ways: `testTableCoversEveryLabelInTheShell` names every
label and asserts `Contrast.pairs.count` equals the number of names it lists, so a row the list omits and a
row nobody added are both failures. What the table does *not* do is drive the views -- no pane reads a colour
out of it, each sets its own semantic `NSColor`, and keeping the two in step is a review obligation rather
than a mechanism (Ruling AJ9, which rejected the `Contrast.color(for:)` refactor and deferred it to Plan 4,
the pass where new labelled elements actually arrive).

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
  give the app two identities, so monochrome is chosen in both. `MenuStatus` decides symbol and text
  together from one table, and that table feeds both surfaces -- but only in the sense that both read the
  *same decision*: the pill renders the symbol, its colour and `shortText`, while the menu-bar item renders
  `text` and nothing else. There is no glyph and no status colour in the `NSStatusItem` menu.
- No custom color is invented. The alternative -- a dynamic `systemGreen` darkened until it clears 3:1
  -- would put a hand-tuned RGB in the shell, and `dark-mode.md` is explicit that hardcoded values are
  the thing to avoid. If that trade is ever wanted, it is a separate decision with its own numbers.

Two pairs a unit test cannot decide, so they are measured on pixels instead:
- **Label on glass.** The pill samples whatever is behind the window. Checked with screenshots of the
  installed app over a deliberately light and a deliberately dark desktop picture.
- **Increase Contrast / Reduce Transparency.** Both are handled by the real materials, which is the
  argument for keeping the material system-supplied; each gets one screenshot pass rather than code.

## Motion

`MotionPlan` is a `[Transition]` where each `Transition` carries `id`, `duration`, a `Curve`
(`.spring(damping:)` -- **one** knob, because the transition's `duration` *is* the settle time and the
stiffness is derived to fit it (Ruling AC #1) -- or `.easeOut(x1:y1:x2:y2:)`) and a `Geometry`
(`scaleFromGap`, `collapseToGap`, `growFromEdge`, `positionCrossfade`, `symbolMorph`). There is no `Kind`
enum and no `Motion.run(_:)`: `Motion.morph(_:source:transition:completion:)` is the only code that touches
Core Animation, and the FLIP helper is a separate Foundation-only unit -- `MotionGeometry.morph(source:final:)`
turns two rects into a `MorphTransform` of scale plus centre displacement, and `Motion` adds the layer's own
anchor term before installing it. The source poses a call site *derives* (rather than measures off another
view) are `MotionGeometry`'s too -- `insertionGap`, `collapseGap`, `revealEdge` -- so the production panes and
`MotionProbe` cannot drift.

| id | Trigger | Geometry | Duration | Curve |
|---|---|---|---|---|
| `rowInsert` | `+`, or a filter that reveals a row | The new row unfolds out of a zero-height gap on **its own baseline** (`MotionGeometry.insertionGap`). It is the only thing that moves: `setRows` calls `reloadData()`, so every row is already at its final position when the pose installs -- the arriving row grows inside a gap that has **already opened**, and the rows below it jump rather than reflow. | 260ms | spring, damping 0.85 -- measured overshoot **0.63% of the step** |
| `rowRemove` | confirmed delete | The slot the vanished row left collapses onto the **neighbour baseline above it** (`MotionGeometry.collapseGap`). Nothing closes over time either, and the deleted row's own text is never seen shrinking (Ruling AH): `reloadData()` puts the neighbour into the slot first, so what animates is the row that took the slot's place, collapsing onto the line above it. | 220ms | easeOut |
| `selectionMorph` | sidebar selection change | A 1 pt `separatorColor` line -- the window-level `SelectionOverlayLineView` -- travels from the sidebar row's rect to the trigger field's centre line, hidden at rest. Neither the Trigger **caption** nor the field itself crossfades: the pane is re-displayed, not animated, and the travelling line is the whole shared element. | 200ms | easeOut |
| `paneReveal` | stethoscope → Diagnostics | the pane's content grows from the divider edge; the divider itself moves through `NSSplitViewController`'s own animation | 280ms | spring |
| `statusMorph` | tap state change | SF Symbol replacement plus the **wrapped toolbar item view** -- `MainWindowController.statusPill`, the `NSGlassEffectView` AppKit's toolbar sizes -- springing its width to fit the new label, so material and content travel as one object (Ruling AJ7; it used to morph the content stack inside that view, which snapped the box under a springing content) | 240ms | easeOut |
| `promptPresent` | a placeholder combo fires | the panel scales out of the caret's screen rect | 220ms | spring |
| `promptDismiss` | confirm or cancel | reverse into the caret rect | 180ms | easeOut |

**Why the row motion is only half a motion, and what would settle it (open decision for the live pass).**
The two row rows above are what ships; "neighbours reflow" and "the gap closes" are what this table first
promised, and Ruling AJ6 ruled that the spec describes reality rather than the promise being kept by faking a
translate in code nobody has seen on screen. The upgrade is a real motion capability: either drive the list
with `insertRows`/`removeRows` so AppKit animates the reflow, or give each neighbour its own inverted
per-row translate FLIP. **The one observation that decides it:** add a row in the middle of a real list and
watch the rows *below* it. If they jump and that reads wrong to you, do the upgrade; if it reads as a row
arriving, this table stays as written.

**Why 0.63% is the overshoot and ~5% is gone.** The pass adopted the measured number: at ζ = 0.85 a step
peaks at `exp(-πζ/√(1-ζ²))` = 0.63% of itself (0.25 pt on a 40 pt row), which is why the motion driver's band
is "fails above 1%". A ~5% overshoot needs ζ ≈ 0.69, and Core Animation reports a settling time of
`≈7.87/σ` at 2% -equivalent thresholds -- about 1.97× the textbook `4/σ` -- so lowering ζ pushes
`settlingDuration` past the transition's 150-320 ms duration, the clip lands mid-ramp, and the layer jumps the
rest of the way. One clock per spring was the correction that mattered more than the bounce.

Rules, all of them derived from a correction the user already made:

- **Geometry carries the motion.** Opacity is used only as an anti-flash ramp inside the first ~20%
  of a timeline. `MotionPlanTests` asserts every transition's `Geometry` is one of the five shipped cases and
  that the type cannot name a fade-only transition at all; since Ruling AJ4, `MotionProbe` also *reads*
  `Geometry` to pick each transition's source pose, so the enum is no longer declared-and-unread.
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
becomes `emptyComboCount`, and the two places that print it change together, named by method because line
numbers in a spec go stale the moment a pane moves: `MainWindowController.refreshStatus()` (the diagnostics
summary line "N live, M need the prompt UI") and `StatusItemController.rebuild(_:)` (the menu's
"N inactive (need the prompt UI)" note). Keeping the counter rather than deleting it is deliberate -- it is
the sentinel that shows a combo the user can see is not reachable from the keyboard.

This closes the last of the two open items from the 2026-10-27 live verification. The other,
post-delete selection, is fixed in the next section.

**Selection after delete.** The base `reloadRows` landed the selection on **row 0** when the selected combo
was gone, so two fast deletes with the alert unread destroyed the wrong combo. The sidebar now keeps the
deleted row's own index and selects `min(index, count-1)` -- the neighbour -- which is also what `rowRemove`'s
collapse target needs to know. Both are the same change.

Panel layout: captions left of fields, `⌘↩` confirm, Escape cancel, Tab order top-to-bottom, the
action bar in one glass container. The panel is not resizable, is `.floating` level so it survives
the app being an accessory, and closes on Escape regardless of focus.

## Menu bar and alerts

The `NSStatusItem` menu keeps its system-drawn appearance (see the honest limit under Appearance).
What changes is the vocabulary: the menu's status line and the window's status pill are two renderings of
one `MenuStatus` decision, so they cannot disagree about whether expansion can happen. They do not share a
symbol or a colour -- the menu renders `text` and nothing else, and the symbol, its `emphasisColor` and the
shorter `shortText` are the pill's (this section first claimed the two surfaces used the same symbol name and
the same `NSColor`, which the shipped menu does not do). The delete confirmation keeps its system sheet
slide, and its `informativeText` names the file it writes, which it already does.

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

- `MotionPlanTests` (`Tests/UnfoldTests`) -- Foundation-only: seven ids present, every `Geometry` one of the
  five shipped cases (a fade-only transition cannot be named), durations in 150-320ms, no curve steeper than
  the approved control points, springs positive. This is where "native animation for every component" becomes
  a checkable claim.
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
  selection lands on the neighbour rather than on row 0, which is where the base landed.
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
   logs the layer's *presentation* bounds, scale and transform offset at eight timestamps to the launch log,
   so motion is reported as numbers -- a transition that logs one size eight times is not animating. Each one
   is run from **its own source pose**, chosen by the `Geometry` the plan declares for it and taken from the
   same `MotionGeometry` helper the production call site uses (Ruling AJ4); the probe used to hand all five the
   same zero-height gap, which made `paneReveal`'s and `statusMorph`'s numbers describe a grow neither of them
   performs. Chosen
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
