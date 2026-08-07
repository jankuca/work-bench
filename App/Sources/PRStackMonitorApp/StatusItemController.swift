import AppKit
import SwiftUI

/// Owns the menu bar item and the popover attached to it.
///
/// `NSStatusItem` + `NSPopover` rather than `MenuBarExtra`, per
/// docs/IMPLEMENTATION_PLAN.md §1: M4 needs per-frame control of the icon (badge count
/// drawn into the image, dashed disconnected glyph) and predictable popover dismissal,
/// and `MenuBarExtra(.window)` makes both awkward.
///
/// ``makeIcon()`` becomes the drawn four-state glyph at M4.
@MainActor
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private let controller: PanelController

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        popover = NSPopover()
        controller = PanelController(source: GitHubPanelSource())
        super.init()
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
        button.image = StatusItemController.makeIcon()
        button.imagePosition = .imageOnly
        button.target = self
        button.action = #selector(togglePopover(_:))
        button.setAccessibilityLabel("Pull requests")
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

    /// A template SF Symbol stands in until M4 draws the glyph and its four states.
    /// Template rendering is what makes it invert correctly on dark menu bars.
    private static func makeIcon() -> NSImage? {
        let image = NSImage(
            systemSymbolName: "square.stack.3d.up",
            accessibilityDescription: "Pull requests"
        )
        image?.isTemplate = true
        return image
    }
}

extension StatusItemController: NSPopoverDelegate {
    func popoverDidClose(_ notification: Notification) {
        controller.panelDidClose()
    }
}
