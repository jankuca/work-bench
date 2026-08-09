import Foundation

/// What can be done to one row, and which key does it.
///
/// The keyboard is an accelerator and never the only path (IMPLEMENTATION_PLAN §5), so this
/// is deliberately not a "key handler": it is the list of a row's actions, each of which
/// happens to have a key. The row menu and the action rotor are built from the same list,
/// which is what keeps the three from drifting apart — a case added here appears in all of
/// them or in none.
///
/// It lives in core rather than in `PanelUI` because availability is a rule about a row and
/// not about a view: dismissal exists on Done rows only, snooze on everything else, and the
/// issue key does nothing on a pull request that links no ticket. All three are pinned by a
/// table test in a Linux container.
public enum RowAction: String, Hashable, Sendable, CaseIterable {
    /// Open the pull request in the browser — and mark it read (PRD §8).
    case open
    case markRead
    case snooze
    /// Done rows only, and permanent.
    case dismiss
    /// The primary Linear issue; repeat presses cycle through the rest (``IssueCycle``).
    case openIssue

    /// The key on the hovered row. Matched case-insensitively, and only with no modifier
    /// held — `⌘R` belongs to the system, not to the row under the pointer.
    public var key: Character {
        switch self {
        case .open: return "\r"
        case .markRead: return "r"
        case .snooze: return "s"
        case .dismiss: return "x"
        case .openIssue: return "l"
        }
    }

    /// The wording in the row menu and the accessibility rotor. `Open` is spelled by the
    /// caller, which is the only one that knows the pull request's number.
    public var title: String {
        switch self {
        case .open: return "Open pull request"
        case .markRead: return "Mark read"
        case .snooze: return "Snooze"
        case .dismiss: return "Dismiss"
        case .openIssue: return "Open issue"
        }
    }

    /// The action a key press means, or `nil` for a key that means nothing here — in which
    /// case the event belongs to whatever else wants it.
    public static func forKey(_ character: Character) -> RowAction? {
        // Compared as strings, not as folded characters: `Character.lowercased()` can
        // return two of them for a scalar nobody here will ever type, and `Character(_:)`
        // traps on that rather than failing to match.
        let lowered = character.lowercased()
        return allCases.first { lowered == String($0.key) }
    }
}

extension RowPresentation {
    /// Whether this row offers the action at all.
    ///
    /// An unavailable action is not a disabled one: it is absent from the menu and from the
    /// rotor, and its key falls through to whoever else is listening. An `Open issue` entry
    /// on a row with no ticket is a rotor entry that does nothing, and a `Mark read` on a
    /// row already read is a control the user cannot tell they pressed.
    public func supports(_ action: RowAction) -> Bool {
        switch action {
        case .open:
            return true
        case .markRead:
            return isUnread
        case .snooze:
            // Snooze suppresses an attention state. A Done row has none and never will —
            // it is finished — so the choice there is dismissal, not silence.
            return !isDismissible
        case .dismiss:
            return isDismissible
        case .openIssue:
            return !issues.isEmpty
        }
    }

    /// The row's actions in menu order.
    public var availableActions: [RowAction] {
        RowAction.allCases.filter(supports)
    }
}

/// Which linked issue the `L` key opens next.
///
/// The state is the **pair** `(row, index)`, never a bare index. Storing the index alone
/// would carry position across rows: hover a pull request with three tickets, press `L`
/// twice, hover a different one, and the next press opens that row's third ticket — or
/// nothing, if it has fewer (IMPLEMENTATION_PLAN §5).
///
/// A value type with no view in it, so the wrap and the reset are testable directly.
public struct IssueCycle: Equatable, Sendable {
    private struct Position: Equatable, Sendable {
        var id: PRID
        /// The index the *next* press opens.
        var index: Int
    }

    private var position: Position?

    public init() {}

    /// The issue this press opens, advancing the cycle. `nil` when the row links none.
    ///
    /// Wraps back to the primary after the last, so `L` on a two-ticket row alternates
    /// rather than going quiet. Hovering a different row starts that row at its own primary.
    public mutating func next(for row: RowPresentation) -> IssueRef? {
        guard !row.issues.isEmpty else {
            position = nil
            return nil
        }
        // The modulo is not belt and braces: the panel re-derives under the pointer, and a
        // poll that drops a ticket while the cycle sits past the new end would otherwise
        // index out of bounds.
        let index = position.map { $0.id == row.id ? $0.index % row.issues.count : 0 } ?? 0
        position = Position(id: row.id, index: (index + 1) % row.issues.count)
        return row.issues[index]
    }

    /// Back to "the next press opens the primary". The popover closing does this, so a
    /// reopened panel never continues a cycle the user cannot see the state of.
    public mutating func reset() {
        position = nil
    }
}
