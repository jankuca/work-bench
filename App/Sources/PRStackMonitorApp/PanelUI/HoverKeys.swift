import AppKit
import PRStackCore

/// The keyboard half of the row actions: one local `NSEvent` monitor, live only while the
/// popover is open, acting on the row under the pointer (IMPLEMENTATION_PLAN §5).
///
/// Which key means what, and whether a given row offers it, are `RowAction`'s — in core,
/// table-tested. What is here is the part that needs AppKit: owning the monitor's lifetime
/// and deciding whether an event belongs to us at all.
@MainActor
final class HoverKeyMonitor: NSObject {
    /// The token `addLocalMonitorForEvents` returns. It stays live until removed, so this
    /// is the single place it is stored and the single place it is cleared.
    private var keyMonitor: Any?
    /// The popover's window. Events from anywhere else are not ours: the app is active
    /// while the panel is open, and Settings can be in front of it.
    private weak var window: NSWindow?
    private weak var controller: PanelController?
    /// `(row, index)` for repeated `L` presses. Resets when the hovered row changes — which
    /// it does by itself, on the id — and when the panel closes.
    private var issues = IssueCycle()
    /// Which row the open snooze menu is for. Held because `NSMenuItem`'s action carries
    /// only the duration.
    private var snoozeTarget: PRID?

    /// Starts monitoring, replacing any monitor already running.
    ///
    /// Idempotent by construction: it tears down first, so a re-open can never stack a
    /// second monitor. Getting that wrong leaks one per open and keeps every previous
    /// handler live, so the third open of the panel would dismiss three rows on one `X`.
    func start(on window: NSWindow?, controller: PanelController) {
        stop()
        // No window, no monitor. `handle` scopes events with `event.window === window`, and
        // a nil property would make that succeed for every event that also carries no
        // window — an unscoped monitor acting on keystrokes aimed somewhere else.
        guard let window else { return }
        self.window = window
        self.controller = controller
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Key events are delivered on the main thread, so this asserts an isolation
            // that already holds rather than dispatching. It cannot be a `Task`: the
            // handler has to answer *now* whether it swallowed the event.
            //
            // `?? event` collapses the optional the chaining adds — a monitor that outlives
            // its owner passes everything through rather than eating it.
            MainActor.assumeIsolated { self?.handle(event) ?? event }
        }
    }

    /// Stops monitoring. Safe to call twice, which matters: a popover close and a resign
    /// both fire for the same dismissal, and removing a token twice over-releases.
    func stop() {
        issues.reset()
        snoozeTarget = nil
        window = nil
        guard let token = keyMonitor else { return } // already stopped
        keyMonitor = nil                             // clear BEFORE removing
        NSEvent.removeMonitor(token)
    }

    // No `deinit` teardown: this is owned by ``StatusItemController`` for the life of the
    // process, and every dismissal already routes through ``stop()``. A `deinit` that could
    // only run at termination would be a nonisolated read of main-actor state for no gain.

    // MARK: - Dispatch

    /// `nil` swallows the event; returning it passes it on.
    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let controller, event.window === window else { return event }
        // A modified press belongs to the system or to a menu equivalent, never to the row
        // under the pointer. Shift is not in the list: it is how `X` is typed on some
        // layouts, and `RowAction` matches case-insensitively.
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.isDisjoint(with: [.command, .control, .option, .function]) else { return event }

        guard let character = event.charactersIgnoringModifiers?.first,
              let action = RowAction.forKey(character),
              let row = controller.hoveredRow,
              row.supports(action)
        else { return event }

        perform(action, on: row, controller: controller)
        return nil
    }

    private func perform(_ action: RowAction, on row: RowPresentation, controller: PanelController) {
        switch action {
        case .open:
            controller.open(row: row)
        case .markRead:
            controller.markRead(row.id)
        case .dismiss:
            controller.dismiss(row.id)
        case .openIssue:
            // Advance even when the row links one ticket: the cycle's own bookkeeping is
            // what makes a later press on a *different* row start at its primary.
            if let issue = issues.next(for: row) { controller.open(issue.url) }
        case .snooze:
            presentSnoozeMenu(for: row)
        }
    }

    // MARK: - The snooze menu

    /// `S` opens the duration menu inline — at the pointer, over the row it is about.
    ///
    /// An `NSMenu` rather than something in SwiftUI because it has to appear from a key
    /// press with no view to anchor to, and because this way the key and the row menu offer
    /// one list built from one place.
    private func presentSnoozeMenu(for row: RowPresentation) {
        guard let window, let view = window.contentView else { return }
        snoozeTarget = row.id

        let menu = NSMenu(title: RowAction.snooze.title)
        if row.isSnoozed {
            menu.addItem(item(title: "Wake now", duration: nil))
            menu.addItem(.separator())
        }
        for duration in SnoozeDuration.allCases {
            menu.addItem(item(title: duration.title, duration: duration))
        }

        // `mouseLocationOutsideOfEventStream` is in window coordinates and current as of
        // right now, which is what makes the menu appear under the pointer that is already
        // hovering the row rather than wherever the last mouse *event* was.
        let location = view.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        _ = menu.popUp(positioning: nil, at: location, in: view)
    }

    private func item(title: String, duration: SnoozeDuration?) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(snoozePicked(_:)), keyEquivalent: "")
        item.target = self
        // `representedObject` is a strong `Any?`, which is how the enum survives the trip
        // through the menu — `NSMenuItem` has no payload of its own. Assigned only when
        // there is one, so `Wake now` carries a plain absence rather than a boxed `nil`.
        if let duration { item.representedObject = duration }
        return item
    }

    @objc private func snoozePicked(_ sender: NSMenuItem) {
        guard let controller, let id = snoozeTarget else { return }
        snoozeTarget = nil
        guard let duration = sender.representedObject as? SnoozeDuration else {
            controller.wake(id)
            return
        }
        controller.snooze(id, for: duration)
    }
}
