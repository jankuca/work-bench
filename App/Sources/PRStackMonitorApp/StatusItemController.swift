import AppKit
import SwiftUI
import PRStackCore

/// Owns the menu bar item and the popover attached to it.
///
/// `NSStatusItem` + `NSPopover` rather than `MenuBarExtra`, per
/// docs/IMPLEMENTATION_PLAN.md §1: the icon is drawn per state — badge count composited
/// into the image, dashed disconnected glyph — and the popover's dismissal has to be
/// predictable. `MenuBarExtra(.window)` makes both awkward.
///
/// What the icon shows is decided in core (``IconState``) and drawn by ``StatusItemIcon``.
/// This class only routes: it is the ``IconPresenter`` the event bus's one sink pushes to.
@MainActor
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let controller: PanelController
    private let events: EventBus
    /// The hovered-row key handler. One instance for the life of the process, started when
    /// the popover opens and stopped when it closes — never re-created, so there is one
    /// monitor to own rather than one per open.
    private let keys = HoverKeyMonitor()
    /// Built the first time Settings is asked for, and kept from then on.
    ///
    /// Lazily, because building it reads the Keychain to say where each credential is
    /// coming from, and a menu bar app that never has its settings opened should not do
    /// that at launch on top of the poll that already does.
    private lazy var settings: SettingsWindowController = {
        let window = SettingsWindowController(events: events)
        // Settings can change what a poll covers — the repository scope, a tag pattern, a
        // credential — so an edit brings the next poll forward instead of leaving the panel
        // on data gathered under the old settings.
        window.onChange = { [weak self] in self?.controller.settingsDidChange() }
        return window
    }()

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        popover = NSPopover()
        events = EventBus()
        controller = PanelController(source: GitHubPanelSource(), events: events)
        super.init()
        // One sink today, and the list is what makes a `UserNotificationSink` a drop-in
        // later (IMPLEMENTATION_PLAN §1). Registered before anything can publish.
        events.register(IconSink(presenter: self))
        controller.onOpenSettings = { [weak self] in self?.showSettings() }
        // `terminate` rather than `stop`: this is the user asking the app to go away, and
        // it runs the delegate's `applicationShouldTerminate` path like ⌘Q does.
        controller.onQuit = { NSApp.terminate(nil) }
        configure()
    }

    private func configure() {
        // The panel sizes itself: 440 pt wide, height to content up to 800 (§5). Letting
        // the hosting controller drive `contentSize` is what makes the all-clear state a
        // short panel rather than an 800 pt one with a message at the top.
        let hosting = NSHostingController(rootView: PanelView(controller: controller))
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self

        guard let button = statusItem.button else { return }
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(togglePopover(_:))
        // Nothing has been derived yet, so the honest first frame is the first-run one:
        // not connected, nothing verified, dashed.
        show(.disconnected)

        // Starts the scheduler, which polls once immediately and then on the interval table
        // — sleep, battery, panel state and all. Nothing else in this class has a timer.
        controller.start()
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }

        if popover.isShown {
            popover.performClose(sender)
            return
        }

        // A status-item popover does not receive key events unless the app is active.
        // Activating on open and letting `.transient` close it on resign is the standard
        // arrangement, and it is what makes the hovered-row keyboard actions work without
        // changing how dismissal feels.
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        controller.panelDidOpen()
        // After `show`, because the popover has no window before it. Scoping the monitor to
        // that window is what keeps a keystroke aimed at Settings from dismissing a row
        // behind it.
        keys.start(on: popover.contentViewController?.view.window, controller: controller)
    }

    /// Settings is a window, so it needs the app in front — with `.accessory` there is no
    /// Dock icon to bring it there.
    private func showSettings() {
        // The popover is transient and would close on its own the moment the window takes
        // over; closing it explicitly means the monitor comes down through the same path as
        // every other dismissal rather than on a resign nobody routed.
        if popover.isShown { popover.performClose(nil) }
        NSApp.activate()
        settings.show()
    }
}

extension StatusItemController: IconPresenter {
    /// The one place an ``IconState`` becomes something on screen.
    func show(_ state: IconState) {
        guard let button = statusItem.button else { return }
        button.image = StatusItemIcon.image(for: state)
        // The badge is drawn into the image, so it is not an accessibility element of its
        // own — the button's label has to carry the state or VoiceOver reads a bare
        // "Pull requests" whatever the icon says.
        button.setAccessibilityLabel(state.accessibilityLabel)
        button.toolTip = state.accessibilityLabel
    }
}

extension StatusItemController: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        // Both halves of the same dismissal, and both idempotent: a close and a resign
        // fire for one user action, and `stop()` is written to survive being called twice.
        keys.stop()
        controller.panelDidClose()
    }
}
