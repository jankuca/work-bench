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

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        popover = NSPopover()
        events = EventBus()
        controller = PanelController(source: GitHubPanelSource(), events: events)
        super.init()
        // One sink today, and the list is what makes a `UserNotificationSink` a drop-in
        // later (IMPLEMENTATION_PLAN §1). Registered before anything can publish.
        events.register(IconSink(presenter: self))
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

        // One poll at launch, so the icon means something before the panel has ever been
        // opened. This is not the scheduler: the interval table, sleep and battery are
        // M8, and they replace this call rather than being bolted onto it.
        controller.refresh()
    }

    @objc private func togglePopover(_ sender: Any?) {
        guard let button = statusItem.button else { return }

        if popover.isShown {
            popover.performClose(sender)
            return
        }

        // A status-item popover does not receive key events unless the app is active.
        // Activating on open and letting `.transient` close it on resign is the standard
        // arrangement, and it is what makes the hovered-row keyboard actions possible at
        // M7 without changing how dismissal feels.
        NSApp.activate()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        controller.panelDidOpen()
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
        controller.panelDidClose()
    }
}
