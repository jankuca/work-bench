import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// Held for the lifetime of the process — releasing it removes the menu bar item.
    private var statusItemController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItemController = StatusItemController()
    }

    /// There is no window to restore, so clicking the app in Finder should do nothing
    /// rather than resurrect anything.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        false
    }
}
