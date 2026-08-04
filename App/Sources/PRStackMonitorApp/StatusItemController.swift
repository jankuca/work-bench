import AppKit
import SwiftUI

/// Owns the menu bar item and the popover attached to it.
///
/// `NSStatusItem` + `NSPopover` rather than `MenuBarExtra`, per
/// docs/IMPLEMENTATION_PLAN.md §1: M4 needs per-frame control of the icon (badge count
/// drawn into the image, dashed disconnected glyph) and predictable popover dismissal,
/// and `MenuBarExtra(.window)` makes both awkward.
///
/// M0 wires up the shell only. ``makeIcon()`` becomes the drawn four-state glyph at M4,
/// and the popover's content view becomes the real panel at M3.
final class StatusItemController: NSObject {
    private let statusItem: NSStatusItem
    private let popover: NSPopover

    override init() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        popover = NSPopover()
        super.init()
        configure()
    }

    private func configure() {
        // 440 pt content width is the panel geometry from design iteration 2a (§5).
        popover.contentSize = NSSize(width: 440, height: 260)
        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = NSHostingController(rootView: PlaceholderPanelView())

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
