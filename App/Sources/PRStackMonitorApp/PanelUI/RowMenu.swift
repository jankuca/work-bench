import AppKit
import PRStackCore

/// The row menu and the snooze menu, built as `NSMenu`s at the moment they are asked for.
///
/// One builder for every way in: the ⋯ button, a right-click on the row, and the `S` key.
/// The layout is the same from all three — the times, the events, then the `Until merged`
/// and `Until released` submenus, each listing the row's own stack before everything else.
///
/// Built **on demand**, not declared in each row's SwiftUI body. Those submenus list every
/// other pull request in flight, so a row's menu grows with the list — and a SwiftUI `Menu`
/// or `.contextMenu` evaluates its contents every time the row renders. Two of them per row
/// made a render of the panel quadratic in its length: at 40 rows that was thousands of menu
/// items rebuilt on every hover change, which is what made a long list stutter as it
/// scrolled under the pointer. Here a menu costs something only when it is opened, and only
/// for the one row it is about.
@MainActor
final class RowMenuPresenter: NSObject {
    private weak var controller: PanelController?
    /// The pull requests the open menu acts on: the row's own, or every layer of a
    /// collapsed row. Held because `NSMenuItem`'s action carries only its represented
    /// object.
    private var targets: [PRID] = []

    init(controller: PanelController) {
        self.controller = controller
    }

    /// What an item does, carried in its `representedObject`.
    private enum Command {
        case markRead
        case openIssue(URL)
        case wake
        case snooze(SnoozeOption)
        case dismiss
        /// One layer of a collapsed row, on its own.
        case openMember(CollapsedMember)
        case wakeMember(PRID)
    }

    /// The full row menu, at the pointer: everything the row offers, in `RowAction`'s order.
    ///
    /// `Open` is not in it: the row itself is the affordance for that, and a menu entry for
    /// "what clicking already does" is a line of noise on every row.
    ///
    /// A collapsed row ends with one submenu per layer folded into it, top-most first, so
    /// each can still be opened or woken without waking the rest.
    func presentRowMenu(for row: RowPresentation) {
        let menu = NSMenu(title: row.title)
        if row.supports(.markRead) {
            menu.addItem(item(RowAction.markRead.title, .markRead))
        }
        for issue in row.issues {
            menu.addItem(item("Open \(issue.identifier)", .openIssue(issue.url)))
        }
        if row.supports(.snooze) {
            if row.isSnoozed {
                menu.addItem(item(row.wakeTitle, .wake))
            }
            let parent = NSMenuItem(title: RowAction.snooze.title, action: nil, keyEquivalent: "")
            parent.submenu = snoozeMenu(for: row, includesWake: false)
            menu.addItem(parent)
        }
        if row.isCollapsed {
            menu.addItem(.separator())
            for member in row.collapsedMembers {
                menu.addItem(memberItem(member))
            }
        }
        if row.isDismissible {
            if !menu.items.isEmpty { menu.addItem(.separator()) }
            menu.addItem(item(RowAction.dismiss.title, .dismiss))
        }
        present(menu, for: row.memberIDs)
    }

    /// The snooze menu on its own, at the pointer — what `S` opens.
    func presentSnoozeMenu(for row: RowPresentation) {
        present(snoozeMenu(for: row, includesWake: true), for: row.memberIDs)
    }

    // MARK: - Building

    private func snoozeMenu(for row: RowPresentation, includesWake: Bool) -> NSMenu {
        let menu = NSMenu(title: RowAction.snooze.title)
        if includesWake, row.isSnoozed {
            menu.addItem(item(row.wakeTitle, .wake))
            menu.addItem(.separator())
        }
        for option in SnoozeOption.durations {
            menu.addItem(item(option.title, .snooze(option)))
        }
        menu.addItem(.separator())
        for option in SnoozeOption.events {
            menu.addItem(item(option.title, .snooze(option)))
        }
        let mergeTargets = row.mergeTargets
        let releaseTargets = row.releaseTargets
        if !mergeTargets.isEmpty || !releaseTargets.isEmpty {
            menu.addItem(.separator())
        }
        if !mergeTargets.isEmpty {
            menu.addItem(submenu(title: "Until merged", targets: mergeTargets) { .merged($0) })
        }
        if !releaseTargets.isEmpty {
            menu.addItem(submenu(title: "Until released", targets: releaseTargets) { .released($0) })
        }
        return menu
    }

    /// The row's own stack first, then a separator, then every other pull request in flight.
    private func submenu(
        title: String,
        targets: [SnoozeTarget],
        option: (PRID) -> SnoozeOption
    ) -> NSMenuItem {
        let parent = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: title)
        let stack = targets.filter(\.isStackMember)
        let others = targets.filter { !$0.isStackMember }
        for target in stack {
            menu.addItem(item(target.menuTitle, .snooze(option(target.id))))
        }
        if !stack.isEmpty && !others.isEmpty {
            menu.addItem(.separator())
        }
        for target in others {
            menu.addItem(item(target.menuTitle, .snooze(option(target.id))))
        }
        parent.submenu = menu
        return parent
    }

    /// `#1402 Title ▸ Open · Wake now`, for one layer of a collapsed row.
    private func memberItem(_ member: CollapsedMember) -> NSMenuItem {
        let parent = NSMenuItem(title: member.menuTitle, action: nil, keyEquivalent: "")
        let menu = NSMenu(title: member.menuTitle)
        menu.addItem(item(RowAction.open.title, .openMember(member)))
        menu.addItem(item("Wake now", .wakeMember(member.id)))
        parent.submenu = menu
        return parent
    }

    private func item(_ title: String, _ command: Command) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(picked(_:)), keyEquivalent: "")
        item.target = self
        // `representedObject` is a strong `Any?`, which is how the enum survives the trip
        // through the menu — `NSMenuItem` has no payload of its own.
        item.representedObject = command
        return item
    }

    // MARK: - Presenting

    /// Pops the menu up under the pointer, which is on the row (or its ⋯) for every way in.
    ///
    /// In screen coordinates — `in: nil` — so no window or anchor view is needed: the `S`
    /// key has none, and the ⋯ button is a SwiftUI view with no `NSView` of its own.
    /// `popUp` runs the menu's tracking loop and returns once it closes.
    private func present(_ menu: NSMenu, for ids: [PRID]) {
        targets = ids
        _ = menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }

    @objc private func picked(_ sender: NSMenuItem) {
        guard let controller, !targets.isEmpty,
              let command = sender.representedObject as? Command
        else { return }
        let ids = targets
        targets = []
        switch command {
        case .markRead: controller.markRead(ids)
        case .openIssue(let url): controller.open(url)
        case .wake: controller.wake(ids)
        case .snooze(let option): controller.snooze(ids, option)
        // Only ever offered on a Done row, which is never collapsed: one id.
        case .dismiss: for id in ids { controller.dismiss(id) }
        case .openMember(let member): controller.open(member: member)
        case .wakeMember(let id): controller.wake(id)
        }
    }
}
