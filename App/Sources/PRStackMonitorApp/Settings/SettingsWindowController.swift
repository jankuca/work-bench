import AppKit
import SwiftUI

/// The one window this app has.
///
/// Hand-rolled rather than SwiftUI's `Settings` scene: there is no `App` here to hang a
/// scene off — the shell is an `NSApplication` with a status item and a popover — and an
/// `.accessory` app has no menu bar of its own to put ⌘, on.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    /// Called when something a poll reads has changed, and again when the window closes.
    var onChange: () -> Void = {}

    private let model: SettingsModel
    /// Built once and kept. Rebuilding it per open would drop the field contents and the
    /// last message every time the user looked away, and there is exactly one of it.
    private var window: NSWindow?

    init(events: EventBus, defaults: UserDefaults = .standard) {
        model = SettingsModel(events: events, defaults: defaults)
        super.init()
        model.onChange = { [weak self] in self?.onChange() }
    }

    func show() {
        let window = window ?? makeWindow()
        self.window = window
        // Fresh every time it is shown: a token can be revoked in Keychain Access while the
        // window sits behind the panel.
        model.refreshCredentialSources()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 400),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "PRStackMonitor Settings"
        window.contentView = NSHostingView(rootView: SettingsView(model: model))
        // `NSWindow` still defaults to freeing itself on close, and this one is held in a
        // property that outlives the close — without this, reopening messages a dead object.
        window.isReleasedWhenClosed = false
        window.delegate = self
        // Once, on creation. Centring on every show would move a window the user had put
        // somewhere.
        window.center()
        return window
    }

    /// Closing is the moment to poll: it is the end of an editing session, and the changes
    /// inside it were each applied as they were made.
    func windowWillClose(_ notification: Notification) {
        onChange()
    }
}
