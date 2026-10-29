# Unfold Glass, Appearance and Motion (Plan 3) Implementation Plan

**Goal:** Give Unfold's AppKit shell the macOS 26 Liquid Glass treatment, a measured-contrast Light/Dark contract with a user-visible appearance override, native geometric motion for the transitions the system cannot animate, and a split `MainWindowController` that makes all of that maintainable.

**Architecture:** Three layers. `Design/` holds the tokens, the appearance preference and motion as *pure values* (`MotionPlan`, `MotionGeometry`) so they are assertable without a view; `Motion.swift` is the single thin place that touches Core Animation. The shell keeps its stock AppKit controls -- on macOS 26+ those already render the real material -- and hand-placed glass is confined to one `NSGlassEffectContainerView` holding the two floating control clusters. The 963-line `MainWindowController` becomes three pane controllers plus a thin coordinator that owns the model.

> **Amended by Ruling V (decided during Task 6's execution) and restated here by the final review's
> cleanup.** The container in that paragraph was withdrawn and never shipped:
> `NSGlassEffectContainerView` merges *descendant glass views*, and each cluster has exactly one
> `Glass.wrap`, so it would have merged nothing while elevating z-order. What ships is two independent
> `Glass.wrap` calls plus `Glass.windowBackground()` -- and `Glass.swift` lives in `Sources/Unfold/AppShell/`,
> not `Design/`, because both of its functions build views. Two more clauses in the same paragraph are also
> not what shipped: there is no `Glass.container` (grep for it in `Sources/` is empty), and the coordinator is
> not thin -- it measures **798** lines at the tip of this pass (810 at Ruling AJ2's review of `43a527c`, before
> this fix wave moved the `SelectionOverlayLineView` class into `Design/` and deleted the dead `addRemoveItems`
> surface out of it), which the spec's architecture row now says
> (Ruling AJ2 upheld Ruling T's decision not to split it further, and overturned only the number).

**Tech Stack:** Swift 6.4 (SwiftPM, `swift-tools-version: 6.2`), AppKit, QuartzCore (`CASpringAnimation`, `CATransform3D`), XCTest, `vtool`/`screencapture` for verification. No third-party dependencies.

**Spec:** `docs/specs/2026-10-29-unfold-liquid-glass-motion-design.md` -- read it with this plan. Where the two disagree, the spec's measured numbers win; three corrections were already folded back into it after measuring (see "Corrections found while planning").

## Global Constraints

Every task's requirements implicitly include this section.

- `// swift-tools-version: 6.2` and `platforms: [.macOS(.v26)]`, `LSMinimumSystemVersion` `26.0`.
  `.v26` does not exist below tools-version 6.2 -- measured, `6.0` fails with `'v26' is unavailable`.
- `swiftLanguageModes: [.v5]` stays. It is load-bearing: tap callbacks are `@convention(c)` pointers.
- No third-party dependencies.
- **Plan 3 touches nothing in `Sources/UnfoldEngine/` or `Sources/UnfoldMac/`.** `UnfoldEngine` stays
  Foundation-only; the keyboard layer keeps its document-verified behaviour untouched.
- Exactly one `#available` guard may exist in `Sources/Unfold/` after Task 1, and it is the one on
  `effectIsInteractive`: the SDK marks that property `API_AVAILABLE(macos(27.0))`
  (`NSGlassEffectView.h:45`) while the floor is 26. Every macOS 26 *fallback* branch is deleted.
  Verified by grep, and Ruling F covers it.
- No hand-drawn glass, blur or vibrancy. No `tintColor` on any glass surface. Glass appears only in
  the functional layer: never behind list rows, editor fields or the counters block.
- No hard-coded RGB. Colors come from semantic `NSColor` only. No asset catalog -- `swift build` has no
  `actool`, so a Color Set is not available to this package.
- Contrast floors, measured with the label's alpha composited over the backing: **≥4.5:1** for text
  up to 17 pt, **≥3:1** for symbols. Baseline measured 2026-10-29 on macOS 27.2: `label`/window
  `14.94:1` (aqua) and `12.23:1` (dark); `secondaryLabel`/window **`3.95:1` aqua** -- which is why
  meaningful text moves to `labelColor`.
- Motion: durations `150-320ms`; geometry carries the motion; opacity only as an anti-flash ramp in
  the first ~20% of a timeline; the approved curve is `cubic-bezier(0.33, 1, 0.68, 1)`, never the
  steeper `(0.22, 1, 0.36, 1)`; **no Reduce Motion branch** -- motion stays unconditional.
- Controls the system already animates (push buttons, pop-ups, focus ring, sheets, sidebar toggle) get
  no custom motion.
- Appearance default is `.system`; `NSApp.appearance` is the only lever; the persisted key is exactly
  `unfold.appearancePreference` with raw values `system` / `light` / `dark`.
- `UIDesignRequiresCompatibility` must not appear in `Resources/Info.plist`.
- The window's `+`, delete, pause, diagnostics and self-test/stress/idle/Ctrl-C buttons must still work
  at the end of every task; the self-test buttons hold a reference to the "Try it" text view, whose
  owner changes in Task 4.
- Commit messages: plain imperative sentences, no `feat:` prefixes.
- **Git -- this bullet supersedes every per-task "Stop for review ... no commit" step below.** On
  2026-10-29 one local commit per task was authorised on the current branch
  (`task/unfold-keyboard-layer`), so each task's final step is: run its verification, `git add` only the
  files that task changed, commit once, then stop for review. Commit messages are plain imperative sentences with
  no `feat:` prefix and no trailer. **Never** `git push`, `git tag`, `git commit --amend`, `git stash`, or
  `git checkout -- <path>`; never stage a file the task did not change. Pushing happens outside the plan.
- The project path contains a space: `"$REPO_ROOT"`. Quote it
  in every command.
- Baseline before starting, measured 2026-10-29: **186 test methods, 0 failures**, across three targets
  -- `UnfoldEngineTests` 71, `UnfoldMacTests` 106, `UnfoldTests` 9. Note that `swift test` prints an
  `Executed N tests` line *per target*, so "71" is one target's total and not the suite's; use the two
  commands below rather than eyeballing a single line. Every task keeps them green and adds to the count:

  ```bash
  swift test --list-tests 2>/dev/null | grep -c "/"                     # total test methods
  swift test 2>&1 | grep -E "Test Suite 'All tests' failed|with [1-9][0-9]* failures" || echo GREEN
  ```

## File structure

Created:

| Path | One responsibility |
|---|---|
| `Sources/Unfold/Design/Theme.swift` | Type, radius, spacing tokens; `AppearancePreference` and its persistence |
| `Sources/Unfold/Design/Contrast.swift` | The (element, text color, backing, floor) table and the WCAG math that reads it |
| `Sources/Unfold/Design/MotionPlan.swift` | The transition table as values. Foundation only, no AppKit |
| `Sources/Unfold/Design/MotionGeometry.swift` | Pure rect math: two rects → scale/translation. Foundation + CoreGraphics. *(No `flippedness` input -- Ruling AE deleted the parameter; see Task 9. The three source-pose helpers `insertionGap` / `collapseGap` / `revealEdge` were added here by Ruling AJ4 so the panes and `MotionProbe` share one spelling.)* |
| `Sources/Unfold/Design/Motion.swift` | The only Core Animation in the shell: apply a plan entry to a layer-backed view |
| `Sources/Unfold/AppShell/SidebarViewController.swift` | Source list, filter, row diffing, row motion, `ComboRowView` |
| `Sources/Unfold/AppShell/EditorViewController.swift` | The editor form, commit paths, hint line, "Try it" field, path label |
| `Sources/Unfold/AppShell/DiagnosticsViewController.swift` | Counters block, glass test-button cluster, result line, motion probe |
| `Sources/Unfold/AppShell/MotionProbe.swift` | Runs each transition and logs measured presentation-frame rects |
| `Tests/UnfoldTests/ThemeTests.swift` | Preference decoding and application |
| `Tests/UnfoldTests/ContrastTests.swift` | The measured floors, both appearances |
| `Tests/UnfoldTests/MotionPlanTests.swift` | Duration band, curve steepness, geometry-only kinds |
| `Tests/UnfoldTests/MotionGeometryTests.swift` | Morph math, flipped and unflipped, degenerate rects |

Modified: `Package.swift`, `Resources/Info.plist`, `Sources/Unfold/main.swift`,
`Sources/Unfold/AppShell/Glass.swift`, `Sources/Unfold/AppShell/MainWindowController.swift`,
`Sources/Unfold/AppShell/StatusItemController.swift`,
`docs/specs/2026-10-23-macos-text-expander-design.md`.

Deleted content: `Glass.wrap`'s `tint` parameter, `MainWindowController.vstack` (unused), the
deprecated `selectionHighlightStyle = .sourceList` assignment, and every macOS 26 *fallback*
`#available` branch in the shell. One guard remains by necessity: `effectIsInteractive` is
`API_AVAILABLE(macos(27.0))` against a 26 floor.

## Task map

| # | Task | Ends with |
|---|---|---|
| 1 | Floor bump, fallback deletion, product-spec corrections | `minos 26.0`, one 27.0 guard, 186 green |
| 2 | Theme tokens + `AppearancePreference` + startup application | persisted override changes the running app |
| 3 | Extract `SidebarViewController` | list behaves identically, in its own file |
| 4 | Extract `EditorViewController` | editor behaves identically; `+`/delete still land |
| 5 | Extract `DiagnosticsViewController`, thin the controller | three panes out; the controller stops owning pane internals (it lands at 568, not ~200 -- see Ruling T/AJ2) |
| 6 | ~~One glass container~~ Interactive glass on the existing wraps -- **the container was withdrawn by Ruling V** | press response visible; one `Glass.wrap` per cluster, no merged slab |
| 7 | `Contrast.swift` + `ContrastTests` + the color moves | Light mode meets the floor, asserted |
| 8 | `MotionPlan.swift` + `MotionPlanTests` | the seven transitions exist as data |
| 9 | `MotionGeometry.swift` + `MotionGeometryTests` | morph math proven for both coordinate spaces |
| 10 | `Motion.swift` + `MotionProbe` + probe button | one transition measured to move geometrically |
| 11 | Wire `rowInsert`, `rowRemove`, `selectionMorph`, `paneReveal`, `statusMorph`; neighbour selection | all five measured; delete lands on the neighbour instead of row 0 |
| 12 | Appearance toolbar item, shared status vocabulary, two-appearance capture | toggle works, menu and pill agree |

---

### Task 1: Raise the floor to macOS 26 and delete the fallbacks

**Files:**
- Modify: `Package.swift:1` and `Package.swift:6`
- Modify: `Resources/Info.plist` (`LSMinimumSystemVersion`)
- Modify: `Sources/Unfold/AppShell/Glass.swift`
- Modify: `docs/specs/2026-10-23-macos-text-expander-design.md` (the stale build-environment claim)

**Interfaces:**
- Produces: `Glass.wrap(_ content: NSView, cornerRadius: CGFloat, padding: CGFloat, interactive: Bool = true) -> NSView` -- **no `tint` parameter**; no call site used it. `Glass.windowBackground() -> NSView` unchanged.
- Produces: a package whose built executable has `minos 26.0`, which later tasks rely on when they use `NSGlassEffectView` without a guard.

- [ ] **Step 1: Bump the manifest and the floor**

`Package.swift` line 1 and the `platforms:` line become exactly:

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Unfold",
    platforms: [.macOS(.v26)],
```

Leave `swiftLanguageModes: [.v5]` and every target block untouched.

- [ ] **Step 2: Verify the manifest change compiles and lands in the binary**

```bash
cd "$REPO_ROOT"
swift build 2>&1 | tail -3
vtool -show-build .build/debug/Unfold | grep minos
```
Expected: `Build complete!` and `minos 26.0`. If the manifest errors with `'v26' is unavailable`, the
tools-version line did not change -- that is the failure mode measured while planning.

- [ ] **Step 3: Raise the bundle's declared minimum**

In `Resources/Info.plist`, replace the `LSMinimumSystemVersion` value `14.0` with `26.0`:

```xml
	<key>LSMinimumSystemVersion</key>
	<string>26.0</string>
```

- [ ] **Step 4: Delete the availability branches and the unused tint parameter**

`Sources/Unfold/AppShell/Glass.swift` becomes exactly this (the `guard #available(macOS 26.0)` wrapper
and the `tint` parameter are gone; the 27.0 guard on `effectIsInteractive` is the one that remains,
because the floor is 26 and that property arrived in 27):

```swift
import AppKit

/// The system's Liquid Glass, and only the system's.
///
/// `NSGlassEffectView` exists from macOS 26, which is this app's floor, so there is no fallback path
/// to maintain and no hand-made blur to imitate it -- an imitation reads as a sticker the moment
/// anything moves behind it, and `liquid-glass.md` treats a fake glass surface as worse than none.
///
/// Placement follows Apple's boundary: glass is the floating **control** layer. The toolbar, the
/// status pill and the diagnostics cluster get it. The combo list and the editor fields do not -- text
/// on a surface that samples the desktop behind the window is text whose contrast nobody can
/// guarantee.
enum Glass {
    /// Wraps a control in glass, with `padding` of glass left around it.
    @MainActor
    static func wrap(_ content: NSView, cornerRadius: CGFloat, padding: CGFloat,
                     interactive: Bool = true) -> NSView {
        let glass = NSGlassEffectView()
        glass.style = .regular
        glass.cornerRadius = cornerRadius
        // The only availability check the shell keeps. The floor is macOS 26 and this property arrived
        // in 27, so below 27 the glass stays static -- its documented default -- rather than the call
        // being faked with a hand-made hover.
        if #available(macOS 27.0, *) { glass.effectIsInteractive = interactive }
        content.translatesAutoresizingMaskIntoConstraints = false
        glass.contentView = content
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: glass.leadingAnchor, constant: padding),
            content.trailingAnchor.constraint(equalTo: glass.trailingAnchor, constant: -padding),
            content.topAnchor.constraint(equalTo: glass.topAnchor, constant: padding),
            content.bottomAnchor.constraint(equalTo: glass.bottomAnchor, constant: -padding),
        ])
        return glass
    }

    /// The window's own surface: a material that blurs what is behind it, which is what gives the
    /// glass controls something to refract. `.underWindowBackground` is the material meant for this
    /// slot.
    @MainActor
    static func windowBackground() -> NSView {
        let effect = NSVisualEffectView()
        effect.material = .underWindowBackground
        effect.blendingMode = .behindWindow
        effect.state = .followsWindowActiveState
        return effect
    }
}
```

- [ ] **Step 5: Correct the stale build-environment claim in the product spec**

In `docs/specs/2026-10-23-macos-text-expander-design.md`, replace the paragraph that
begins "Build environment constraint: this machine has Command Line Tools only, no Xcode.app" with:

```markdown
Build environment: Xcode is installed (`/Applications/Xcode.app`, SDK 27.0), corrected 2026-10-29 --
the original draft recorded Command Line Tools only. The project is still a SwiftPM package and the
`.app` bundle is still assembled by `Scripts/make-app-bundle.sh`, because that path is what the
keystroke-tap verification uses. The platform floor is macOS 26 (Plan 3), so the app does not run on
Sonoma or Sequoia.
```

- [ ] **Step 6: Verify the single surviving guard and the unchanged suite**

```bash
cd "$REPO_ROOT"
grep -rn "#available" Sources/Unfold/
[ "$(grep -rn '#available' Sources/Unfold/ | wc -l | tr -d ' ')" = "1" ] \
  && grep -q 'macOS 27.0' Sources/Unfold/AppShell/Glass.swift && echo "one guard, on effectIsInteractive"
grep -c "UIDesignRequiresCompatibility" Resources/Info.plist | grep -q "^0$" && echo "compat key absent"
swift test 2>&1 | grep -E "Test Suite 'All tests' failed|with [1-9][0-9]* failures" || echo GREEN
swift test --list-tests 2>/dev/null | grep -c /
```
Expected: the only `#available` line in `Sources/Unfold/` is the `macOS 27.0` guard on
`effectIsInteractive` -- that guard is required, because the floor is 26 and the property arrived in 27
(`NSGlassEffectView.h:45`); `one guard, on effectIsInteractive`; `compat key absent`; `GREEN`; `186`.

- [ ] **Step 7: Commit, then stop for review**

```bash
cd "$REPO_ROOT"
git add Package.swift Resources/Info.plist Sources/Unfold/AppShell/Glass.swift \
        docs/specs/2026-10-23-macos-text-expander-design.md
git commit -m "Require macOS 26 and delete the pre-glass fallbacks"
git show --stat --oneline HEAD
```
Then list the changed files and the check output. Do not push. The bundle is rebuilt by hand
(`Scripts/install-local.sh`) and the window checked against how it looked before, since a floor bump changes how
the system renders the stock controls.

---

### Task 2: Theme tokens and the appearance preference

**Files:**
- Create: `Sources/Unfold/Design/Theme.swift`
- Create: `Tests/UnfoldTests/ThemeTests.swift`
- Modify: `Sources/Unfold/main.swift` (apply the preference before any window exists)

**Interfaces:**
- Produces:
  - `enum AppearancePreference: String, CaseIterable { case system, light, dark }`
  - `static AppearancePreference.read(from defaults: UserDefaults = .standard) -> AppearancePreference`
  - `func write(to defaults: UserDefaults = .standard)`
  - `var appearanceName: NSAppearance.Name?` (nil for `.system`) and `func apply()` which sets `NSApp.appearance`
  - `static let UserDefaults.unfoldAppearanceKey = "unfold.appearancePreference"`
  - `enum Theme { enum Radius { card, pill }; enum Spacing { panePadding, captionColumn, gutter }; enum Font { caption, body, mono, monoTrigger } }` -- only tokens a later task reads (Ruling A: no `fieldGap`, no `captionEmphasised`, no `Radius.small`)
- Consumed by: Tasks 3-7 for every radius/spacing/size, Task 12 for the toolbar control, `main.swift` for startup.

- [ ] **Step 1: Write the failing tests**

Create `Tests/UnfoldTests/ThemeTests.swift`:

```swift
import AppKit
import XCTest
@testable import Unfold

/// The preference is a decoded value, not a view: it must survive a garbage defaults entry by
/// falling back to the system, because a stuck Dark mode is the failure the HIG warns about.
final class ThemeTests: XCTestCase {
    /// `UserDefaults(suiteName:)` persists on every `set`, so the domains it creates are tracked and
    /// cleared in `tearDown`. Clearing turns out not to be sufficient on its own: a *named* suite writes
    /// `~/Library/Preferences/<suite>.plist`, and cfprefsd re-creates that file after the test process
    /// exits even when `removePersistentDomain` has run -- the run leaked four empty plists every time.
    /// A suite name that is an absolute path keeps the same genuinely-persistent domain under a per-run
    /// temp directory, so the real preferences folder is never written and a value written by one
    /// process is still read back by another.
    private let runDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("UnfoldTests.Theme.\(UUID().uuidString)")
    private var suites: [String] = []

    private func freshDefaults(_ suffix: String) -> UserDefaults {
        try? FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
        let name = runDirectory.appendingPathComponent("UnfoldTests.Theme.\(suffix)").path
        suites.append(name)
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    override func tearDown() {
        for name in suites {
            UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
        }
        suites.removeAll()
        try? FileManager.default.removeItem(at: runDirectory)
        super.tearDown()
    }

    func testMissingValueMeansMatchSystem() {
        XCTAssertEqual(AppearancePreference.read(from: freshDefaults("missing")), .system)
    }

    func testUnknownValueMeansMatchSystem() {
        let defaults = freshDefaults("unknown")
        defaults.set("graphite", forKey: UserDefaults.unfoldAppearanceKey)
        XCTAssertEqual(AppearancePreference.read(from: defaults), .system,
                       "an unreadable preference must not strand the app in a fixed appearance")
    }

    func testRoundTripThroughDefaults() {
        for preference in AppearancePreference.allCases {
            let defaults = freshDefaults("roundtrip-\(preference.rawValue)")
            preference.write(to: defaults)
            XCTAssertEqual(AppearancePreference.read(from: defaults), preference)
        }
    }

    /// The on-disk contract, pinned as a literal. A round-trip test alone stays green if the key or a
    /// raw value is renamed, and a renamed key silently breaks hand-edited defaults and the toolbar
    /// control that writes it later.
    func testPersistedContractIsPinned() {
        XCTAssertEqual(UserDefaults.unfoldAppearanceKey, "unfold.appearancePreference")
        XCTAssertEqual(AppearancePreference.allCases.map(\.rawValue), ["system", "light", "dark"],
                       "Match System first, because it is the default the menu must keep reachable")
    }

    func testAppearanceNameMapping() {
        XCTAssertEqual(AppearancePreference.system.appearanceName, nil)
        XCTAssertEqual(AppearancePreference.light.appearanceName, .aqua)
        XCTAssertEqual(AppearancePreference.dark.appearanceName, .darkAqua)
        XCTAssertEqual(AppearancePreference.allCases.count, 3,
                       "Match System must stay reachable from the same control")
    }

    /// `apply()` is the only part of this type with a runtime effect, so it is asserted rather than
    /// read. `NSApp` only exists once the shared application has been created.
    func testApplyMovesTheAppAppearance() {
        _ = NSApplication.shared
        AppearancePreference.dark.apply()
        XCTAssertEqual(NSApp.appearance?.name, .darkAqua)
        AppearancePreference.light.apply()
        XCTAssertEqual(NSApp.appearance?.name, .aqua)
        AppearancePreference.system.apply()
        XCTAssertNil(NSApp.appearance, "Match System must leave the app tracking the system")
    }
}
```

- [ ] **Step 2: Run them to verify they fail**

```bash
cd "$REPO_ROOT"
swift test --filter ThemeTests 2>&1 | tail -5
```
Expected: a compile failure naming `AppearancePreference` as an unresolved identifier.

- [ ] **Step 3: Write `Theme.swift`**

Create `Sources/Unfold/Design/Theme.swift`:

```swift
import AppKit

/// The one place the app's look is decided, so a change to a radius or a caption size is one edit.
///
/// Colors are deliberately absent: every color in the shell is a semantic `NSColor` that resolves per
/// appearance, and `swift build` cannot compile an asset catalog. What is spelled out here is the
/// geometry and type, plus the appearance preference.
enum Theme {
    enum Radius {
        static let card: CGFloat = 10    // glass-wrapped clusters
        static let pill: CGFloat = 13    // the toolbar status pill
    }

    enum Spacing {
        static let panePadding: CGFloat = 24
        static let captionColumn: CGFloat = 82
        static let gutter: CGFloat = 12
    }

    enum Font {
        /// The platform floor for body text is 11 pt; 11 is also the system's own caption size, and
        /// hierarchy is carried by weight against the 13 pt body rather than by a colour step, because
        /// secondary label measures 3.95:1 over a light window background.
        static let caption: NSFont = .systemFont(ofSize: 11)
        static let body: NSFont = .systemFont(ofSize: 13)
        static let mono: NSFont = .monospacedSystemFont(ofSize: 13, weight: .regular)
        static let monoTrigger: NSFont = .monospacedSystemFont(ofSize: 12.5, weight: .medium)
    }
}

extension UserDefaults {
    /// Raw values are `system` / `light` / `dark`. Written by the toolbar control, read once at launch.
    static let unfoldAppearanceKey = "unfold.appearancePreference"
}

/// App-level appearance override. The default is `.system`, which leaves `NSApp.appearance` nil so the
/// app tracks the system -- including the Auto time-of-day switch -- with no code of its own.
enum AppearancePreference: String, CaseIterable {
    case system
    case light
    case dark

    static func read(from defaults: UserDefaults = .standard) -> AppearancePreference {
        guard let raw = defaults.string(forKey: UserDefaults.unfoldAppearanceKey),
              let parsed = AppearancePreference(rawValue: raw) else { return .system }
        return parsed
    }

    func write(to defaults: UserDefaults = .standard) {
        defaults.set(rawValue, forKey: UserDefaults.unfoldAppearanceKey)
    }

    var appearanceName: NSAppearance.Name? {
        switch self {
        case .system: return nil
        case .light: return .aqua
        case .dark: return .darkAqua
        }
    }

    /// App-level rather than window-level, so the prompt panel, alerts and sheets cannot disagree with
    /// the main window. `NSAppearance(named:)` is failable, and a name that fails to resolve must fall
    /// back to the system rather than leave the previous appearance stuck.
    func apply() {
        guard let appearanceName, let appearance = NSAppearance(named: appearanceName) else {
            NSApp.appearance = nil
            return
        }
        NSApp.appearance = appearance
    }
}
```

- [ ] **Step 4: Apply it at startup, before any window exists**

In `Sources/Unfold/main.swift`, insert the two lines marked below so the preference lands before
`AppMenu.install()` and long before `AppDelegate` builds a window:

```swift
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
// Before any window exists: the appearance must be decided for the first frame, not corrected after
// the window has already drawn once in the wrong one.
AppearancePreference.read().apply()
// Before any window exists: the app's own text fields resolve ⌘V and ⌘A through this menu.
AppMenu.install()
```

- [ ] **Step 5: Run the tests and verify the override reaches the running app**

```bash
cd "$REPO_ROOT"
swift test --filter ThemeTests 2>&1 | grep -E "Executed|failures"
swift build 2>&1 | tail -2
ls ~/Library/Preferences | grep -c "^UnfoldTests\\.Theme\\." 
```
Expected: ThemeTests green (6 methods), build complete, and **`0`** -- the run must leave no preference
domain behind. If it prints a non-zero count, that is a leak: `defaults delete` each named domain,
remove the file, and say so in the note; the `tearDown` above is what is supposed to prevent it.

Do **not** write to `io.github.raccoonpie314.unfold`. That lives in the shipped app's real
environment, and the app has no UI to change it back until Task 12. When Task 12 needs it, the key is
`unfold.appearancePreference` -- the Swift property name `unfoldAppearanceKey` is not the persisted string
and writing it would produce a false negative.

- [ ] **Step 6: Stop for review**

Changed: `Sources/Unfold/Design/Theme.swift`, `Tests/UnfoldTests/ThemeTests.swift`,
`Sources/Unfold/main.swift`. No commit.

---

### Task 3: Extract `SidebarViewController`

Pure relocation plus one behaviour-preserving fix. No new features. The point is that the row list, its
filter and its motion get a home that later tasks can extend without opening a 963-line file.

**Files:**
- Create: `Sources/Unfold/AppShell/SidebarViewController.swift`
- Modify: `Sources/Unfold/AppShell/MainWindowController.swift` -- remove lines
  [120-166](../../../Sources/Unfold/AppShell/MainWindowController.swift) (`buildSidebar`,
  `sidebarContainer`), 25-29 (`tableView`, `sidebarScroll`, `searchField`, `filter`, `visible`),
  499-522 (data source/delegate/`controlTextDidChange` for the search field), 697-716 (`reloadRows`),
  718-721 (`editTriggerFromList`), 864-949 (`ComboRowView`, `Combo.preview`), 130-131 double-action wiring
- Test: the existing suite, plus a live check

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces:
  - `final class SidebarViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate`
  - `var onSelect: ((UUID?) -> Void)?` -- fired for every selection change, including an empty selection
  - `var onFilter: ((String) -> Void)?` -- fires with the search field's new text
  - `var onRequestEdit: (() -> Void)?` -- the double-click path; the controller routes it to the editor
  - `var searchText: String { get }` -- the field's current text, for the controller's empty-state copy
  - `func setRows(_ rows: [Combo], selecting id: UUID?)` -- the only way the list changes; the rows arrive **already filtered**
  - `func clearFilter()` -- empties the field and the pane's copy of the text
  - `func focusList()`
  - `var selectedRowFrame: CGRect?` -- in screen coordinates, needed by `selectionMorph` in Task 11
  - `var listTableView: NSTableView { get }` -- read-only, because the window keeps
    `initialFirstResponder = tableView` and the controller cannot reach a private property

The pane holds **no** filter string of its own. `MainWindowController.filter` is the single source, so
`addCombo` clearing the filter and the empty-state copy ("Nothing matches «...»") cannot disagree with
what the list shows.

- [ ] **Step 1: Create the pane file with the moved code**

Create `Sources/Unfold/AppShell/SidebarViewController.swift`. The bodies of `buildSidebar`, the table
data source/delegate methods, `reloadRows`, `ComboRowView` and `Combo.preview` move **verbatim** from
`MainWindowController` (line ranges in Files above); the additions are the interface and the plumbing:

```swift
import AppKit
import UnfoldEngine

/// The library list: a source list of combos with a filter over it.
///
/// The pane renders; it does not decide. `setRows(_:selecting:)` is the only entry point, which is what
/// lets Task 11 animate the diff: the pane can see which ids arrived and which left because it
/// remembers what it last showed. The model and the filter string stay with the window controller -- the
/// pane reports intent through `onSelect` / `onFilter` / `onRequestEdit` and never edits a `Combo`.
final class SidebarViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate,
                                   NSSearchFieldDelegate {
    var onSelect: ((UUID?) -> Void)?
    var onFilter: ((String) -> Void)?
    var onRequestEdit: (() -> Void)?

    private let tableView = NSTableView()
    private let sidebarScroll = NSScrollView()
    private let searchField = NSSearchField()
    private var visible: [Combo] = []
    private var shownIDs: [UUID] = []

    var searchText: String { searchField.stringValue }
    var listTableView: NSTableView { tableView }

    override func loadView() { /* the moved buildSidebar() body, ending with self.view = container */ }

    /// Puts the selection back where it was. Row indexes are indexes into `visible`, never into
    /// `file.combos`, so a filter cannot make the editor select a combo that is not on screen.
    func setRows(_ rows: [Combo], selecting id: UUID?) { /* the moved reloadRows() body, filtered part removed */ }

    func focusList() { view.window?.makeFirstResponder(tableView) }

    /// The selected row's frame in screen coordinates -- the anchor the editor's morph starts from.
    var selectedRowFrame: CGRect? {
        let row = tableView.selectedRow
        guard row >= 0, let rowView = tableView.rowView(atRow: row, makeIfNecessary: false),
              let window = view.window else { return nil }
        return window.convertToScreen(tableView.convert(rowView.frame, to: nil))
    }

    /// The controller clears the filter when a combo is added, because "new" is a word a half-typed
    /// filter would hide.
    func clearFilter() {
        searchField.stringValue = ""
    }
}
```

Inside the moved code, three substitutions are required and nothing else changes:

1. `reloadRows()` becomes `setRows(_:selecting:)`. It takes the already-filtered array instead of
   reading `file.combos`, its filter block is deleted (the controller filters), and instead of assigning
   `selectedID` it calls `onSelect?(...)`. Its `tableView.selectRowIndexes(...)` calls stay as they are.
2. `controlTextDidChange` keeps its `searchField` identity check and becomes
   `onFilter?(searchField.stringValue)` -- the pane does not store the text.
3. `tableViewSelectionDidChange` calls `onSelect?(...)`, and `editTriggerFromList` calls
   `onRequestEdit?()` instead of touching the trigger field, which is Task 4's to own.

At the end of `setRows`, record the ids it showed, so Task 11 can diff against them:
`shownIDs = visible.map(\.id)`.

Also in this task, while the file is open: delete the deprecated
`tableView.selectionHighlightStyle = .sourceList` line, keeping `tableView.style = .sourceList`.
Verify afterwards that `swift build` no longer prints the `'sourceList' was deprecated in macOS 12.0`
warning for this file.

- [ ] **Step 2: Rewire the window controller**

In `MainWindowController`: add `private let sidebar = SidebarViewController()`, drop the properties and
methods listed in Files, and change the split assembly to host the pane:

```swift
private func assembleSplitView() {
    let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
    sidebarItem.minimumThickness = 190
    sidebarItem.preferredThicknessFraction = 0.3
    sidebarItem.canCollapse = false
    splitView.addSplitViewItem(sidebarItem)
    // ...detail and diagnostics items unchanged...
}
```

Install the plumbing in `init`, after the panes are built and before `reloadRows()`:

```swift
sidebar.onSelect = { [weak self] id in
    self?.selectedID = id
    self?.loadEditor()
}
sidebar.onFilter = { [weak self] needle in
    self?.filter = needle
    self?.reloadRows()
}
// In this task it still opens the controller's own trigger field; Task 4 replaces the body with
// `self?.editor.beginTriggerEdit()` once the editor is a pane.
sidebar.onRequestEdit = { [weak self] in
    self?.editTriggerFromList()
}
```

Inside the pane, the table's double action can no longer target a controller selector, so it becomes:

```swift
tableView.doubleAction = #selector(doubleClicked)
tableView.target = self

@objc private func doubleClicked() { onRequestEdit?() }
```

`window.initialFirstResponder = tableView` in `init` becomes
`window.initialFirstResponder = sidebar.listTableView` -- the list, not the filter: an accidental keystroke
should move the selection, not quietly narrow the library to nothing. That comment travels with it.

`filter` stays on the controller (it is part of the library's state, and `addCombo` clears both), so
`addCombo` calls `sidebar.clearFilter()` in place of its two current assignment lines
([MainWindowController.swift:633-634](../../../Sources/Unfold/AppShell/MainWindowController.swift)),
and every `reloadRows()` in the controller ends with:

```swift
private func reloadRows() {
    let needle = filter.lowercased()
    let matching = needle.isEmpty ? file.combos : file.combos.filter {
        $0.trigger.lowercased().contains(needle) || $0.label.lowercased().contains(needle)
            || $0.preview.lowercased().contains(needle)
    }
    sidebar.setRows(matching, selecting: selectedID)
}
```

The filter predicate moves with it -- the controller filters, the pane renders. `Combo.preview` moves to
`SidebarViewController.swift` as an `internal extension Combo` (drop the `fileprivate`) so both files
can see it.

- [ ] **Step 3: Compile and run the suite**

```bash
cd "$REPO_ROOT"
swift build 2>&1 | grep -E "error|warning: 'sourceList'|Build complete" ; swift test 2>&1 | grep -E "Test Suite 'All tests' failed|with [1-9][0-9]* failures" || echo GREEN
```
Expected: `Build complete!`, no `sourceList` deprecation line, `GREEN`.

- [ ] **Step 4: Live check, because Auto Layout reports a satisfied layout while a pane renders wrong**

Rebuild the bundle and run it -- this raises a window, so do it when nothing else needs the screen:

```bash
cd "$REPO_ROOT" && ./Scripts/make-app-bundle.sh && ./Scripts/install-local.sh
```
Verify by eye: rows show trigger over preview, selection tints the row and the symbol follows it, the
filter narrows the list, `+` lands a selected focused row, deleting selects a row, and the sidebar width
still opens at 218 pt.

- [ ] **Step 5: Stop for review**

Changed: `Sources/Unfold/AppShell/SidebarViewController.swift` (new),
`Sources/Unfold/AppShell/MainWindowController.swift`. No commit.

---

### Task 4: Extract `EditorViewController`

> **Amended by Ruling AG, decided from Task 11b's review, and restated here by the final review (Ruling
> AJ10).** Everything this task produces about a **proxy view** is withdrawn. `editor.triggerFieldProxy` -- the
> interface below, the `triggerProxy` code block in Step 2, and Task 5's Step 0 regression test for it -- does
> not exist in the shipped shell, and `grep -rn triggerFieldProxy Sources/` is empty. The pane-hosted proxy
> was clipped: the split view's `_NSSplitViewItemViewWrapper` has `masksToBounds == true` (measured), and this
> morph's start pose is a row-sized bar sitting over the *sidebar*, so the pane cut it and the line popped in
> at the editor's left edge instead of travelling from the row -- the shared element reduced to an appearance.
> What shipped instead: the 1 pt `separatorColor` line is a `SelectionOverlayLineView` hosted by the
> **window's own content view** (the common unclipped ancestor of both panes), owned and morphed by
> `MainWindowController`, still hidden at rest per Ruling R and still `hitTest`-nil; the class itself lives in
> `Sources/Unfold/Design/SelectionOverlayLineView.swift`, moved out of the coordinator by Ruling AJ2 because it
> is the shell's only custom-drawing view. The pane keeps only the
> accessor the morph needs -- `triggerFieldFrameInWindow`. `EditorViewController` is otherwise exactly as
> specified here.

**Files:**
- Create: `Sources/Unfold/AppShell/EditorViewController.swift`
- Modify: `Sources/Unfold/AppShell/MainWindowController.swift` -- remove lines
  [168-265](../../../Sources/Unfold/AppShell/MainWindowController.swift) (`buildDetail`,
  `detailContainer`), 30-37 + 39-40 (`triggerField`, `replacementScroll`, `replacementView`,
  `insertionPopUp`, `enabledCheck`, `editorHint`, `tryScroll`, `tryView`, `testResult`'s sibling
  `pathLabel`), 372-398 (`configure(_:in:monospaced:)`, `caption`), 526-577 (`loadEditor`, `selected`,
  `hint(for:)`, `showHint`), 579-618 (commit paths), 718-721, and the `NSTextViewDelegate` conformance

**Interfaces:**
- Consumes: `Theme.Font`, `Theme.Spacing` from Task 2.
- Produces:
  - `enum ComboEdit { case trigger(String), replacement(String), insertion(InsertionMode), enabled(Bool) }`
  - `final class EditorViewController: NSViewController, NSTextFieldDelegate, NSTextViewDelegate`
  - `var onEdit: ((ComboEdit) -> Void)?` -- the only way anything leaves the pane; the controller owns
    `file`, `mutate` and `reloadRows`, so the pane needs no reload callback
  - `func display(_ combo: Combo?)`
  - `func showHint(_ text: String, failure: Bool)`
  - `func beginTriggerEdit()` -- focus the trigger field and select its text
  - `func beginTryEdit()` -- focus the "Try it" field and clear it, which is what the self-test buttons do
  - `var tryTextView: NSTextView` -- `ConsistencyTest` needs it
  - `var triggerFieldFrameInWindow: CGRect?` -- the destination rect for `selectionMorph` in Task 11
  - `var triggerFieldProxy: NSView` -- the thin view Task 11 morphs instead of the real field
    *(withdrawn by Ruling AG before it ever shipped; the pane exposes `triggerFieldFrameInWindow` only)*

- [ ] **Step 0: Carry the three follow-ups Task 3's review collected**

These are Task 3's deferred minors, one line each, applied here because this task is already in the same
two files:

1. `SidebarViewController.searchText` and `focusList()` have no consumer anywhere in Plan 3 -- delete both
   (Ruling N). Keep `listTableView`, `selectedRowFrame` and `shownIDs`, which Tasks 11 uses.
2. `clearFilter()` gains a contract comment: it clears the field's text only; the caller owns
   `MainWindowController.filter` and must reset it, because setting `stringValue` programmatically does
   not fire `controlTextDidChange`.
3. `MainWindowController`'s empty-state branch reads `sidebar.listTableView.numberOfRows == 0`, a view
   internal. Replace with `var isEmptyList: Bool { visible.isEmpty }` on the pane.
4. Before the pane closures are wired, call `sidebar.loadViewIfNeeded()` (and `editor.loadViewIfNeeded()`
   for the pane added in this task). The current order works only because `assembleSplitView()` touches
   `splitView.view` first; that is an AppKit internal, not a contract, and Task 5 rewrites that function.

- [ ] **Step 1: Create the pane**

Move `buildDetail`'s body into `loadView()`, `configure`/`caption` as private helpers, and
`loadEditor`/`showHint` as `display`/`showHint`. Every anchor constraint, the 82 pt caption column, the
`safeAreaLayoutGuide` usage and the two `heightAnchor` priorities move verbatim -- those exist because of
`NSStackView`'s `.gravityAreas` drift and must not be "cleaned up" into stack views. Replace the magic
numbers with the Task 2 tokens where they are the same value:

```swift
private let captionColumn: CGFloat = Theme.Spacing.panePadding + Theme.Spacing.captionColumn
private let controlColumn: CGFloat = captionColumn + Theme.Spacing.gutter
```

`hint(for:)` is model logic (it reads the whole library for duplicates and `TriggerIndex` for
rejections), so it stays in the window controller; the editor only renders what it is given.

The commit sites stop mutating the model and post instead:

```swift
func controlTextDidEndEditing(_ notification: Notification) {
    if (notification.object as? NSControl) === triggerField {
        onEdit?(.trigger(triggerField.stringValue))
    }
}

/// "Saves as you type" is the promise the hint makes, so the replacement commits on change rather
/// than on focus loss. It deliberately does not reload the editor: rewriting the string under a
/// caret that is mid-word moves the caret to the end.
func textDidChange(_ notification: Notification) {
    guard (notification.object as? NSTextView) === replacementView else { return }
    onEdit?(.replacement(replacementView.string))
}

func beginTriggerEdit() {
    view.window?.makeFirstResponder(triggerField)
    triggerField.selectText(nil)
}
```

`enabledCheck.state` and `insertionPopUp` actions post `.enabled` / `.insertion` the same way.
`display(_:)` sets `isEnabled` / `isEditable` exactly as `loadEditor()` does today, including the
empty-selection path -- but the message *text* for the three empty cases comes from the controller,
because it depends on `file.combos.isEmpty` and the filter.

- [ ] **Step 2: Rewire the controller**

```swift
editor.onEdit = { [weak self] edit in
    guard let self else { return }
    switch edit {
    case .trigger(let value):
        self.mutate { $0.trigger = value }
        self.reloadRows()
        self.redisplay()
    case .replacement(let text):
        do {
            let parts = try Template.parse(text)
            self.mutate { $0.parts = parts }
            self.reloadRows()
            // Deliberately not `redisplay()`: writing `replacementView.string` back under a caret that
            // is mid-word moves the caret to the end. The hint may refresh -- the pane's own
            // `showHint` is the only view it touches.
            if let combo = self.selected() { self.editor.showHint(self.hint(for: combo), failure: false) }
        } catch {
            self.editor.showHint("Not saved -- \(error)", failure: true)
        }
    case .insertion(let mode):
        self.mutate { $0.insertion = mode }
    case .enabled(let on):
        self.mutate { $0.enabled = on }
        self.reloadRows()
    }
}
```

`redisplay()` is the new name for what `loadEditor()` becomes at the controller level -- it picks
`selected()` and hands the pane both the combo and the hint:

```swift
private func redisplay() {
    let combo = selected()
    editor.display(combo)
    editor.showHint(combo.map(hint(for:)) ?? emptySelectionMessage, failure: false)
}
```

`emptySelectionMessage` reproduces the current three-way branch verbatim (`No combos yet...`,
`Nothing matches «...»`, `Select a combo in the sidebar.`).

ConsistencyTest construction moves after the pane exists:
`ConsistencyTest(coordinator: coordinator, textView: editor.tryTextView)`, and every
`window?.makeFirstResponder(tryView)` / `tryView.string = ""` in the diagnostics actions becomes
`editor.beginTryEdit()` -- a new one-line method on the pane:

```swift
func beginTryEdit() {
    view.window?.makeFirstResponder(tryView)
    tryView.string = ""
}
```

`pathLabel` moves into the pane, and because `store` does not, the pane needs a setter. Split it so the
per-second `refreshStatus()` cannot disturb a tooltip the user is reading: a one-shot
`setPathTooltip(_:)` called from `loadView`-time wiring with `store.url.path`, and
`showPath(short:)` for the `~`-shortened text that `refreshStatus` updates every second -- the latter
writing only when the string actually changed.

`addCombo`'s final two lines become `editor.beginTriggerEdit()`, and the sidebar's double-click path
becomes `sidebar.onRequestEdit = { [weak self] in self?.editor.beginTriggerEdit() }` -- the closure that
called the controller's own `editTriggerFromList()` in Task 3, whose method is deleted here.

The two Task 11 anchors are created in this task so the pane exposes them before anything asks:

```swift
/// The trigger field's frame, in screen coordinates -- where a selection morph lands.
var triggerFieldFrameInWindow: CGRect? {
    guard let window = view.window else { return nil }
    return window.convertToScreen(triggerField.convert(triggerField.bounds, to: nil))
}

/// A 1 pt separator-coloured line laid exactly over the trigger field, **hidden until the morph needs
/// it**. Task 11 morphs this rather than the field itself: re-laying out a real control mid-animation is
/// what moved the caret the last time a morph touched something the user was typing into. It draws
/// nothing while hidden, and its `hitTest` returns nil so it can never eat a click.
var triggerFieldProxy: NSView { triggerProxy }
```

*(Step 2's `triggerProxy` property and this accessor were withdrawn by Ruling AG before they could ship -- the
pane-hosted line was clipped by the split view's wrapper. `SelectionOverlayLineView` in
`MainWindowController`'s window-level overlay carries the same three properties: `separatorColor` fill,
nothing while hidden, `hitTest` nil. See Task 4's callout.)*

- [ ] **Step 3: Compile, test, live check**

```bash
cd "$REPO_ROOT"
swift build 2>&1 | tail -2 && swift test 2>&1 | grep -E "Test Suite 'All tests' failed|with [1-9][0-9]* failures" || echo GREEN
```
Then on the installed build, in this exact order -- the sequence is the one that found the `+` bug:
type in Replacement and confirm `combos.json` changed; rename a trigger and confirm the row renamed in
place instead of spawning a card; `+` then type immediately; delete; run `Self-test`; run
`Run consistency test`. A refused write must still roll back and the hint must still go red.

- [ ] **Step 4: Stop for review** -- changed: `EditorViewController.swift` (new),
`MainWindowController.swift`. No commit.

---

### Task 5: Extract `DiagnosticsViewController` and thin the controller

**Files:**
- Create: `Sources/Unfold/AppShell/DiagnosticsViewController.swift`
- Modify: `Sources/Unfold/AppShell/MainWindowController.swift` -- remove lines
  [267-317](../../../Sources/Unfold/AppShell/MainWindowController.swift) (`buildDiagnostics`,
  `diagnosticsContainer`), 38-39 (`diagnosticsSummary`, `testResult`), 400-423 (`section`,
  `pushButton`, unused `vstack`), 760-766 (the summary string build), 773-862 (commands and diagnostics
  actions stay on the controller as `@objc` methods; only their *buttons* move)

**Interfaces:**
- Consumes: `Theme`, `Glass.wrap` from Task 1.
- Produces:
  - `final class DiagnosticsViewController: NSViewController`
  - `var summary: String { get set }` and `var testResult: String { get set }`
  - `var containerForMotionProbe: NSView` -- the view Task 10 animates to prove motion is geometric

- [ ] **Step 0: Carry what Tasks 3 and 4 left for this one**

1. Delete `vstack(_:spacing:)` -- dead private code, still in `MainWindowController`, on this task's
   removal list.
2. Keep `editor.setPathTooltip(store.url.path)` ahead of the first `refreshStatus()` call. It is the only
   thing that puts the full path in the tooltip, and `refreshStatus()` now never sets it.
3. Add the one regression test Task 4's fix round should have had: after `loadViewIfNeeded()`, assert
   `editor.triggerFieldProxy.isHidden` is true and that the proxy `isDescendant(of: editor.view)`. It is
   reachable through the existing `@testable import Unfold` target with no window and no app launch, and it
   fails for exactly the defect that review found. This raises the suite from 192 to 193; the count is a
   floor to add to, never a cap.
   *(Withdrawn by Ruling AG with the proxy itself -- see Task 4's callout. The equivalent shipped assertion is
   in `SelectionOverlayTests`: the overlay is installed on the window's content view, ships hidden, and is
   unhidden only for the length of its own morph.)*
4. Wire `diagnostics.loadViewIfNeeded()` alongside the sidebar's and editor's, before any assignment to it.

- [ ] **Step 1: Move the pane**

`buildDiagnostics`' body becomes `loadView()`. The buttons keep targeting the window controller, and
they do it through the responder chain with **nil target** -- the same mechanism `AppMenu` already
documents ("Commands are sent with a nil target, so they travel the responder chain"). Reference the
selectors without strings so a rename is a compile error:

```swift
private func pushButton(_ title: String, _ action: Selector) -> NSButton {
    let button = NSButton(title: title, target: nil, action: action)
    button.bezelStyle = .rounded
    button.controlSize = .small
    return button
}

// `MainWindowController`'s diagnostics actions become internal `@objc` methods so the responder
// chain can find them; `#selector` keeps the connection checkable at compile time.
private func buttonRow() -> [NSButton] {
    [pushButton("Run consistency test", #selector(MainWindowController.runConsistencyTest)),
     pushButton("Stress test (40)", #selector(MainWindowController.runStressTest)),
     pushButton("Self-test", #selector(MainWindowController.runSelfTest)),
     pushButton("Idle timeout", #selector(MainWindowController.testIdleTimeout)),
     pushButton("Ctrl-C in Terminal", #selector(MainWindowController.testControlC)),
     pushButton("Motion probe", #selector(MainWindowController.runMotionProbe)),
     pushButton("Restart tap", #selector(MainWindowController.restartTap)),
     pushButton("Relaunch", #selector(MainWindowController.relaunch)),
     pushButton("Reveal app", #selector(MainWindowController.revealApp))]
}
```

`runMotionProbe` does not exist until Task 10, so in **this** task omit that one line and add it in
Task 10 -- do not stub it.

- [ ] **Step 2: Give the controller the pane and keep the strings where they belong**

`refreshStatus()` stops building the diagnostics block itself and hands the strings over:

```swift
diagnostics.summary = "Keystrokes seen \(coordinator.keystrokesSeen)\n"
    + "Tap switched off by macOS \(coordinator.tapDisableObservations)×\n"
    + "Combos \(coordinator.activeCount) live, \(coordinator.inactivePlaceholderCount) need the prompt UI\n"
    + "Last event \(coordinator.lastRouting ?? "none")\n"
    + "Last expansion \(coordinator.lastExpansion.map { "«\($0.replacingOccurrences(of: "\n", with: "⏎"))»" } ?? "--")"
diagnostics.testResult = consistencyTest.summary
```

That `inactivePlaceholderCount` line is Plan 4's rename, not this plan's -- copy it verbatim.

- [ ] **Step 3: Delete the dead helper**

`vstack(_ views:spacing:)`
([MainWindowController.swift:400-406](../../../Sources/Unfold/AppShell/MainWindowController.swift)) has
no caller. Delete it.

- [ ] **Step 4: Verify**

```bash
cd "$REPO_ROOT"
grep -c "" Sources/Unfold/AppShell/MainWindowController.swift
swift build 2>&1 | tail -2 && swift test 2>&1 | grep -E "Test Suite 'All tests' failed|with [1-9][0-9]* failures" || echo GREEN
```
Expected: the controller's line count reported -- **the bar is "the three panes are out", which lands near
568, not "under 300"** (Ruling T: the ~150/<300 numbers were arithmetic that never fitted the plan's own
instruction to keep the model path and the eight diagnostics actions on the controller). Build clean,
`GREEN`. Then on the installed build: open Diagnostics with the stethoscope item and ⌥⌘D, press every
button, confirm the counters still update once a second and the pane still collapses.

- [ ] **Step 5: Commit, then stop for review** (one local commit per the Git rule; never push).

---

### Task 6: One glass container, interactive glass

> **Superseded by Ruling V, decided during execution.** Steps 1 and 2 below are **not** to be done.
> `NSGlassEffectContainerView` is documented to merge *descendant glass effect views*
> (`NSGlassEffectView.h:49-59`), and this app has no site with two of them: the status pill is one
> `NSGlassEffectView` around an image and a label, and the Diagnostics cluster is one
> `NSGlassEffectView` around eight standard rounded buttons whose system material is drawn inside each
> control, not as a descendant glass view. A container over one pane merges nothing, adds an Auto Layout
> level, and performs the header's documented effect 1 -- elevating its descendants' z-order -- which is an
> unverifiable change to a surface nobody has looked at. `Glass.container` and `Glass.statusPill` are
> therefore not produced, and `effectIsInteractive` stays set inside the existing `Glass.wrap`, which is
> where the interactive response this task is meant to deliver already lives. What survives of Task 6:
> **Step 3** (restore the scroll edge) and the verification greps. Open question parked for the live pass,
> not decided blind: whether the Diagnostics cluster needs its `Glass.wrap` at all, since its eight
> buttons are system components that "pick up the material automatically" -- if pixels show two glass
> layers there, the honest fix is removing the wrap, not adding a container. Everything below is kept for
> the record.

**Files:**
- Modify: `Sources/Unfold/Design/Glass.swift` (add the container helper)
- Modify: `Sources/Unfold/AppShell/MainWindowController.swift` (status pill)
- Modify: `Sources/Unfold/AppShell/DiagnosticsViewController.swift` (button cluster)

**Interfaces:**
- Produces: `Glass.container(_ content: NSView, mergingAt spacing: CGFloat = 0) -> NSView` and
  `Glass.statusPill(content: NSView) -> NSView`.

- [ ] **Step 1: Add the container helper**

`NSGlassEffectContainerView` merges nearby descendant glass views and batches them; without it, the
eight diagnostics buttons are eight separate panes, which is the "glass stacked on glass" defect the
review checklist counts.

```swift
extension Glass {
    /// Groups several `wrap`-ed controls so the system merges them into one slab instead of drawing a
    /// separate pane per control, and batches them into one render pass. `spacing` is the proximity at
    /// which merging begins; the documented default of zero batches without distorting unrelated views.
    @MainActor
    static func container(_ content: NSView, mergingAt spacing: CGFloat = 0) -> NSView {
        let container = NSGlassEffectContainerView()
        content.translatesAutoresizingMaskIntoConstraints = false
        container.contentView = content
        container.spacing = spacing
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            content.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            content.topAnchor.constraint(equalTo: container.topAnchor),
            content.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        return container
    }
}
```

- [ ] **Step 2: Wrap the two clusters**

Diagnostics: `Glass.container(Glass.wrap(column, cornerRadius: Theme.Radius.card, padding: 8))`.
Status pill: `item.view = Glass.container(Glass.wrap(stack, cornerRadius: Theme.Radius.pill, padding: 6))`.
Both call sites pass `interactive: true` by default. Read the call site to confirm it is not set to
`false` -- the property defaults off, and the press response exists only because we turn it on. Note the
floor: on macOS 26 the guard cannot fire, so the glass is legitimately static there; this machine is 27,
so the response must be visible in the screenshots, and its absence is a bug rather than an OS version.

- [ ] **Step 3: Restore the scroll edge effect and fix the search field the honest way**

In `SidebarViewController.loadView()`, delete
`sidebarScroll.automaticallyAdjustsContentInsets = false` (leave the property at its default of `true`)
so the system's scroll-edge fade returns where the list meets the filter pill.

Then **check whether the original problem still exists** before touching the field: the line was added
because the magnifier glyph landed on the placeholder text. With the edge effect restored, screenshot
the empty field at the sidebar's 218 pt width and at its 190 pt minimum and look. If the glyph and the
placeholder are clear of each other, stop -- no inset code is needed, and the fix that motivated
disabling the edge effect was the wrong lever. If they still collide, set the inset explicitly and
record the measured number with the result:

```swift
// Measured from the screenshot at the 190 pt minimum width, not guessed.
(searchField.cell as? NSSearchFieldCell)?.searchTextRectInsets = NSEdgeInsets(top: 0, left: 22,
                                                                              bottom: 0, right: 8)
```

- [ ] **Step 4: Verify on pixels**

```bash
cd "$REPO_ROOT" && swift build 2>&1 | tail -2
./Scripts/make-app-bundle.sh && ./Scripts/install-local.sh
```
Then screenshot the toolbar and the Diagnostics pane (`screencapture -l$(...)` on the window id) and
check: the diagnostics buttons read as one merged slab, the pill has the lens response on press, the
list fades where it passes under the filter, and the magnifier does not touch the placeholder.

- [ ] **Step 5: Commit, then stop for review** (one local commit per the Git rule; never push).

---

### Task 7: The contrast table and the colour moves it demands

> **Amended by Ruling X, decided from Task 7's review.** Two things in the code blocks below are wrong and
> were fixed during execution rather than re-litigated afterwards.
> (1) **The declared backing is an upper bound, not the surface the app renders.** The window's root view is
> an `NSVisualEffectView` with `blendingMode = .behindWindow` on a non-opaque window, so *all* content-layer
> text -- not just the pill -- sits on material that samples the desktop. Measuring against
> `windowBackgroundColor` therefore certifies the best case (full reduce-transparency), never the worst.
> The rows stay, the comment says what it is, and Task 12's capture pass owns the real numbers for pane
> text as well as the pill.
> (2) **The 13-row table under-declares the shell.** It omits the Diagnostics section header (which the
> grep gate forces to `labelColor`), the new failure-hint glyph, and the disabled-row slash symbol. Three
> rows are added: `diagnostics.section` (labelColor, 4.5), `editor.hintSymbol` (systemRed, 3.0),
> `row.disabledSymbol` (secondaryLabelColor, 3.0). An instrument whose stated purpose is "one pair per
> labelled element" that skips three of them is the thing this task exists to prevent.


**Files:**
- Create: `Sources/Unfold/Design/Contrast.swift`
- Create: `Tests/UnfoldTests/ContrastTests.swift`
- Modify: the three pane files -- every `secondaryLabelColor` on meaningful text, plus `showHint`

**Interfaces:**
- Produces:
  - `struct ContrastPair { let element: String; let text: NSColor; let backing: NSColor; let floor: Double }`
  - `enum Contrast { static let pairs: [ContrastPair]; static func ratio(foreground:background:appearance:) -> Double; static func failures(in appearance: NSAppearance.Name) -> [String] }`
  - `EditorViewController.showHint(_ text: String, failure: Bool)` -- unchanged signature, now sets the symbol

- [ ] **Step 1: Write the failing test with the measured numbers**

`Tests/UnfoldTests/ContrastTests.swift`:

```swift
import AppKit
import XCTest
@testable import Unfold

/// Measured 2026-10-29 on macOS 27.2, with the label's alpha composited over the backing. Without
/// compositing, `secondaryLabelColor` reports 21:1 -- identical to `labelColor` -- because it is a
/// translucent color and the instrument ignored the alpha. That is the lie this test exists to catch.
final class ContrastTests: XCTestCase {
    func testEveryDeclaredPairMeetsItsFloor() {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            XCTAssertEqual(Contrast.failures(in: appearance), [],
                           "\(appearance.rawValue) must have no under-floor pair")
        }
    }

    /// The regression guard for the measurement itself: these are the values the shell had before
    /// Task 7, and the table must now resolve the offending ones through `labelColor`.
    func testMeasuredBaselineOfTheSemanticColors() {
        XCTAssertEqual(Contrast.ratio(foreground: .labelColor, background: .windowBackgroundColor,
                                      appearance: .aqua), 14.938, accuracy: 0.02)
        XCTAssertEqual(Contrast.ratio(foreground: .secondaryLabelColor,
                                      background: .windowBackgroundColor, appearance: .aqua),
                       3.949, accuracy: 0.02,
                       "secondary label under 4.5:1 in Light is the finding, not a bug in the math")
        XCTAssertEqual(Contrast.ratio(foreground: .secondaryLabelColor,
                                      background: .windowBackgroundColor, appearance: .darkAqua),
                       5.890, accuracy: 0.02)
        XCTAssertEqual(Contrast.ratio(foreground: .systemGreen, background: .windowBackgroundColor,
                                      appearance: .aqua), 2.220, accuracy: 0.02)
    }

    func testTableCoversEveryLabelInTheShell() {
        for element in ["caption.trigger", "caption.replacement", "caption.try", "editor.hint",
                        "diagnostics.summary", "diagnostics.result", "editor.path", "row.preview",
                        "row.trigger", "pill.status", "window.title"] {
            XCTAssertTrue(Contrast.pairs.contains { $0.element == element }, "\(element) is undeclared")
        }
    }

    /// The reason the pill is monochrome while it is working. These two are unusable as Light-mode
    /// glyph colours, so this pins the measurement that forced the decision -- if the system ever ships
    /// a greener green, the test says so instead of the table quietly re-adding it.
    func testGreenAndOrangeCannotClearTheGlyphFloorInLight() {
        let green = Contrast.ratio(foreground: .systemGreen, background: .windowBackgroundColor,
                                   appearance: .aqua)
        let orange = Contrast.ratio(foreground: .systemOrange, background: .windowBackgroundColor,
                                    appearance: .aqua)
        let red = Contrast.ratio(foreground: .systemRed, background: .windowBackgroundColor,
                                 appearance: .aqua)
        XCTAssertLessThan(green, 3.0, "systemGreen at \(green) must not be a Light-mode status glyph")
        XCTAssertLessThan(orange, 3.0, "systemOrange at \(orange) must not be a Light-mode status glyph")
        XCTAssertGreaterThanOrEqual(red, 3.0, "red is the status colour, so it has to clear 3:1")
    }
}
```

- [ ] **Step 2: Run it to verify it fails**

```bash
cd "$REPO_ROOT"
swift test --filter ContrastTests 2>&1 | grep -E "error|failed" | head -3
```
Expected: unresolved `Contrast`.

- [ ] **Step 3: Write the table and the math**

`Sources/Unfold/Design/Contrast.swift`:

```swift
import AppKit

/// One pair per labelled element in the shell, and the WCAG math that reads them.
///
/// Meaningful text is floored at 4.5:1 up to 17 pt. That floor is why the captions, the hint line, the
/// counters, the path label and the row preview are `labelColor` and not the `secondaryLabelColor`
/// they used to be: secondary label over a light window background measures 3.95:1, so the colour step
/// that was carrying hierarchy was carrying it below legibility. Hierarchy now comes from 11 pt
/// against 13 pt and weight against weight (`typography.md`, `color.md`).
///
/// A pair's backing is the *opaque* material base, which is the honest approximation for content-layer
/// text. Text on glass samples whatever is behind the window and cannot be computed here; the pill is
/// covered by a screenshot pass in Task 12 instead, and its label is monochrome `labelColor` for the
/// same reason.
struct ContrastPair {
    let element: String
    let text: NSColor
    let backing: NSColor
    /// 4.5 for text, 3.0 for a glyph or large text.
    let floor: Double
}

enum Contrast {
    static let pairs: [ContrastPair] = [
        .init(element: "window.title", text: .labelColor, backing: .windowBackgroundColor, floor: 4.5),
        .init(element: "caption.trigger", text: .labelColor, backing: .windowBackgroundColor, floor: 4.5),
        .init(element: "caption.replacement", text: .labelColor, backing: .windowBackgroundColor, floor: 4.5),
        .init(element: "caption.try", text: .labelColor, backing: .windowBackgroundColor, floor: 4.5),
        .init(element: "editor.hint", text: .labelColor, backing: .windowBackgroundColor, floor: 4.5),
        .init(element: "diagnostics.summary", text: .labelColor, backing: .windowBackgroundColor, floor: 4.5),
        .init(element: "diagnostics.result", text: .labelColor, backing: .windowBackgroundColor, floor: 4.5),
        .init(element: "editor.path", text: .labelColor, backing: .windowBackgroundColor, floor: 4.5),
        .init(element: "row.trigger", text: .labelColor, backing: .windowBackgroundColor, floor: 4.5),
        .init(element: "row.preview", text: .labelColor, backing: .windowBackgroundColor, floor: 4.5),
        .init(element: "pill.status", text: .labelColor, backing: .windowBackgroundColor, floor: 4.5),
        // The status glyph is the one coloured element in the control layer, and red is the only
        // semantic status colour that clears the 3:1 graphic floor in both appearances -- measured,
        // systemGreen is 2.22:1 and systemOrange 2.31:1 in Light. Task 12 therefore renders the
        // working and paused states in `labelColor` and colours only the broken ones.
        .init(element: "pill.statusSymbol", text: .systemRed, backing: .windowBackgroundColor, floor: 3.0),
        // The one place contrast is deliberately lowered: "disabled" is the message, and the slash
        // symbol plus the tooltip say it without colour.
        .init(element: "row.triggerDisabled", text: .secondaryLabelColor,
              backing: .windowBackgroundColor, floor: 3.0),
    ]

    static func ratio(foreground: NSColor, background: NSColor,
                      appearance: NSAppearance.Name) -> Double {
        guard let named = NSAppearance(named: appearance),
              let f = resolve(foreground, in: named), let b = resolve(background, in: named) else {
            return -1
        }
        let l1 = luminance(composite(f, b)), l2 = luminance((b.r, b.g, b.b))
        return (max(l1, l2) + 0.05) / (min(l1, l2) + 0.05)
    }

    static func failures(in appearance: NSAppearance.Name) -> [String] {
        pairs.filter { ratio(foreground: $0.text, background: $0.backing, appearance: appearance) < $0.floor }
             .map { "\($0.element) = \(String(format: "%.2f", ratio(foreground: $0.text, background: $0.backing, appearance: appearance))):1 under \($0.floor)" }
    }

    /// A semantic color must be resolved *inside* the appearance it is being measured against, or
    /// `usingColorSpace` hands back whatever the process default says.
    private static func resolve(_ color: NSColor, in appearance: NSAppearance)
        -> (r: Double, g: Double, b: Double, a: Double)? {
        var out: (Double, Double, Double, Double)?
        appearance.performAsCurrentDrawingAppearance {
            guard let c = color.usingColorSpace(.sRGB) else { return }
            out = (Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent),
                   Double(c.alphaComponent))
        }
        guard let o = out else { return nil }
        return (o.0, o.1, o.2, o.3)
    }

    /// Label colors are translucent, so the backing must be composited before any luminance is taken.
    private static func composite(_ f: (r: Double, g: Double, b: Double, a: Double),
                                  _ b: (r: Double, g: Double, b: Double, a: Double))
        -> (Double, Double, Double) {
        (f.a * f.r + (1 - f.a) * b.r, f.a * f.g + (1 - f.a) * b.g, f.a * f.b + (1 - f.a) * b.b)
    }

    private static func luminance(_ t: (Double, Double, Double)) -> Double {
        func channel(_ c: Double) -> Double { c <= 0.03928 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * channel(t.0) + 0.7152 * channel(t.1) + 0.0722 * channel(t.2)
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

```bash
cd "$REPO_ROOT"
swift test --filter ContrastTests 2>&1 | grep -E "Executed|failed|under"
```
Expected: 4 tests, 0 failures. The `pill.statusSymbol` row is `systemRed`, not `systemGreen`: this is the
test that caught it, run before the table was written -- with green in the table,
`testEveryDeclaredPairMeetsItsFloor` failed on `["pill.statusSymbol = 2.22:1 under 3.0"]` in Aqua. If the
test now reports `row.triggerDisabled`, the floor for the disabled case is wrong, not the colour -- keep
it at 3.0 and note that it measures 3.95 (aqua) and 5.89 (dark).

- [ ] **Step 5: Apply the table to the shell**

In the three panes, replace the colour assignments so they read from the table's decisions:

- `caption(_:)` in `EditorViewController`: `textColor = .labelColor`, font
  `Theme.Font.caption`, alignment `.right` unchanged.
- `editorHint`: `.labelColor`; it stays `wrappingLabelWithString` and 2 lines max.
- `diagnosticsSummary`, `testResult` in `DiagnosticsViewController`: `.labelColor`.
- `pathLabel`: `.labelColor`.
- `ComboRowView.apply(_:)`: `previewLabel.textColor = .labelColor`;
  `triggerLabel.textColor = combo.enabled ? .labelColor : .secondaryLabelColor`; the disabled symbol
  keeps `.secondaryLabelColor`.
- `showHint(_:failure:)` in `EditorViewController` -- the red stops being the sole carrier. Give the hint
  a leading symbol and colour only that:

```swift
/// A failure hint is label-colour text with a red glyph, not red text: `systemRed` at 11 pt over a
/// light window background is 3.57:1, under the floor for meaningful text. The sentence carries the
/// meaning; the glyph is emphasis.
private let hintSymbol = NSImageView()

func showHint(_ text: String, failure: Bool) {
    editorHint.stringValue = text
    editorHint.textColor = .labelColor
    hintSymbol.isHidden = !failure
    hintSymbol.contentTintColor = .systemRed
    hintSymbol.image = failure
        ? NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Not saved")
        : nil
}
```

Add `hintSymbol` to the container to the left of `editorHint` and give it the same leading anchor the
hint had (`guide.leadingAnchor, constant: controlColumn`), shifting `editorHint`'s leading to the
symbol's trailing. Both are added to the `views` array that the moved `buildDetail` already activates
constraints for. The controller's own callers keep working because `showHint(_:failure:)` is the name it
already uses after Task 4 -- there is no `red:`-labelled variant left to update.

- [ ] **Step 6: Verify**

```bash
cd "$REPO_ROOT"
grep -rn "secondaryLabelColor" Sources/Unfold/ | grep -v row.triggerDisabled
swift test 2>&1 | grep -E "Test Suite 'All tests' failed|with [1-9][0-9]* failures" || echo GREEN
```
Expected: the only `secondaryLabelColor` left in the shell is the disabled-row case and its symbol, and
the suite is green with the new tests included (note the new total). Then read every caption in Light
mode on the installed build -- the hierarchy should still be obvious at 11 pt against 13 pt.

- [ ] **Step 7: Commit, then stop for review** (one local commit per the Git rule; never push).

---

### Task 8: `MotionPlan` -- the transitions as data

> **Amended by Ruling AC #1, restated by the final review (Ruling AJ10).** `Curve` shipped with **one** spring
> knob -- `case spring(damping: Double)` -- so every `.spring(damping: 0.85, response: ...)` in the snippets below
> (the exactness table at item 1, the `Curve` declaration, the `MotionPlan.all` rows and the spring-band test
> that reads `let response` out of the curve) is withdrawn, and the doc comment's "`damping` 0.85 gives roughly
> a 5% overshoot" is wrong: measured at ζ = 0.85 the overshoot is **0.63%** of the step, and 5% needs ζ ≈ 0.69,
> which cannot settle inside the 150-320 ms band. The transition *duration* is the settle time and the driver
> derives the stiffness that makes `CASpringAnimation.settlingDuration` land on it. See Task 10's callout and
> `MotionDriverTests.testEverySpringSettlesInsideItsOwnDuration`.

> **Amendment (Ruling Z), decided from Task 8/9's review.** The review found that the test code specified
> below is weak in four ways, and it is the plan's code being wrong, not the pass's. Apply these
> replacements to `MotionPlanTests.swift` as part of Task 8:
>
> 1. **Pin the contract exactly, per id.** The `0.15-0.32` band cannot catch the realistic mistake
>    (`0.26 ↔ 0.28` transposed between `rowInsert` and `paneReveal`), and both curve loops are `if case`
>    filters, so swapping `rowInsert` from `.spring` to `.easeOut` passes. Add:
>
>    ```swift
>    /// The contract as an exact table, because a band this wide passes any plausible transposition of the
>    /// real numbers and the id-to-curve-kind mapping is otherwise unpinned.
>    func testEachTransitionIsExactlyAsSpecified() {
>        let expected: [TransitionID: (duration: Double, curve: Curve, ramp: Double)] = [
>            .rowInsert: (0.26, .spring(damping: 0.85, response: 0.28), 0.2),
>            .rowRemove: (0.22, .easeOut(0.33, 1, 0.68, 1), 0.2),
>            .selectionMorph: (0.20, .easeOut(0.33, 1, 0.68, 1), 0.2),
>            .paneReveal: (0.28, .spring(damping: 0.85, response: 0.30), 0.2),
>            .statusMorph: (0.24, .easeOut(0.33, 1, 0.68, 1), 0.2),
>            .promptPresent: (0.22, .spring(damping: 0.85, response: 0.26), 0.2),
>            .promptDismiss: (0.18, .easeOut(0.33, 1, 0.68, 1), 0.2),
>        ]
>        XCTAssertEqual(Set(MotionPlan.all.map(\.id)), Set(TransitionID.allCases),
>                       "the table and the enum have drifted apart")
>        for t in MotionPlan.all {
>            let e = expected[t.id]
>            XCTAssertEqual(t.duration, e.duration, accuracy: 0.0001, "\(t.id) duration")
>            XCTAssertEqual(t.curve, e.curve, "\(t.id) curve")
>            XCTAssertEqual(t.opacityRamp, e.ramp, accuracy: 0.0001, "\(t.id) ramp")
>        }
>    }
>    ```
>    Keep the band tests as the coarse guard; `Curve` already conforms to `Equatable` and the exact table is
>    what uses it.
>
> 2. **Assert the property, not the proxy.** `x1 >= 0.30` excludes `cubic-bezier(0.22, 1, 0.36, 1)` only
>    because that curve happened to have a small first x; the complaint was about *progress by 45 ms*, which
>    is set by the y control points the band test discards as `_`. Add a test-local evaluator (a
>    `CAMediaTimingFunction` is AppKit/QuartzCore and this file must stay Foundation-only) and bound the
>    sampled progress:
>
>    ```swift
>    /// A cubic timing function maps time-progress to value-progress through a parameter, so the value at a
>    /// given time is found by solving x(t)=time for t. Bisection is enough: the x curve is monotonic for
>    /// control points inside [0, 1].
>    private func progress(of curve: (Double, Double, Double, Double), atTime time: Double) -> Double {
>        let (x1, y1, x2, y2) = curve
>        func axis(_ a: Double, _ b: Double, _ t: Double) -> Double {
>            3 * (1 - t) * (1 - t) * t * a + 3 * (1 - t) * t * t * b + t * t * t
>        }
>        var low = 0.0, high = 1.0, mid = 0.5
>        for _ in 0..<40 {
>            mid = (low + high) / 2
>            if axis(x1, x2, mid) < time { low = mid } else { high = mid }
>        }
>        return axis(y1, y2, mid)
>    }
>
>    /// "It looked like nothing" is a statement about how much of the change is spent early, so the guard is
>    /// the sampled property rather than the control points: at 45 ms into any transition in this plan, no
>    /// more than half the change may be gone. The curve that failed before was at ~76% by then.
>    func testNoCurveSpendsHalfItsChangeInFortyFiveMilliseconds() {
>        for t in MotionPlan.all {
>            guard case .easeOut(let x1, let y1, let x2, let y2) = t.curve else { continue }
>            for (label, value) in [("x1", x1), ("y1", y1), ("x2", x2), ("y2", y2)] {
>                XCTAssertGreaterThanOrEqual(value, 0, "\(t.id) \(label) below 0")
>                XCTAssertLessThanOrEqual(value, 1, "\(t.id) \(label) above 1")
>            }
>            let at45 = min(1, 0.045 / t.duration)
>            let spent = progress(of: (x1, y1, x2, y2), atTime: at45)
>            XCTAssertLessThanOrEqual(spent, 0.5,
>                "\(t.id) is \(String(format: "%.0f%%", spent * 100)) done by 45ms")
>        }
>    }
>    ```
>
> 3. **`testEveryTransitionMovesGeometry` currently contains no assertion** -- it works once (a new `.fade`
>    case makes the exhaustive switch a compile error) and then degrades silently if anyone adds
>    `default:`. Keep the switch as the compile-time guard and give it real teeth:
>
>    ```swift
>    let allowed: Set<String> = ["scaleFromGap", "collapseToGap", "growFromEdge",
>                                "positionCrossfade", "symbolMorph"]
>    for t in MotionPlan.all {
>        XCTAssertFalse(String(describing: t.geometry).contains("fade"), "\(t.id)")
>        XCTAssertTrue(allowed.contains(String(describing: t.geometry)), "\(t.id) \(t.geometry)")
>    }
>    ```
>
> 4. **`opacityRamp` is a door left open.** Nothing reads it yet and nothing bounds it, so a future fade is
>    expressible without adding a `Geometry` case: set the ramp near 1.0 and let the driver do the work. Add
>    `XCTAssert(t.opacityRamp > 0 && t.opacityRamp <= 0.25)` to the exactness table's loop, and state in the
>    `Transition` doc that the ramp only ever *starts* slightly transparent, never carries the motion.
>
> 5. Name the lookup `lookup(_:)` everywhere, including the Interfaces line, since Tasks 10 and 11 call it.
> 6. One line of doc on the seam: durations and curve parameters are `Double`, geometry is `CGFloat`, and
>    the driver (Task 10) owns the conversion.
> 7. **Item 2's ceiling is corrected by Ruling AA: `0.6`, not `0.5`** -- and three more numbers in this
>    amendment were wrong when written, all caught by the pass rather than bent:
>    - sampled progress at an absolute 45 ms is **53.4%** for `selectionMorph` (0.20 s) and **57.7%** for
>      `promptDismiss` (0.18 s) on the *approved* curves, because a fixed time is a bigger fraction of a
>      shorter transition; the curve that actually failed sat at **64.7-76.5%**. So the net has ~7 points of
>      separation and the per-id exactness table in item 1 is the primary guard -- say that in the comment.
>    - the x-axis case's expected `translation.width` is **−115**, not −70 (`midX 135 − 250`), which the
>      shipped test already carries.
>    - `String(describing:)` on `.positionCrossfade` **contains** the substring "fade", so item 3's
>      `contains("fade")` fails three legitimate cases; compare with `== "fade"` instead, as shipped.
>    - the prescribed mutation "`y1` → 0.2" *slows* the curve (49.7% → ~19%) and cannot fail a
>      too-fast-progress guard. The mutation that proves the guard is a front-loaded
>      `.easeOut(0.30, 1, 0.32, 1)`, which measures 62% at 45 ms.
>    - `expected[t.id]` on a dictionary is optional, so the table needed `guard let` to compile.


**Files:**
- Create: `Sources/Unfold/Design/MotionPlan.swift`
- Create: `Tests/UnfoldTests/MotionPlanTests.swift`

**Interfaces:**
- Produces: `enum TransitionID`, `enum Curve`, `enum Geometry`, `struct Transition`, `enum MotionPlan { static let all: [Transition]; static func lookup(_ id: TransitionID) -> Transition? }` -- `lookup`, not `transition(_:)`, which is what Tasks 10 and 11 call.
- Consumed by: Task 9 (geometry), Task 10 (driver), Task 11 (wiring). `MotionPlan` imports Foundation only -- no AppKit -- which is what makes it testable the way `MenuStatus` is.

- [ ] **Step 1: Write the failing tests**

`Tests/UnfoldTests/MotionPlanTests.swift`:

```swift
import XCTest
@testable import Unfold

/// The motion contract as data. Every rule corrected in review is an assertion here, so a
/// regression is a failing test rather than "i cant tell if anything animated".
final class MotionPlanTests: XCTestCase {
    private let required: [TransitionID] = [.rowInsert, .rowRemove, .selectionMorph, .paneReveal,
                                            .statusMorph, .promptPresent, .promptDismiss]

    func testEveryNamedTransitionExists() {
        for id in required { XCTAssertNotNil(MotionPlan.lookup(id), "\(id) is missing") }
        XCTAssertEqual(MotionPlan.all.count, required.count, "an undeclared transition slipped in")
    }

    func testDurationsStayInThePerceivedBand() {
        for t in MotionPlan.all {
            XCTAssertGreaterThanOrEqual(t.duration, 0.15, "\(t.id) is too fast to perceive")
            XCTAssertLessThanOrEqual(t.duration, 0.32, "\(t.id) makes people wait")
        }
    }

    /// The curve that failed before spent 76% of its change by 45 ms and read as nothing. A control
    /// point below 0.30 on the first x is the shape of that failure.
    func testNoCurveIsFrontLoadedPastTheApprovedShape() {
        for t in MotionPlan.all {
            if case .easeOut(let x1, _, let x2, _) = t.curve {
                XCTAssertGreaterThanOrEqual(x1, 0.30, "\(t.id) starts too steeply")
                XCTAssertLessThanOrEqual(x2, 0.75, "\(t.id) ends too steeply")
            }
        }
    }

    /// Opacity-only transitions are what got reported as "there is no animation". The enum cannot
    /// express an opacity-only geometry, so this guards the enum itself from a future `.fade`.
    func testEveryTransitionMovesGeometry() {
        for t in MotionPlan.all {
            switch t.geometry {
            case .scaleFromGap, .collapseToGap, .growFromEdge, .positionCrossfade, .symbolMorph:
                break
            }
        }
    }

    func testSpringsAreDampedEnoughToSettleWithoutBouncing() {
        for t in MotionPlan.all {
            if case .spring(let damping, let response) = t.curve {
                XCTAssertGreaterThan(damping, 0.7, "\(t.id) overshoots")
                XCTAssertLessThanOrEqual(damping, 1.0, "\(t.id) overshoots")
                XCTAssertGreaterThan(response, 0.15, "\(t.id)")
                XCTAssertLessThan(response, 0.6, "\(t.id)")
            }
        }
    }
}
```

- [ ] **Step 2: Verify they fail**

```bash
cd "$REPO_ROOT"
swift test --filter MotionPlanTests 2>&1 | grep -E "error:|failed" | head -3
```
Expected: unresolved `MotionPlan`.

- [ ] **Step 3: Write the plan**

`Sources/Unfold/Design/MotionPlan.swift` -- Foundation only, deliberately:

```swift
import Foundation

/// Which transition, with what timing, moving what.
enum TransitionID: String, CaseIterable {
    case rowInsert, rowRemove, selectionMorph, paneReveal, statusMorph
    case promptPresent, promptDismiss
}

enum Curve: Equatable {
    /// `damping` 0.85 gives roughly a 5% overshoot; `response` is the SwiftUI-style settle time in
    /// seconds, mapped onto `CASpringAnimation`'s stiffness/mass by `Motion`.
    case spring(damping: Double, response: Double)
    /// Four control points. The approved shape is (0.33, 1, 0.68, 1).
    case easeOut(Double, Double, Double, Double)
}

/// The kinds of motion the shell can express. There is no `.fade` member: opacity is an anti-flash
/// ramp inside a geometric transition, never a transition, and a type that cannot say "fade only" is
/// how that stays true.
enum Geometry {
    case scaleFromGap      // a row unfolds out of the gap it is opening
    case collapseToGap     // a row shrinks into the gap it is closing
    case growFromEdge      // a pane grows from the divider side
    case positionCrossfade // shared element from one rect to another
    case symbolMorph       // SF Symbol replacement plus a width change
}

struct Transition: Equatable {
    let id: TransitionID
    let duration: Double
    let curve: Curve
    let geometry: Geometry
    /// The anti-flash ramp, as a fraction of the timeline. Kept at 0.2 so opacity never carries motion.
    let opacityRamp: Double
}

enum MotionPlan {
    static let all: [Transition] = [
        .init(id: .rowInsert, duration: 0.26, curve: .spring(damping: 0.85, response: 0.28),
              geometry: .scaleFromGap, opacityRamp: 0.2),
        .init(id: .rowRemove, duration: 0.22, curve: .easeOut(0.33, 1, 0.68, 1),
              geometry: .collapseToGap, opacityRamp: 0.2),
        .init(id: .selectionMorph, duration: 0.20, curve: .easeOut(0.33, 1, 0.68, 1),
              geometry: .positionCrossfade, opacityRamp: 0.2),
        .init(id: .paneReveal, duration: 0.28, curve: .spring(damping: 0.85, response: 0.30),
              geometry: .growFromEdge, opacityRamp: 0.2),
        .init(id: .statusMorph, duration: 0.24, curve: .easeOut(0.33, 1, 0.68, 1),
              geometry: .symbolMorph, opacityRamp: 0.2),
        .init(id: .promptPresent, duration: 0.22, curve: .spring(damping: 0.85, response: 0.26),
              geometry: .positionCrossfade, opacityRamp: 0.2),
        .init(id: .promptDismiss, duration: 0.18, curve: .easeOut(0.33, 1, 0.68, 1),
              geometry: .positionCrossfade, opacityRamp: 0.2),
    ]

    /// `promptPresent` and `promptDismiss` are declared here and wired in Plan 4, whose prompt panel is
    /// the only thing that uses them. They belong to the plan now so the table is the complete contract
    /// and Task 11's assertions do not have to be edited later.
    static func lookup(_ id: TransitionID) -> Transition? {
        all.first { $0.id == id }
    }
}
```

- [ ] **Step 4: Run and verify**

```bash
cd "$REPO_ROOT"
swift test --filter MotionPlanTests 2>&1 | grep -E "Executed|failed"
```
Expected: 5 tests, 0 failures. `promptPresent` at 0.22 and `promptDismiss` at 0.18 are inside the band;
if the band test fails, the duration is wrong, not the band.

- [ ] **Step 5: Commit, then stop for review** (one local commit per the Git rule; never push).

---

### Task 9: `MotionGeometry` -- the morph math, both coordinate spaces

> **Amendment (Ruling Z, continued).** The review found the x axis is dead under test: every rect in the
> specified cases uses `x: 100, width: 300` for both source and target, so `translation.width` is always 0
> and `scale.width` always 1 -- an implementation that hard-codes both passes all five tests. `paneReveal`
> and `statusMorph` are exactly the transitions whose horizontal component Task 10 will trust. Apply these
> changes with Task 9:
>
> 1. **Cover the x axis with a real ratio.** Add, alongside the existing cases:
>
>    ```swift
>    func testHorizontalAxisIsNotAssumedIdentity() {
>        let wide = CGRect(x: 100, y: 200, width: 300, height: 40)
>        let narrowLeft = CGRect(x: 60, y: 200, width: 150, height: 40)
>        for flipped in [false, true] {
>            let morph = MotionGeometry.morph(source: narrowLeft, final: wide, flipped: flipped)
>            XCTAssertEqual(morph.scale.width, 0.5, "flipped=\(flipped)")
>            XCTAssertEqual(morph.translation.width, -70, "flipped=\(flipped)")
>            XCTAssertEqual(morph.translation.height, 0, "flipped=\(flipped)")
>        }
>    }
>    ```
>    and rename `testScaleIsSourceOverTargetInBothAxes` to something that does not promise the axis it was
>    only sampling at a degenerate ratio (`testHeightRatioFollowsSourceOverTarget`).
>
> 2. **`testEmptyTargetIsRefusedWithIdentity` asserts only `scale`** -- a guard returning identity scale with
>    a garbage translation passes. Assert the whole value: `XCTAssertEqual(morph, .identity)`, which also
>    makes `MorphTransform.identity` read by a test rather than only inside production.
>
> 3. **Delete the unreachable `isFinite` branch in `clamp`.** With `final.width > 0, final.height > 0`
>    already guarded, a division cannot produce a non-finite value from real rects; the branch is dead code
>    that the review correctly says is untestable. Leave the clamp itself (`max(minimumScale,
>    min(value, 1 / minimumScale))`) and add `XCTAssertEqual(MotionGeometry.minimumScale, 0.02)`, since the
>    current clamp test's `< 0.05` window would accept 0.04.
>
> 4. One line of doc on the seam: this file is `CGFloat` throughout and `MotionPlan` is `Double`; Task 10's
>    driver owns the conversion.

> **Amended by Ruling AE, decided from Task 10's measurement.** Three things this task specifies are not what
> shipped, and one number in the amendment above is wrong.
> (1) **There is no `flipped:` parameter.** `MotionGeometry.morph(source:final:)` takes two rects and nothing
> else (the interface, the test cases and the implementation below all still spell the third argument). Task 10
> measured the claim the parameter rested on and found it backwards: AppKit mirrors a view's flippedness into
> its layer tree (`isGeometryFlipped` tracks `isFlipped`), the morphing layer's resting `frame` equals the
> view's `frame` in **both** orientations, and so a `transform` translation already runs along the axis the
> rects are written on. Negating `dy` for a flipped container started the pose 20 pt on the far side of the
> resting frame -- the row slid in from below the gap instead of out of it. `MotionDriverTests`
> `.testAFlippedContainerMovesTheSameWayItsOwnCoordinatesSay` is the measurement, and it fails if the ternary
> comes back in either direction.
> (2) **The sign expectations below are the ones that were wrong**, so
> `testASourceAboveTheTargetPushesOppositeWaysInEachSpace` became
> `testTheYOffsetIsTheRectGapAsGiven`: a source at a numerically larger `y` is `+60` and one at a numerically
> smaller `y` is `-60`, in either orientation. Step 4's "if the flipped/unflipped sign test fails the ternary
> is backwards -- fix the math" was right about the diagnosis and wrong about which math.
> (3) **`-70` in the amendment's own snippet above is an arithmetic error.** `narrowLeft.midX` is 135 and
> `wide.midX` is 250, so `translation.width` is **-115**, which is what the shipped test asserts. Ruling Z's
> point -- cover x with a real ratio -- stands; its number did not.
> (4) Ruling D, from the same round, is why the driver never converts either: `view.frame` *is* the rect in the
> superlayer's space, so `MotionGeometry`'s output needs only the layer's anchor term (Ruling AE's second
> half) and no coordinate handling at all.


**Files:**
- Create: `Sources/Unfold/Design/MotionGeometry.swift`
- Create: `Tests/UnfoldTests/MotionGeometryTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `struct MorphTransform { let scale: CGSize; let translation: CGSize }`,
  `MotionGeometry.morph(source: CGRect, final: CGRect, flipped: Bool) -> MorphTransform`,
  `MorphTransform.transform3D(atProgress: Double) -> CATransform3D` lives in Task 10, not here -- this
  type stays Core Animation-free.

The reason this is a separate pure file: under a layer-backed `NSView`, `layer.transform` translates in
the **superlayer's** space, whose y direction depends on whether the enclosing view is flipped --
`NSTableView`'s row views are. Getting that sign wrong is an animation that moves the wrong way and
looks like a bug in the curve, so it is proven here first.

- [ ] **Step 1: Write the failing tests**

```swift
import XCTest
@testable import Unfold

/// AppKit hands a layer-backed view a coordinate space whose y direction depends on the enclosing
/// view's flippedness. NSTableRowView is flipped; a plain container is not. One sign error and every
/// morph moves the wrong way, which reads as bad easing rather than bad math.
final class MotionGeometryTests: XCTestCase {
    private let final = CGRect(x: 100, y: 200, width: 300, height: 40)

    func testIdenticalRectsGiveIdentity() {
        let morph = MotionGeometry.morph(source: final, final: final, flipped: false)
        XCTAssertEqual(morph.scale, CGSize(width: 1, height: 1))
        XCTAssertEqual(morph.translation, .zero)
    }

    func testASourceAboveTheTargetPushesOppositeWaysInEachSpace() {
        let above = CGRect(x: 100, y: 260, width: 300, height: 40)
        XCTAssertEqual(MotionGeometry.morph(source: above, final: final, flipped: false).translation.height,
                       60, "unflipped: +y is up, so a source above is a positive offset")
        XCTAssertEqual(MotionGeometry.morph(source: above, final: final, flipped: true).translation.height,
                       -60, "flipped: +y is down, so the same source needs the opposite sign")
    }

    func testScaleIsSourceOverTargetInBothAxes() {
        let halfHeight = CGRect(x: 100, y: 220, width: 300, height: 20)
        XCTAssertEqual(MotionGeometry.morph(source: halfHeight, final: final, flipped: true).scale,
                       CGSize(width: 1, height: 0.5))
    }

    /// A zero-height gap is what `scaleFromGap` starts from. A literal 0 scale collapses the layer to
    /// nothing and the transform degenerates, so it is clamped and the caller fades in across the ramp.
    func testZeroSourcedDimensionsAreClampedNotZero() {
        let gap = CGRect(x: 100, y: 220, width: 300, height: 0)
        let morph = MotionGeometry.morph(source: gap, final: final, flipped: true)
        XCTAssertGreaterThan(morph.scale.height, 0)
        XCTAssertLessThan(morph.scale.height, 0.05)
        XCTAssertEqual(morph.scale.width, 1)
    }

    func testEmptyTargetIsRefusedWithIdentity() {
        let morph = MotionGeometry.morph(source: final, final: .zero, flipped: false)
        XCTAssertEqual(morph.scale, CGSize(width: 1, height: 1), "no scale can be derived from zero")
    }
}
```

- [ ] **Step 2: Verify they fail**

```bash
cd "$REPO_ROOT"
swift test --filter MotionGeometryTests 2>&1 | grep -E "error:|failed" | head -3
```
Expected: unresolved `MotionGeometry`.

- [ ] **Step 3: Write it**

```swift
import Foundation

/// Scale and offset for a morph between two rects, expressed in the layer's own space so the driver
/// needs no coordinate conversion.
struct MorphTransform: Equatable {
    static let identity = MorphTransform(scale: CGSize(width: 1, height: 1), translation: .zero)
    let scale: CGSize
    let translation: CGSize
}

enum MotionGeometry {
    /// The smallest scale a morph may start from. Zero makes the transform degenerate and the layer
    /// unpaintable, which is the difference between "grows out of the gap" and "flashes".
    static let minimumScale: CGFloat = 0.02

    /// `source` and `final` must be in the same coordinate space. `flipped` is the enclosing view's
    /// `isFlipped`, which decides the sign of the y offset.
    static func morph(source: CGRect, final: CGRect, flipped: Bool) -> MorphTransform {
        guard final.width > 0, final.height > 0 else { return .identity }
        let scale = CGSize(width: clamp(source.width / final.width),
                           height: clamp(source.height / final.height))
        let dy = source.midY - final.midY
        return MorphTransform(
            scale: scale,
            translation: CGSize(width: source.midX - final.midX, height: flipped ? -dy : dy)
        )
    }

    private static func clamp(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 1 }
        return max(minimumScale, min(value, 1 / minimumScale))
    }
}
```

- [ ] **Step 4: Run and verify**

```bash
cd "$REPO_ROOT"
swift test --filter MotionGeometryTests 2>&1 | grep -E "Executed|failed"
```
Expected: 5 tests, 0 failures. If the flipped/unflipped sign test fails, the ternary is backwards -- fix
the math, do not adjust the expectation.

- [ ] **Step 5: Commit, then stop for review** (one local commit per the Git rule; never push).

---

### Task 10: `Motion` -- the only Core Animation in the shell, and the probe that measures it

> **Amendment (Ruling AC), decided from Task 10's review -- four defects, three introduced by the task itself.**
> 1. **A spring cannot have two clocks.** `Curve.spring(damping:response:)` set stiffness from `response`
>    (`k = 4/response²`) while `Motion` clipped the animation to `transition.duration`. With `damping 0.85`
>    and `response 0.28` the settling time is ≈ **0.66 s** against a 0.26 s duration, so every spring ended
>    with a ~17 pt pop -- which the first driver test then asserted as correct. **Removed: `response`.**
>    `Curve.spring(damping:)` only; the driver derives stiffness so that `settlingDuration ≈ duration`,
>    because the perceived 150-320 ms band is the contract and a spring that cannot settle inside it is not
>    usable. Update Task 8's exactness table and spring-band test to match; assert
>    `spring.settlingDuration <= duration + 0.01` where the data is checked, not where it is used.
> 2. **An interrupted morph killed its interruption.** `removeAnimation(forKey:)` left the *previous*
>    `CATransaction` completion armed, and when Core Animation retired it, it removed whatever animation now
>    held that key and fired the old `completion?()`. Guard by identity: remove and call completion only if
>    `layer.animation(forKey:) === self.animation`. Pressing **Motion probe** twice is now safe, which is why
>    the live check for it can be retired from the list.
> 3. **`flipped` was read from the wrong view.** `view.frame` -- the `final` handed to `MotionGeometry` -- is
>    expressed in the **immediate superview's** space, so the input is `view.superview?.isFlipped ?? false`.
>    The `enclosingScrollView?.documentView` branch picked a different space entirely and was dead code for
>    the only host ever probed (the diagnostics cluster sits in a glass view inside a plain split item, with
>    no scroll view). The sign for a flipped container is still **unmeasured**, so Task 10 must add one
>    flipped fixture (`NSScrollView` with a flipped `documentView`, or an `NSTableRowView`) and assert the
>    **sign** of `ty`; if the measurement says `MotionGeometry`'s ternary is backwards, the fix belongs in
>    `MotionGeometry`, not in the driver's guess.
> 4. **The driver test could still skip on a broken animation.** `presentation()` is nil when nothing is in
>    flight, so "attaches nothing" landed in `XCTSkip`. Assert immediately after the morph that the layer
>    actually carries the `unfold.morph` key, so a skip can only mean "attached, but no render cycle".
>
> Also ruled as **carried, not fixed here**: the probe measures the same zero-height-below-the-rect geometry
> for all five transitions, so `.growFromEdge`'s horizontal shape is never exercised and `Motion.morph` reads
> no `geometry` at all (Ruling C's consequence) -- Task 11 gives each transition its own real source rect, and
> that is where the coverage arrives. `preparedLayer` setting `wantsLayer` as a side effect of animating, and
> the test window being ordered out rather than closed, are deferred to the final review.

> **Amended by Rulings AC, D, E and AJ4, restated here by the final review (Ruling AJ10). The Step 1 code
> block below is the pre-amendment driver and is *not* what shipped.**
> (1) **`Curve` has one spring knob** -- `Curve.spring(damping:)`. The block's
> `case .spring(let damping, let response)` and `spring.stiffness = CGFloat(4 / (response * response))` were
> deleted by Ruling AC #1: two clocks left every spring truncated with a visible pop. What ships seeds from the
> textbook `k = (4/(ζ·duration))²` and then corrects against the settle time Core Animation actually reports
> (`settlingDuration ≈ 7.87/σ` at ζ = 0.85, **1.967×** the textbook `4/σ`), so `settlingDuration` lands on the
> transition's own duration; `MotionDriverTests.testEverySpringSettlesInsideItsOwnDuration` asserts it for all
> three springs.
> (2) **There is no `frameInSuperlayer`.** The `private extension NSView` at the end of Step 1 was deleted
> (Ruling D): `view.frame` *is* the rect in the superlayer's space, AppKit mirrors flippedness into the layer
> tree, and an alias that implied a conversion existed was worse than nothing. Same reason the `flipped`
> argument this block still threads into `MotionGeometry.morph` is gone -- see Task 9's Ruling AE callout.
> (3) **There is no `Motion.stop(_:)`** (Ruling E), even though the interface list below still produces it.
> The `removeAnimation(forKey:)` that fires when a new target arrives *is* the stop, and nothing else needs to
> call one until Plan 4's prompt-panel dismissal asks for it. An exposed stop entry point with no caller is
> surface, not behaviour.
> (4) **Ruling AC's "carried, not fixed here" note about the probe is now overturned by Ruling AJ4.** The
> coverage did not arrive with Task 11 -- Task 11 gave the *call sites* their own source rects while
> `MotionProbe` went on handing all five the same zero-height full-width gap, so `paneReveal`'s and
> `statusMorph`'s logged numbers described a vertical grow neither performs. The probe now picks each source
> from the `Geometry` the plan declares for it, through the same `MotionGeometry` helpers the panes call, and
> `MotionProbeTests` fails if the five ever collapse back into one.
> (5) Two AC-carried items that were *not* overturned and are still true of the shipped driver: the completion
> is guarded by animation **identity** (plus the measured fact that Core Animation retires a finished
> animation before the transaction block runs, which is why "nothing under the key" also passes), and
> `preparedLayer` still sets `wantsLayer` as a side effect of animating.


**Files:**
- Create: `Sources/Unfold/Design/Motion.swift`
- Create: `Sources/Unfold/AppShell/MotionProbe.swift`
- Modify: `Sources/Unfold/AppShell/DiagnosticsViewController.swift` (the probe button)
- Modify: `Sources/Unfold/AppShell/MainWindowController.swift` (`runMotionProbe`)

**Interfaces:**
- Consumes: `MotionPlan`, `MorphTransform` from Tasks 8 and 9.
- Produces:
  - `Motion.morph(_ view: NSView, source: CGRect, transition: Transition, completion: (() -> Void)? = nil)`
  - `Motion.stop(_ view: NSView)`
  - `MotionProbe.runAll(on host: NSView, log: @escaping (String) -> Void)`

- [ ] **Step 1: Write the driver**

```swift
import AppKit
import QuartzCore

/// The single place the shell touches Core Animation. Everything it needs to know about timing comes
/// from a `Transition`, so retuning motion is a `MotionPlan` edit.
///
/// Two rules, both learned the hard way: geometry carries the motion, and an in-flight morph must be
/// interruptible -- setting a new target retargets from the presentation value instead of queuing a
/// backlog, which is what `liquid-glass.md` means by letting people cancel motion.
@MainActor
enum Motion {
    static func morph(_ view: NSView, source: CGRect, transition: Transition,
                      completion: (() -> Void)? = nil) {
        guard let layer = preparedLayer(for: view) else { return }
        let flipped = view.enclosingScrollView?.documentView?.isFlipped
            ?? (view.superview?.isFlipped ?? false)
        let start = MotionGeometry.morph(source: source, final: view.frameInSuperlayer, flipped: flipped)

        layer.removeAnimation(forKey: Self.morphKey)
        let animation = animation(for: transition, start: start)
        // `CAAnimation.completionHandler` is an iOS-only property -- it is not on the macOS SDK at all,
        // verified against `QuartzCore.framework/Headers/CAAnimation.h`. On macOS the completion is
        // carried by the transaction that wraps the add.
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak view] in
            // The transform is never left applied: the view's real frame is the truth at the end.
            view?.layer?.removeAnimation(forKey: Self.morphKey)
            completion?()
        }
        layer.add(animation, forKey: Self.morphKey)
        rampOpacity(layer, transition: transition)
        CATransaction.commit()
    }

    static func stop(_ view: NSView) { view.layer?.removeAnimation(forKey: Self.morphKey) }

    private static let morphKey = "unfold.morph"

    /// Scale and translate together, in one keyframe-free transform animation so the two cannot drift.
    private static func animation(for transition: Transition, start: MorphTransform) -> CAAnimation {
        let from = transform(scale: start.scale, translation: start.translation)
        let to = CATransform3DIdentity
        switch transition.curve {
        case .spring(let damping, let response):
            let spring = CASpringAnimation(keyPath: "transform")
            spring.fromValue = NSValue(caTransform3D: from)
            spring.toValue = NSValue(caTransform3D: to)
            // `response` is the settle time; stiffness follows from it at unit mass, and damping ratio
            // maps onto `damping` the way CASpringAnimation expects (ratio × 2 × sqrt(stiffness × mass)).
            // All three are CGFloat, and `response` is a Double from the plan -- the conversion is
            // explicit because Swift will not do it for you.
            spring.mass = 1
            spring.stiffness = CGFloat(4 / (response * response))
            spring.damping = CGFloat(2.0 * damping * spring.stiffness.squareRoot())
            spring.duration = transition.duration
            spring.initialVelocity = 0
            return spring
        case .easeOut(let x1, let y1, let x2, let y2):
            let basic = CABasicAnimation(keyPath: "transform")
            basic.fromValue = NSValue(caTransform3D: from)
            basic.toValue = NSValue(caTransform3D: to)
            basic.timingFunction = CAMediaTimingFunction(controlPoints: Float(x1), Float(y1),
                                                         Float(x2), Float(y2))
            basic.duration = transition.duration
            return basic
        }
    }

    private static func transform(scale: CGSize, translation: CGSize) -> CATransform3D {
        var t = CATransform3DIdentity
        t = CATransform3DTranslate(t, translation.width, translation.height, 0)
        return CATransform3DScale(t, scale.width, scale.height, 1)
    }

    /// A short anti-flash ramp only, inside the first `opacityRamp` of the timeline. It starts slightly
    /// transparent and reaches opaque; it never starts at 0 and it never carries the motion alone.
    private static func rampOpacity(_ layer: CALayer, transition: Transition) {
        let ramp = CABasicAnimation(keyPath: "opacity")
        ramp.fromValue = 1 - transition.opacityRamp
        ramp.toValue = 1
        ramp.duration = transition.duration * transition.opacityRamp
        layer.add(ramp, forKey: "unfold.opacity")
    }

    private static func preparedLayer(for view: NSView) -> CALayer? {
        view.wantsLayer = true
        return view.layer
    }
}

private extension NSView {
    /// The frame in the space the layer lives in -- the superlayer's coordinates, which AppKit keeps in
    /// the view's own geometry rather than the flippedness-adjusted drawing space.
    var frameInSuperlayer: CGRect { frame }
}
```

`frameInSuperlayer` is where the coordinate-space question actually bites; the probe in Step 2 is what
proves whether the sign and the magnitude are right on a real layer, and if it reports movement in the
wrong direction the fix belongs in `flipped`, not in the expectation.

- [ ] **Step 2: Write the probe**

```swift
import AppKit

/// Runs each transition on a real view and logs the measured presentation geometry, because "the
/// animation is real" has to be a number at three timestamps rather than a screenshot opinion.
@MainActor
enum MotionProbe {
    /// `promptPresent` and `promptDismiss` are Plan 4's -- the panel they need does not exist yet.
    ///
    /// Each run is staggered past the previous one's duration plus a settle gap. `Motion.morph`
    /// deliberately removes the in-flight animation when a new target arrives, so firing all five at
    /// once would leave the later samples measuring the wrong transition.
    static func runAll(on host: NSView, log: @escaping (String) -> Void) {
        let ids: [TransitionID] = [.rowInsert, .rowRemove, .selectionMorph, .paneReveal, .statusMorph]
        var start = 0.0
        for id in ids {
            guard let transition = MotionPlan.lookup(id) else { continue }
            let at = start
            DispatchQueue.main.asyncAfter(deadline: .now() + at) { run(transition, on: host, log: log) }
            start += transition.duration + 0.15
        }
    }

    /// Nothing is resized here: the probe reads the view's real frame and morphs it out of a zero-height
    /// gap at its own baseline. The animation is a transform, so the layout never changes and the caret
    /// in a neighbouring field cannot move.
    private static func run(_ transition: Transition, on host: NSView, log: @escaping (String) -> Void) {
        let final = host.frame
        let source = CGRect(x: final.minX, y: final.maxY, width: final.width, height: 0)
        Motion.morph(host, source: source, transition: transition)

        let samples = 8
        for step in 0..<samples {
            let when = transition.duration * Double(step) / Double(samples - 1)
            DispatchQueue.main.asyncAfter(deadline: .now() + when) {
                guard let presentation = host.layer?.presentation() else { return }
                let size = presentation.bounds.size
                let t = presentation.affineTransform()
                log("\(transition.id.rawValue) t=\(String(format: "%.0f", when * 1000))ms "
                    + "bounds=\(Int(size.width))x\(Int(size.height)) tx=\(String(format: "%.1f", t.tx)) "
                    + "ty=\(String(format: "%.1f", t.ty))")
            }
        }
    }
}
```

- [ ] **Step 3: Wire the button**

Add `pushButton("Motion probe", #selector(MainWindowController.runMotionProbe))` to
`buttonRow()` (Task 5 reserved its place), and on the controller:

```swift
@objc func runMotionProbe(_ sender: Any?) {
    MotionProbe.runAll(on: diagnostics.containerForMotionProbe) { line in launchLog("motion: \(line)") }
}
```

`DiagnosticsViewController.containerForMotionProbe` is the already-existing `NSStackView` of buttons,
exposed as a property -- do not create a throwaway view; probing the real cluster is the point.

- [ ] **Step 4: Measure it**

```bash
cd "$REPO_ROOT"
: > /tmp/unfold-launch.log && swift build 2>&1 | tail -2 && ./Scripts/make-app-bundle.sh && ./Scripts/install-local.sh
```
Open Diagnostics, press **Motion probe**, then:
```bash
grep "motion:" /tmp/unfold-launch.log | head -45
```
Expected per transition: 8 lines, with `bounds` changing across at least three consecutive samples and
returning to the resting size at the end. A transition that logs one size for all eight samples is not
animating -- that is the failure this task exists to catch, and it means the transform was applied to the
wrong space.

- [ ] **Step 5: Commit, then stop for review** (one local commit per the Git rule; never push). Keep the measured log lines with the result.

---

### Task 11: Wire the five transitions and fix where selection lands after a delete

**Files:**
- Modify: `Sources/Unfold/AppShell/SidebarViewController.swift` (`setRows`, row motion, neighbour selection)
- Modify: `Sources/Unfold/AppShell/MainWindowController.swift` (`paneReveal`, `statusMorph`, add/delete wiring)
- Modify: `Sources/Unfold/AppShell/DiagnosticsViewController.swift` (reveal growth)

**Interfaces:**
- Consumes: `Motion.morph`, `MotionPlan.lookup`, `SidebarViewController.selectedRowFrame`,
  `EditorViewController`'s trigger field frame.

- [ ] **Step 1: Diff the rows in `setRows`**

`setRows` already records `visible.map(\.id)`. Compare before replacing, animate the difference, and
select the **neighbour** of what left:

```swift
func setRows(_ rows: [Combo], selecting id: UUID?) {
    let previous = visible
    let previousShown = shownIDs
    visible = rows  // the moved filter stays in the controller; this pane only receives
    let inserted = Set(visible.map(\.id)).subtracting(previousShown)
    let removed = Set(previousShown).subtracting(visible.map(\.id))
    tableView.reloadData()
    shownIDs = visible.map(\.id)

    // A delete must land on the neighbour, not on row 0: two fast deletes with the confirmation unread
    // otherwise destroy a combo nobody chose. That selection index is also what `rowRemove` collapses
    // toward, so the fix and the motion are the same change.
    let target: Int
    if let id, let index = visible.firstIndex(where: { $0.id == id }) {
        target = index
    } else if let firstRemoved = removed.first,
              let oldIndex = previous.firstIndex(where: { $0.id == firstRemoved }) {
        target = min(oldIndex, max(visible.count - 1, 0))
    } else if let first = visible.first {
        target = 0
    } else {
        onSelect?(nil)
        return
    }
    tableView.selectRowIndexes(IndexSet(integer: target), byExtendingSelection: false)
    animate(inserted: inserted, removed: removed, in: previous)
}
```

- [ ] **Step 2: Animate the difference**

```swift
private func animate(inserted: Set<UUID>, removed: Set<UUID>, in previous: [Combo]) {
    guard !inserted.isEmpty || !removed.isEmpty else { return }
    guard let insert = MotionPlan.lookup(.rowInsert), let remove = MotionPlan.lookup(.rowRemove) else {
        return
    }
    for id in inserted {
        guard let row = visible.firstIndex(where: { $0.id == id }),
              let rowView = tableView.rowView(atRow: row, makeIfNecessary: true) else { continue }
        let final = rowView.frame
        let gap = CGRect(x: final.minX, y: final.maxY, width: final.width, height: 0)
        Motion.morph(rowView, source: gap, transition: insert)
    }
    for id in removed {
        guard let oldIndex = previous.firstIndex(where: { $0.id == id }),
              let neighbour = tableView.rowView(atRow: min(oldIndex, max(previous.count - 2, 0)),
                                                makeIfNecessary: false) else { continue }
        let collapse = CGRect(x: neighbour.frame.minX, y: neighbour.frame.maxY,
                              width: neighbour.frame.width, height: 0)
        if let rowView = tableView.rowView(atRow: min(oldIndex, max(visible.count - 1, 0)),
                                          makeIfNecessary: false) {
            Motion.morph(rowView, source: collapse, transition: remove)
        }
    }
}
```

Row views are recycled, so `rowRemove` animates whatever currently occupies the vanished row's slot --
which is why its source is the neighbour's baseline and the transition is short. If a run shows a row
morphing that did not change, that recycling is the cause, and the fix is to snapshot the leaving row
with `bitmapImageRepForCachingDisplay` rather than to lengthen the animation.

- [ ] **Step 3: `selectionMorph`, `paneReveal`, `statusMorph`**

> **Amended by Ruling AG (the proxy) and Ruling AJ7 (the pill), decided by the final review.** Two things in
> this step are not what shipped.
> (1) **`editor.triggerFieldProxy` does not exist** -- see Task 4's callout for why a pane-hosted proxy was
> clipped. The code block below ran on `MainWindowController.selectionOverlay`, a `SelectionOverlayLineView`
> in the **window's content view**, and both rects are converted out of screen space into the overlay's host
> space before the morph (they cross panes, so they arrive in screen coordinates and `MotionGeometry`
> compares them against the overlay's own layer space). The `isHidden = false` / restore pairing, the
> `to != from` refusal and the completion passed to `Motion.morph` rather than chased by a timer are all as
> written here.
> (2) **`statusMorph` does not run "on the pill's stack".** The stack is the glass view's own `contentView`,
> and the pill body the user reads as *the pill* is sized by AppKit's toolbar layout, so morphing the stack
> sprang content inside a box that snapped -- two objects on two clocks, which this plan's own rule 4 forbids
> for a control the system already animates. It morphs `MainWindowController.statusPill`, the wrapped
> `NSGlassEffectView`, and measures its **previous and final frames off that same view**; the deferred read
> (one main-queue turn, because the toolbar re-measures asynchronously) is unchanged. Measured in-process
> (`StatusPillMotionTests`): the item view goes 71 → 263 pt in one layout pass with no animation on it or on
> the `NSToolbarItemViewer` above it, and morphing it interpolates the rendered width with `scale.y` pinned at
> 1.000.
> The `.hierarchicalColor` symbol configuration and "do not animate when the value is unchanged" stay as
> specified; the memo that enforces the second is `lastRenderedStatus`.

`selectionMorph` runs from the controller, because it is the one transition with a source and a target
in different panes:

```swift
sidebar.onSelect = { [weak self] id in
    guard let self else { return }
    if let morph = MotionPlan.lookup(.selectionMorph), let from = self.sidebar.selectedRowFrame {
        let to = self.editor.triggerFieldFrameInWindow
        if let to, to != from {
            // The proxy ships hidden (Task 4 round 1): it exists to be morphed, and drawing it any
            // other time would put a line through the user's trigger text.
            self.editor.triggerFieldProxy.isHidden = false
            Motion.morph(self.editor.triggerFieldProxy, source: from, transition: morph) {
                self.editor.triggerFieldProxy.isHidden = true
            }
        }
    }
    self.selectedID = id
    self.redisplay()
}
```

`triggerFieldProxy` is a `NSView` the editor exposes that sits exactly over the trigger field and holds
nothing but a 1 pt `NSColor.separatorColor` line; morphing a proxy that way keeps the real field from
re-laying out mid-animation, which is what moved the caret the last time a morph touched an editor
control. *(Not what shipped -- Ruling AG replaced this view with the window-level
`SelectionOverlayLineView` for the clipping reason in Task 4's callout, and kept the reason: the line morphs,
the field never does.)*

`paneReveal`: the diagnostics pane grows from the divider side when `toggleDiagnostics` flips
`isCollapsed`, using its own leading edge as the source; keep the split view's own animation and morph
the content, not the divider.

`statusMorph`: in `refreshStatus`, when the symbol name or the label text actually changed, run
`statusMorph` on the pill's stack and use `NSImage(systemSymbolName:)` plus
`symbolConfiguration` with `.hierarchicalColor` so the replacement is a morph rather than a swap. Do
not animate when the value is unchanged -- `refreshStatus` runs once a second.

- [ ] **Step 4: Test and measure**

```bash
cd "$REPO_ROOT"
swift test 2>&1 | grep -E "Test Suite 'All tests' failed|with [1-9][0-9]* failures" || echo GREEN
```
Expected: green, with the new total reported. Then add a test to `Tests/UnfoldEngineTests/StoreTests.swift`
only if the neighbour-selection logic proved to need model support -- it does not, it is pane state, so
the honest coverage is live: delete a middle row and confirm the *neighbour* is selected; delete twice
fast without reading the alert and confirm the second delete hits what the row said; press `+` and
confirm `grep "motion:" /tmp/unfold-launch.log` after a probe run still shows changing bounds.

- [ ] **Step 5: Commit, then stop for review** (one local commit per the Git rule; never push).

---

### Task 12: The appearance toggle, one status vocabulary, and the two-appearance pass

**Files:**
- Modify: `Sources/Unfold/AppShell/MainWindowController.swift` (toolbar item `unfold.appearance`)
- Modify: `Sources/Unfold/AppShell/StatusItemController.swift` (shared vocabulary)
- Modify: `Sources/Unfold/Design/Theme.swift` (`MenuStatus` symbol/colour table)
- Modify: `docs/specs/2026-10-29-unfold-liquid-glass-motion-design.md` (corrections found here)

**Interfaces:**
- Consumes: `AppearancePreference` from Task 2, `MenuStatus` from `StatusItemController.swift`.
- Produces: `extension MenuStatus { var symbolName: String { get }; var emphasisColor: NSColor { get }; var shortText: String { get } }`.

- [ ] **Step 1: Move the status vocabulary onto `MenuStatus`**

`MainWindowController.refreshStatus` currently duplicates the symbol/text/colour decisions that
`MenuStatus` already makes for the menu
([MainWindowController.swift:731-753](../../../Sources/Unfold/AppShell/MainWindowController.swift)).
Delete the local `(symbol, text, color)` tuple and the switch that builds it, and evaluate the existing
pure function instead -- one decision, two surfaces:

```swift
let status = MenuStatus.evaluate(isTrusted: PermissionFlow.isTrusted,
                                 isPaused: coordinator.isPaused,
                                 tapState: coordinator.tapState,
                                 isTapEnabled: coordinator.isTapEnabled)
statusSymbol?.image = NSImage(systemSymbolName: status.symbolName,
                              accessibilityDescription: status.text)
statusSymbol?.contentTintColor = status.emphasisColor
statusLabel?.stringValue = status.shortText
// Monochrome label: the label has to be readable on its own, and only red clears the glyph floor in
// Light mode, so the broken states are coloured and the working ones are not.
statusLabel?.textColor = .labelColor
statusItem?.toolTip = "\(status.text) -- \(coordinator.keystrokesSeen) keystrokes, "
    + "\(coordinator.tapDisableObservations) tap switch-offs"
```

Note the behaviour this *changes*, deliberately: `refreshStatus`'s old switch reached the same
conclusions by a different route, and `MenuStatus` is the one that has the tests. The pill's label text
comes from `status.text`, whose `notReceivingKeystrokes` wording is long ("not receiving keystrokes -- a
password field or Secure Input can block expansion") and was written for a menu, not a pill. Split the
value into a short and a long form so the pill stays compact and the menu stays specific:

```swift
extension MenuStatus {
    /// The pill's one-line form. `text` is the menu's full sentence; both are decided from the same
    /// case, so they cannot disagree about whether expansion can happen.
    var shortText: String {
        switch self {
        case .notPermitted: "Grant access"
        case .paused: "Paused"
        case .tapGivenUp: "Tap stopped"
        case .notReceivingKeystrokes: "Tap silent"
        case .tapInterrupted: "Tap off"
        case .tapDetached: "Tap off"
        case .listening: "Ready"
        }
    }
}
```
Use `status.shortText` for `statusLabel` and `status.text` for the tooltip. `MenuStatusTests` keeps
passing because `text` is untouched; add one test asserting `shortText` is non-empty and under 14
characters for every case.

Then the symbol and colour table, added to `StatusItemController.swift` next to `MenuStatus` itself:

```swift
extension MenuStatus {
    /// The symbol and its emphasis colour. Colour is decoration only: `text` states the same fact, and
    /// the pill's label is `labelColor` because systemGreen is 2.22:1 over a light window background.
    var symbolName: String {
        switch self {
        case .notPermitted: "exclamationmark.triangle.fill"
        case .paused: "pause.circle.fill"
        case .tapGivenUp: "exclamationmark.triangle.fill"
        case .notReceivingKeystrokes: "exclamationmark.circle.fill"
        case .tapInterrupted: "exclamationmark.circle.fill"
        case .tapDetached: "slash.circle.fill"
        case .listening: "checkmark.circle.fill"
        }
    }
    /// Red is the only status colour that survives Light mode: measured against a light window
    /// background, `systemGreen` is 2.22:1 and `systemOrange` 2.31:1, which is a faint smudge rather
    /// than a status light. So the pill reads as *red means not working, monochrome means working*,
    /// and the same identity holds in both appearances instead of only in Dark. ContrastTests pins the
    /// numbers that forced this; if they ever change, that test says so.
    var emphasisColor: NSColor {
        switch self {
        case .notPermitted, .tapGivenUp, .notReceivingKeystrokes, .tapInterrupted, .tapDetached:
            return .systemRed
        case .paused, .listening:
            return .labelColor
        }
    }
}
```

The menu bar's own status line keeps its wording -- `MenuStatus.text` already decides it -- and the
honest limit stays documented: the `NSStatusItem` menu is drawn by the system menu bar and follows the
*system* appearance, not this app's override.

- [ ] **Step 2: Add the toolbar control**

`MainWindowController`: a new identifier, item builder, and both identifier lists.

```swift
private static let appearance = NSToolbarItem.Identifier("unfold.appearance")

/// Three states, with Match System first and reachable from the same control: the failure mode of an
/// in-app switch is that a person gets stuck in it, which is exactly what `dark-mode.md` warns about.
private func buildAppearanceItem(_ identifier: NSToolbarItem.Identifier) -> NSMenuToolbarItem {
    // `NSToolbarItem.menu` does not exist on the macOS 27 SDK -- `NSToolbarItem.h` exposes only
    // `menuFormRepresentation` -- so the menu-bearing subclass is the only compilable shape. Its
    // `showsIndicator` defaults to YES, which adds a menu chevron the plain-symbol neighbours do not
    // carry: check it on pixels and set it to `false` if it reads as clutter.
    let item = NSMenuToolbarItem(itemIdentifier: identifier)
    item.label = "Appearance"
    item.paletteLabel = "Appearance"
    item.toolTip = AppearancePreference.read().tooltip
    item.image = NSImage(systemSymbolName: "circle.lefthalf.filled", accessibilityDescription: "Appearance")
    item.isBordered = true
    let menu = NSMenu()
    for preference in AppearancePreference.allCases {
        let entry = NSMenuItem(title: preference.menuTitle,
                               action: #selector(selectAppearance(_:)), keyEquivalent: "")
        entry.target = self
        entry.representedObject = preference.rawValue
        entry.state = preference == AppearancePreference.read() ? .on : .off
        menu.addItem(entry)
    }
    item.menu = menu
    return item
}

@objc private func selectAppearance(_ sender: NSMenuItem) {
    guard let raw = sender.representedObject as? String,
          let preference = AppearancePreference(rawValue: raw) else { return }
    preference.write()
    preference.apply()
    sender.menu?.items.forEach { $0.state = $0 === sender ? .on : .off }
    refreshStatus()
}
```

Add `.appearance` to `toolbarDefaultItemIdentifiers` after `.pause` and to
`toolbarAllowedItemIdentifiers`. In `Theme.swift` add:

```swift
extension AppearancePreference {
    var menuTitle: String {
        switch self {
        case .system: "Match System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
    var tooltip: String { "Appearance -- \(menuTitle)" }
}
```

- [ ] **Step 3: Verify the toggle and the two paths agree**

```bash
cd "$REPO_ROOT"
swift build 2>&1 | tail -2 && swift test 2>&1 | grep -E "Test Suite 'All tests' failed|with [1-9][0-9]* failures" || echo GREEN
./Scripts/make-app-bundle.sh && ./Scripts/install-local.sh
```
This raises the app's window and changes nothing in System Settings by itself -- say so before running
it. Then: toggle Light → Dark → Match System and screenshot each; flip the **system** appearance and
confirm Match System tracks it while an explicit choice does not; confirm the prompt-panel-less surfaces
(alert, sheets, Diagnostics, sidebar) all change together, and that a relaunch comes back in the chosen
appearance.

- [ ] **Step 4: Contrast on pixels where math cannot reach**

Capture the toolbar pill over a deliberately light and a deliberately dark desktop picture, both
appearances, and check the label reads. This is the pair `ContrastTests` cannot decide, because glass
samples whatever is behind the window.

- [ ] **Step 5: Correct the spec with anything the measurements contradicted**

Three corrections were already folded in during planning (the `.v26` tools-version requirement, the
translucent-label measurement, `vtool` as the floor check). If Task 10 or 11 found another, edit the
spec in the same commit and say what changed.

- [ ] **Step 6: Full verification**

```bash
cd "$REPO_ROOT"
swift build
swift test
grep -rn "#available" Sources/Unfold/ | grep -v "macOS 27.0" || echo "no fallback guards"
grep -rn "tintColor\|UIDesignRequiresCompatibility" Sources/Unfold/ Resources/Info.plist || echo "no tint, no compat key"
vtool -show-build .build/debug/Unfold | grep minos
grep -rn "^import " Sources/UnfoldEngine/ | grep -v Foundation || echo "engine still Foundation-only"
```
Expected: build clean, all tests green, `no guards`, `no tint, no compat key`, `minos 26.0`, `engine
still Foundation-only`. Then on the installed build: `Self-test`, `Stress test (40)`, `Idle timeout`,
`Ctrl-C in Terminal`, `Run consistency test` -- all must behave as they did before this plan started,
because every one of them is how the keyboard layer proves itself.

- [ ] **Step 7: Stop for review**

List changed files, the final test total, the measured motion log, the screenshot set in both
appearances, and any spec correction. Commit this task once, then stop for review. Never push -- that is a manual step.

## Corrections found while planning

Already folded into the spec; listed here so nobody re-derives them:

1. **`.macOS(.v26)` needs `swift-tools-version: 6.2`.** Probed 2026-10-29; 6.0 fails with
   `'v26' is unavailable`.
2. **`swift test`'s `Target Platform` line is not evidence of the floor.** It printed `macos14.0` even
   after the floor was raised. `vtool -show-build` on the binary is the instrument that works.
3. **Semantic label colors are translucent, so contrast math must composite alpha.** The first probe
   reported `secondaryLabel` at 21:1 -- identical to `label` -- because alpha was ignored. Composited, it
   is 3.95:1 in Light, which is what drove Task 7's colour moves.
4. **`NSAppearance(named:)` is failable** and `NSAppearanceName` is `NSAppearance.Name` in Swift. Both
   hit while compiling the probe.
5. **Anchors come from views we own, not from toolbar geometry.** `NSToolbarItem` exposes no public
   frame for an image item, so `rowInsert` unfolds from the row's own gap and `paneReveal` from the
   divider edge rather than from the `+` and stethoscope items.
6. **`NSAnimationEffect` is deprecated 10.3-14.0** and there is no `NSAnimationTimingFunction` in
   AppKit, which is why Tasks 8-10 exist instead of a call to `insertRows(withAnimation:)`.
7. **`CAAnimation.completionHandler` does not exist on the macOS SDK.** The first compile of Task 10's
   `Motion.swift` failed with `value of type 'CAAnimation' has no member 'completionHandler'`;
   `CATransaction.setCompletionBlock` is the macOS path. Fixed in the code above.
8. **The baseline is 186 test methods, not 71.** `swift test` prints an `Executed N tests` line per
   target, and 71 is only `UnfoldEngineTests`; `UnfoldMacTests` has 106 and `UnfoldTests` 9. The plan now
   uses `swift test --list-tests | grep -c "/"` for the count and a failure-pattern grep for the verdict,
   because `grep "Executed 71 tests"` reports green even when a different target failed.
9. **`systemGreen` and `systemOrange` cannot be status glyphs in Light mode.** Writing the contrast table
   and running it found `pill.statusSymbol = 2.22:1 under 3.0` in Aqua -- the colour scheme approved in
   design did not survive measurement. Status colour collapses to *red = not working, monochrome =
   working*, which also keeps one identity across appearances instead of a coloured pill only in Dark.
   This changes an approved decision, so it is called out here rather than left in the file.

Every code block in Tasks 2, 7, 8, 9, 10 and 12's `MenuStatus` extension was compiled and run in an
isolated copy of the repo (macOS 27.2, SDK 27.0, Swift 6.4) on 2026-10-29: the package built, and
204 test methods ran with 0 failures -- the 186 baseline plus the 18 new ones from Tasks 2, 7, 8 and 9.

> **Scoped by the final review (Ruling AJ10), so the sentence above is not read as more than it is.** That run
> is evidence about the **pre-measurement** code -- the blocks as they were written when the plan was approved.
> It is not evidence about what shipped: six of those blocks were corrected *during* execution by measurement
> (Rulings X and Z for Tasks 7-9's table and tests, AC and AE for Task 10's driver and Task 9's `flipped`,
> AG for Task 4's proxy and Task 11's `selectionMorph`, AJ2-AJ9 for this fix wave), so the compiled-and-run
> claim applies to the plan's own snapshot, and each superseded block carries an `Amended by ...` callout saying
> what replaced it. The suite the shipped tree runs against is the one reported per task in this plan plus
> this fix wave's ten new methods -- **265 methods, 0 failures** (88 `UnfoldTests` / 106 `UnfoldMacTests` /
> 71 `UnfoldEngineTests`) at the tip of
> this pass, measured rather than recalled (the ten new `UnfoldTests` methods: seven in `MotionProbeTests`,
> one in `StatusPillMotionTests`, two landing-count tests in `SidebarRowMotionTests`; `--list-tests | grep -c /`
> = 265).
