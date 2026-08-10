import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Held for the lifetime of the process — releasing it removes the menu bar item.
    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Before the status item, because the first thing the user can do is open the
        // panel and the menu is what makes ⌘V work in the fields behind it. See
        // ``MainMenu`` for why an app with no visible menu bar needs one.
        MainMenu.install(into: NSApplication.shared)
        statusItemController = StatusItemController()
    }

    /// There is no window to restore, so clicking the app in Finder should do nothing
    /// rather than resurrect anything.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        false
    }
}
