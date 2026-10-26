import AppKit

/// The menu bar, because on macOS the menu bar is the interface that is always there.
///
/// `toolbars.md › Desktop`: "Make every toolbar item available as a command in the menu bar." People
/// can customise or hide a toolbar; they cannot hide the menu bar, and Full Keyboard Access navigates
/// through it. Every command the window offers is reachable here, and the standard menus -- Edit for
/// text, View for the sidebar, Window for window management, Help -- exist so the app behaves like
/// every other app rather than like a panel.
enum AppMenu {
    static func install() {
        let main = NSMenu()
        main.addItem(appMenu())
        main.addItem(fileMenu())
        main.addItem(editMenu())
        main.addItem(viewMenu())
        main.addItem(windowMenu())
        main.addItem(helpMenu())
        NSApp.mainMenu = main
    }

    /// Commands are sent with a nil target, so they travel the responder chain and land on whatever
    /// window is key -- which is how a menu item reaches `MainWindowController` without knowing it.
    private static func item(_ title: String, _ selector: String, _ key: String,
                             _ mask: NSEvent.ModifierFlags = .command) -> NSMenuItem {
        let action = selector.isEmpty ? nil : Selector(selector)
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        if !key.isEmpty { item.keyEquivalentModifierMask = mask }
        return item
    }

    private static func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let parent = NSMenuItem()
        parent.title = title
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        parent.submenu = menu
        return parent
    }

    private static func appMenu() -> NSMenuItem {
        submenu("Unfold", [
            item("About Unfold", "orderFrontStandardAboutPanel:", ""),
            .separator(),
            item("Hide Unfold", "hide:", "h"),
            item("Hide Others", "hideOtherApplications:", "h", [.command, .option]),
            item("Show All", "unhideAllApplications:", ""),
            .separator(),
            item("Quit Unfold", "terminate:", "q"),
        ])
    }

    private static func fileMenu() -> NSMenuItem {
        submenu("File", [
            item("New Combo", "newCombo:", "n"),
            item("Delete Combo", "deleteCombo:", "\u{8}", [.command, .option]),
            .separator(),
            item("Reveal Combos File", "revealCombos:", "r", [.command, .shift]),
            .separator(),
            item("Close Window", "performClose:", "w"),
        ])
    }

    private static func editMenu() -> NSMenuItem {
        let menu = submenu("Edit", [
            item("Undo", "undo:", "z"),
            item("Redo", "redo:", "Z"),
            .separator(),
            item("Cut", "cut:", "x"),
            item("Copy", "copy:", "c"),
            item("Paste", "paste:", "v"),
            item("Delete", "delete:", ""),
            item("Select All", "selectAll:", "a"),
        ])
        return menu
    }

    private static func viewMenu() -> NSMenuItem {
        submenu("View", [
            item("Show/Hide Sidebar", "toggleSidebar:", "s", [.command, .control]),
            item("Show/Hide Diagnostics", "toggleDiagnostics:", "d", [.command, .option]),
            .separator(),
            item("Pause Expansion", "toggleExpansionPaused:", "p", [.command, .option]),
        ])
    }

    private static func windowMenu() -> NSMenuItem {
        let menu = submenu("Window", [
            item("Minimize", "performMiniaturize:", "m"),
            item("Zoom", "performZoom:", ""),
            .separator(),
            item("Bring All to Front", "arrangeInFront:", ""),
        ])
        NSApp.windowsMenu = menu.submenu
        return menu
    }

    private static func helpMenu() -> NSMenuItem {
        let menu = submenu("Help", [item("Unfold Help", "showHelp:", "?")])
        NSApp.helpMenu = menu.submenu
        return menu
    }
}
