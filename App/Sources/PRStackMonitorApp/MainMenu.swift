import AppKit

/// The application menu bar — which this app never displays, and cannot do without.
///
/// `LSUIElement` plus `.accessory` means there is no menu bar to draw: nothing here is ever
/// on screen. What a main menu carries besides its items is the **key equivalents**, and
/// `NSApplication` resolves those by walking `mainMenu` before the event reaches the first
/// responder. With no main menu at all there is nothing to walk, so ⌘V is not "unhandled" —
/// it is never routed anywhere, and a `SecureField` in the Settings window has no paste.
/// Right click → Paste works throughout, because that menu is built by the text system from
/// the responder itself and never consults this one, which is exactly what makes the
/// difference look like a bug in the field rather than a missing menu.
///
/// So the items below are not a UI decision. They are the dispatch table for the keystrokes
/// every text field on macOS is expected to answer, plus ⌘Q — which an app with no Dock
/// icon and no window of its own otherwise has no keyboard route to at all. The panel's
/// overflow menu carries `Quit` for the same reason from the other direction: this one only
/// works while the app is active, and a menu bar app usually is not.
@MainActor
enum MainMenu {
    static func install(into application: NSApplication) {
        let menu = NSMenu()
        menu.addItem(submenu(named: ProcessInfo.processInfo.processName, items: applicationItems()))
        // Titled `Edit` because AppKit matches on that title when it injects the system's
        // own editing items — dictation and the emoji picker among them — into the menu.
        menu.addItem(submenu(named: "Edit", items: editItems()))
        application.mainMenu = menu
    }

    private static func applicationItems() -> [NSMenuItem] {
        [
            NSMenuItem(
                title: "Quit \(ProcessInfo.processInfo.processName)",
                action: #selector(NSApplication.terminate(_:)),
                keyEquivalent: "q"
            )
        ]
    }

    /// The responder chain's editing selectors, by name.
    ///
    /// By name and not by `#selector`, which would be checked by the compiler, because
    /// there is no one type to check them against: `NSText` declares five of these and not
    /// undo or redo, and `copy:` collides with `NSObject.copy()` when it is written as a
    /// selector expression. These seven are an informal protocol — every responder that
    /// edits text implements the ones it supports and AppKit routes by name — so naming
    /// them is what they are, not a shortcut around the type system.
    private static func editItems() -> [NSMenuItem] {
        [
            item("Undo", "undo:", "z"),
            redo(),
            .separator(),
            item("Cut", "cut:", "x"),
            item("Copy", "copy:", "c"),
            item("Paste", "paste:", "v"),
            item("Delete", "delete:", ""),
            .separator(),
            item("Select All", "selectAll:", "a")
        ]
    }

    private static func item(_ title: String, _ selector: String, _ key: String) -> NSMenuItem {
        NSMenuItem(title: title, action: NSSelectorFromString(selector), keyEquivalent: key)
    }

    /// ⇧⌘Z. The modifier has to be set after construction: `keyEquivalent` alone implies
    /// ⌘ only, and a bare `"Z"` would be read as the character rather than as shifted.
    private static func redo() -> NSMenuItem {
        let redo = item("Redo", "redo:", "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        return redo
    }

    /// A top-level entry is an item whose only job is to hold a submenu — the item's own
    /// action is never sent, and the first one's title is replaced by the system with the
    /// process name.
    private static func submenu(named title: String, items: [NSMenuItem]) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        for child in items { menu.addItem(child) }
        entry.submenu = menu
        return entry
    }
}
