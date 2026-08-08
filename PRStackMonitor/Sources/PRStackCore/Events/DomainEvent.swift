import Foundation

/// Which integration an event is about, for the events that concern the connection
/// rather than a pull request.
public enum EventSource: String, Hashable, Sendable, CaseIterable {
    case github
    case linear
}

/// A transition derivation observed between two consecutive models.
///
/// Events are a *by-product* of derivation, not a second mechanism: they are the diff
/// between the model just built and the one before it, so they are as pure and as
/// testable as the model itself (IMPLEMENTATION_PLAN §1). v1 registers a single sink —
/// the icon updater — but the list below is the one a notification sink would consume,
/// which is why it is pinned by tests before that sink exists.
public enum DomainEvent: Hashable, Sendable {
    /// A merged pull request's commit turned up in a matching release tag.
    case reachedProduction(PRID)
    case changesRequested(PRID)
    case checksFailed(PRID)
    /// Approved, checks green, no conflict — the row is now the user's to merge.
    case becameMergeable(PRID)
    /// How many comments arrived since the previous model, not the total.
    case newComments(PRID, count: Int)
    case connectionLost(EventSource)

    public var kind: DomainEventKind {
        switch self {
        case .reachedProduction: return .reachedProduction
        case .changesRequested: return .changesRequested
        case .checksFailed: return .checksFailed
        case .becameMergeable: return .becameMergeable
        case .newComments: return .newComments
        case .connectionLost: return .connectionLost
        }
    }

    /// The row this is about, when it is about a row at all.
    public var pullRequest: PRID? {
        switch self {
        case .reachedProduction(let id),
             .changesRequested(let id),
             .checksFailed(let id),
             .becameMergeable(let id):
            return id
        case .newComments(let id, _):
            return id
        case .connectionLost:
            return nil
        }
    }

    /// Stable spelling, for assertions and for the debug log a sink writes.
    public var token: String {
        switch self {
        case .newComments(let id, let count): return "newComments(\(id.rawValue),\(count))"
        case .connectionLost(let source): return "connectionLost(\(source.rawValue))"
        default: return "\(kind.rawValue)(\(pullRequest?.rawValue ?? "-"))"
        }
    }
}

/// The event *types*, without their payloads.
///
/// This is the key the per-event Settings toggles are stored under, and the granularity
/// a future notification sink is switched on and off at. Kept separate from
/// ``DomainEvent`` so a toggle survives a payload changing shape.
public enum DomainEventKind: String, Hashable, Sendable, CaseIterable {
    case reachedProduction
    case changesRequested
    case checksFailed
    case becameMergeable
    case newComments
    case connectionLost

    /// Whether a snoozed row withholds this.
    ///
    /// Snooze silences "this needs you", not "this finished" (IMPLEMENTATION_PLAN §1).
    /// ``reachedProduction`` is the finishing one, so it fires on a snoozed row like any
    /// other; the rest wait for the row to wake.
    public var isWithheldBySnooze: Bool {
        switch self {
        case .changesRequested, .checksFailed, .becameMergeable, .newComments:
            return true
        case .reachedProduction, .connectionLost:
            return false
        }
    }

    /// The wording of the per-event toggle. Settings is M7; the strings live here so the
    /// toggle list is derived from the event set rather than hand-maintained beside it.
    public var settingsTitle: String {
        switch self {
        case .reachedProduction: return "A pull request reaches production"
        case .changesRequested: return "Changes are requested"
        case .checksFailed: return "Checks fail"
        case .becameMergeable: return "A pull request becomes mergeable"
        case .newComments: return "New comments arrive"
        case .connectionLost: return "A connection is lost"
        }
    }
}

extension DomainEvent {
    /// Connection events, diffed over health rather than over the model.
    ///
    /// These are the one kind that cannot come out of ``Derivation``: a snapshot the app
    /// failed to fetch produces no rows to diff, and the previous model is unchanged
    /// precisely *because* the poll failed. So the transition lives on ``PanelStatus``,
    /// and is emitted by whoever owns it — `SyncEngine` at M8, the panel controller until
    /// then.
    ///
    /// `previous == nil` emits nothing, for the same reason a cold-start derivation does:
    /// a relaunch must not replay history as fresh activity.
    public static func connectionEvents(from previous: PanelStatus?, to current: PanelStatus) -> [DomainEvent] {
        guard let previous else { return [] }
        // Only a *loss* is an event. Starting up unconfigured, or staying unreachable
        // across a dozen polls, is a state the footer already reports; announcing it on
        // every poll would make the one transition worth hearing about indistinguishable
        // from the steady state.
        guard previous.github.isConnected, !current.github.isConnected else { return [] }
        return [.connectionLost(.github)]
    }
}
