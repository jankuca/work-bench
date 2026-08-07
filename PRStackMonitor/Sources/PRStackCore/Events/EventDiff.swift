import Foundation

/// The diff between two consecutive models, expressed as ``DomainEvent``s.
///
/// Two rules shape everything here.
///
/// **A row with no previous emits nothing.** Cold start is only the general case of this:
/// `previous == nil` yields an empty list, so a relaunch never replays history as fresh
/// activity, and a pull request appearing for the first time — which on the first poll is
/// *every* pull request — is not a transition either. The unread dot is what says "new to
/// you"; it comes from the persisted read digests and is a separate mechanism.
///
/// **Effective state is what gets diffed, not raw status.** A pull request that goes
/// `checksFailing` during its snooze writes `checksFailing` into the previous model, so at
/// wake time the raw status is unchanged and no transition exists to detect. Diffing the
/// *active* status — the status a row has only while it is awake — turns the wake itself
/// into the transition, which emits the withheld event exactly once (IMPLEMENTATION_PLAN
/// §1).
enum EventDiff {
    static func events(previous: PanelModel?, current: PanelModel) -> [DomainEvent] {
        guard let previous else { return [] }

        // Model order, not dictionary order: the event list is compared byte for byte in
        // tests, and a sink that batches them renders them in the order they arrive.
        var events: [DomainEvent] = []
        for row in current.rows {
            guard let before = previous.row(row.id) else { continue }
            events.append(contentsOf: self.events(before: before, after: row))
        }
        return events
    }

    private static func events(before: PanelRow, after: PanelRow) -> [DomainEvent] {
        var events: [DomainEvent] = []

        // Lifecycle first, and outside the suppression check: a snoozed pull request that
        // ships has still shipped.
        if case .shipped = after.status, !isShipped(before.status) {
            events.append(.reachedProduction(after.id))
        }

        let activeBefore = activeStatus(before)
        // Snoozed on both sides is `nil` on both sides, which is how the withholding falls
        // out of the comparison rather than needing a rule of its own.
        if let activeAfter = activeStatus(after), activeAfter != activeBefore {
            switch activeAfter {
            case .changesRequested:
                events.append(.changesRequested(after.id))
            case .checksFailing:
                events.append(.checksFailed(after.id))
            case .readyToMerge:
                events.append(.becameMergeable(after.id))
            default:
                // Every other status is either terminal, handled above, or not something
                // to be told about — `inReview` and `blocked` are the absence of news.
                break
            }
        }

        // Comments are counted rather than diffed through the status, and they are gated
        // on the row being awake *now*. Comments that arrived during a snooze are not
        // announced at wake: the previous model is rewritten on every poll, including the
        // sleeping ones, so the delta at wake covers the last poll only. That is the
        // intended reading — the row's unread dot already carries "something happened
        // here", and a snooze is a request not to be told about it.
        if !after.isSuppressed {
            let delta = after.pullRequest.commentCount - before.pullRequest.commentCount
            if delta > 0 {
                events.append(.newComments(after.id, count: delta))
            }
        }

        return events
    }

    /// The status a row has while it is awake, and `nil` while it is snoozed.
    ///
    /// This is ``EffectiveState`` viewed as one comparable value: a row moving from
    /// `(checksFailing, suppressed)` to `(checksFailing, active)` moves from `nil` to
    /// `checksFailing`, which is the transition the wake has to produce.
    private static func activeStatus(_ row: PanelRow) -> RowStatus? {
        row.isSuppressed ? nil : row.status
    }

    private static func isShipped(_ status: RowStatus) -> Bool {
        if case .shipped = status { return true }
        return false
    }
}
