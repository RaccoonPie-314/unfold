import AppKit

/// The one place the app's look is decided, so a change to a radius or a caption size is one edit.
///
/// Colors are deliberately absent: every color in the shell is a semantic `NSColor` that resolves per
/// appearance, and `swift build` cannot compile an asset catalog. What is spelled out here is the
/// geometry and type, plus the appearance preference.
enum Theme {
    enum Radius {
        static let card: CGFloat = 10    // glass-wrapped clusters
        static let pill: CGFloat = 13    // the toolbar status pill and the sidebar selection pill
    }

    enum Spacing {
        static let panePadding: CGFloat = 24
        static let captionColumn: CGFloat = 82
        static let gutter: CGFloat = 12
        /// The horizontal inset the glass selection pill takes off a source-list row's rect -- the same
        /// 10 pt the filter field is inset from the pane edge, so the pill lines up with the list's own
        /// inset column instead of running to the scroller.
        static let rowPillInset: CGFloat = 10
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
    ///
    /// **Honest limit:** this reaches Unfold's windows, panels, sheets and alerts -- and nothing else.
    /// The `NSStatusItem` menu (`StatusItemController`) is drawn by the system menu bar and follows the
    /// *system* appearance, not this override; an app cannot restyle the menu bar.
    func apply() {
        guard let appearanceName, let appearance = NSAppearance(named: appearanceName) else {
            NSApp.appearance = nil
            return
        }
        NSApp.appearance = appearance
    }
}

/// The words the `unfold.appearance` toolbar control shows. The raw values these are built from are
/// pinned by `ThemeTests.testPersistedContractIsPinned`; the three titles are the contract the user
/// reads, so they are spelled once, here, in the order that keeps the system default reachable.
extension AppearancePreference {
    var menuTitle: String {
        switch self {
        case .system: return "Match System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    /// The toolbar item's tooltip, naming the choice currently in force.
    var tooltip: String { "Appearance — \(menuTitle)" }
}
