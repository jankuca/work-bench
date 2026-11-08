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
    /// The right-click monitor, live alongside ``keyMonitor`` and owned the same way.
    private var clickMonitor: Any?
    /// What `esc` calls. A closure rather than a reference to the popover, so this class goes
    /// on knowing nothing about windows beyond the one it scopes events to.
    private var onCancel: () -> Void = {}

    /// `esc`. By key code rather than by character, because that is the one spelling of it
    /// that does not depend on the layout.
    private static let escapeKeyCode: UInt16 = 53

    /// Starts monitoring, replacing any monitor already running.
    ///
    /// Idempotent by construction: it tears down first, so a re-open can never stack a
    /// second monitor. Getting that wrong leaks one per open and keeps every previous
    /// handler live, so the third open of the panel would dismiss three rows on one `X`.
    func start(on window: NSWindow?, controller: PanelController, onCancel: @escaping () -> Void = {}) {
        stop()
        // No window, no monitor. `handle` scopes events with `event.window === window`, and
        // a nil property would make that succeed for every event that also carries no
        // window — an unscoped monitor acting on keystrokes aimed somewhere else.
        guard let window else { return }
        self.window = window
        self.controller = controller
        self.onCancel = onCancel
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Key events are delivered on the main thread, so this asserts an isolation
            // that already holds rather than dispatching. It cannot be a `Task`: the
            // handler has to answer *now* whether it swallowed the event.
            //
            // What crosses the boundary is the `Bool`, not the event: `assumeIsolated`
            // requires a `Sendable` result and `NSEvent`'s conformance is unavailable, so
            // the event is re-attached out here where it never left the main thread.
            //
            // `?? false` collapses the optional the chaining adds — a monitor that outlives
            // its owner passes everything through rather than eating it.
            let swallowed = MainActor.assumeIsolated { self?.handle(event) ?? false }
            return swallowed ? nil : event
        }
        // The row's right-click menu. A SwiftUI `.contextMenu` per row would evaluate its
        // contents — every other pull request, twice over — on every render of every row;
        // see ``RowMenuPresenter``. The row under the pointer is already known, so one
        // monitor can build the menu for it at the moment it is asked for.
        clickMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.rightMouseDown, .leftMouseDown]
        ) { [weak self] event in
            let swallowed = MainActor.assumeIsolated { self?.handleClick(event) ?? false }
            return swallowed ? nil : event
        }
    }

    /// Stops monitoring. Safe to call twice, which matters: a popover close and a resign
    /// both fire for the same dismissal, and removing a token twice over-releases.
    func stop() {
        issues.reset()
        if let token = clickMonitor {
            clickMonitor = nil
            NSEvent.removeMonitor(token)
        }
        window = nil
        onCancel = {}
        guard let token = keyMonitor else { return } // already stopped
        keyMonitor = nil                             // clear BEFORE removing
        NSEvent.removeMonitor(token)
    }

    // No `deinit` teardown: this is owned by ``StatusItemController`` for the life of the
    // process, and every dismissal already routes through ``stop()``. A `deinit` that could
    // only run at termination would be a nonisolated read of main-actor state for no gain.

    // MARK: - Dispatch

    /// `true` swallows the event; `false` passes it on.
    private func handle(_ event: NSEvent) -> Bool {
        guard event.window === window else { return false }
        // A modified press belongs to the system or to a menu equivalent, never to the row
        // under the pointer. Shift is not in the list: it is how `X` is typed on some
        // layouts, and `RowAction` matches case-insensitively.
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard modifiers.isDisjoint(with: [.command, .control, .option, .function]) else { return false }

        // Before the row actions, and without needing a row: `esc` is about the panel rather
        // than about whatever the pointer happens to be over. A transient popover closes on
        // it by itself and this is the same dismissal a fraction earlier; one set to stay
        // open has nothing else that would.
        if event.keyCode == Self.escapeKeyCode {
            onCancel()
            return true
        }

        guard let controller,
              let character = event.charactersIgnoringModifiers?.first,
              let action = RowAction.forKey(character),
              let row = controller.hoveredRow,
              row.supports(action)
        else { return false }

        perform(action, on: row, controller: controller)
        return true
    }

    /// A right-click, or a control-click, on a row opens that row's menu. Everything else
    /// — and any click with no row under it — passes through.
    private func handleClick(_ event: NSEvent) -> Bool {
        guard event.window === window else { return false }
        let isContextClick = event.type == .rightMouseDown
            || (event.type == .leftMouseDown && event.modifierFlags.contains(.control))
        guard isContextClick, let controller, let row = controller.hoveredRow else { return false }
        controller.rowMenus.presentRowMenu(for: row)
        return true
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
            controller.rowMenus.presentSnoozeMenu(for: row)
        }
    }
}
