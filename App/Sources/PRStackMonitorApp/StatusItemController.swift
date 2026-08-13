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
    /// The activation observers, held only because `addObserver(forName:)` hands them back.
    ///
    /// Never removed: this object is built in `applicationDidFinishLaunching` and held for
    /// the life of the process, exactly like the status item it owns, so there is no moment
    /// at which unregistering them would be anything but ceremony.
    private var activationTokens: [any NSObjectProtocol] = []
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
        // The panel sizes itself: 440 pt wide, height to content up to 800 (§5), and takes
        // the click that activates the app rather than swallowing it — both are
        // ``PanelHostingController``'s doing, and the second is what makes a panel left open
        // in the background clickable the first time.
        popover.contentViewController = PanelHostingController(rootView: PanelView(controller: controller))
        // Re-read on every open; see ``togglePopover(_:)``. Set here as well so the popover
        // is never briefly configured for a behaviour the user did not choose.
        popover.behavior = AppDefaults.panelDismissal().behavior
        popover.animates = false
        popover.delegate = self

        guard let button = statusItem.button else { return }
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(togglePopover(_:))
        // Nothing has been derived yet, so the honest first frame is the first-run one:
        // not connected, nothing verified, dashed.
        show(.disconnected)

        // The panel is open for as long as the user leaves it open, so "open" and "being
        // looked at" are two questions rather than one.
        observeActivation()

        // Starts the scheduler, which polls once immediately and then on the interval table
        // — sleep, battery, panel state and all. Nothing else in this class has a timer.
        controller.start()
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }

        if popover.isShown {
            closePanel()
            return
        }

        // Read per open rather than held, for the same reason the poll reads its scope per
        // poll: there is then no second copy to keep in step. The open is also the moment
        // AppKit acts on it — a popover arms its dismissal when it is shown — and the only
        // place the preference is edited closes the panel to get at itself, so the next open
        // is always the first moment a change could matter.
        popover.behavior = AppDefaults.panelDismissal().behavior

        // A status-item popover does not receive key events unless the app is active.
        // Activating on open is the standard arrangement, and it is what makes the
        // hovered-row keyboard actions work.
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        controller.panelDidOpen()
        // After `show`, because the popover has no window before it. Scoping the monitor to
        // that window is what keeps a keystroke aimed at Settings from dismissing a row
        // behind it.
        //
        // `esc` comes through the same monitor. `.transient` would close on it by itself;
        // a panel set to stay open has nobody to do that, and the key has to mean the same
        // thing under both.
        keys.start(
            on: popover.contentViewController?.view.window,
            controller: controller,
            onCancel: { [weak self] in self?.closePanel() }
        )
    }

    /// Every dismissal that is not AppKit's own: the menu bar icon, `esc`, and Settings
    /// taking over. `performClose` rather than `close` so the delegate hears it — that is
    /// what stops the key monitor and tells the panel controller.
    private func closePanel() {
        guard popover.isShown else { return }
        popover.performClose(nil)
    }

    /// Watches the app moving in and out of the foreground, so an open panel can say whether
    /// it is being *looked at*.
    ///
    /// With the panel closing on blur the two are the same thing and nothing here ever
    /// changes the answer. With it set to stay open they come apart: the panel sits on screen
    /// while the user works in another app, and a poll landing behind it has not been seen —
    /// which is the difference between the menu bar lighting up for new activity and never
    /// lighting up again.
    private func observeActivation() {
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            let token = NotificationCenter.default.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                // `queue: .main` is what makes this assertion true rather than hopeful: the
                // block is delivered on the main queue, which is the main actor's executor.
                MainActor.assumeIsolated {
                    self?.applicationActivationChanged(
                        isActive: name == NSApplication.didBecomeActiveNotification
                    )
                }
            }
            activationTokens.append(token)
        }
    }

    private func applicationActivationChanged(isActive: Bool) {
        // Activation happens all day with the panel closed — Settings, a resign the panel is
        // already gone for — and none of it is about the panel.
        guard popover.isShown else { return }
        controller.panelDidChangeFocus(isActive)
    }

    /// Settings is a window, so it needs the app in front — with `.accessory` there is no
    /// Dock icon to bring it there.
    private func showSettings() {
        // Closed explicitly rather than left to AppKit: a transient popover would go on its
        // own the moment the window took over, but one set to stay open would sit in front
        // of the window that was asked for — and this way the monitor comes down through the
        // same path as every other dismissal rather than on a resign nobody routed.
        closePanel()
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

private extension AppDefaults.PanelDismissal {
    /// `.transient` is AppKit closing the popover on anything outside it — the standard menu
    /// bar arrangement, and what the app has always done. `.applicationDefined` is the same
    /// popover with nobody closing it, which leaves ``StatusItemController`` holding every
    /// dismissal there is: the menu bar icon, `esc`, and Settings.
    ///
    /// Not `.semitransient`: it closes on interaction elsewhere *in this app*, and this app
    /// is a popover plus a settings window that already closes the popover itself. It would
    /// be `.applicationDefined` with a footnote.
    var behavior: NSPopover.Behavior {
        switch self {
        case .onBlur: return .transient
        case .manual: return .applicationDefined
        }
    }
}
