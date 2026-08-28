import Foundation

/// The single status a row resolves to. Exactly one value per row — never a set.
///
/// The case order below is the precedence order, and terminal states come first
/// deliberately: they are facts about the pull request rather than signals about it. A
/// closed pull request carries whatever stale review metadata it had at close, and must
/// not fall through to a live status (IMPLEMENTATION_PLAN §2).
public enum RowStatus: Hashable, Sendable {
    // Terminal — checked first.
    case closed
    case shipped(tag: String)
    /// Merged into a branch whose release cannot be followed — an integration branch no
    /// pull request owns.
    ///
    /// Terminal, and that is the point rather than a convenience. Nothing further will be
    /// learned about it, so leaving it in the live list would recreate exactly the row that
    /// sits at `merged · awaiting release` forever. It is *not* ``shipped``: no tag has been
    /// shown to contain it, and the phrase names the branch instead of claiming a release.
    case mergedUntracked
    case merged
    // Open pull requests only, first match wins.
    /// Work in progress, only ever present when the user has asked for drafts (§3).
    ///
    /// First among the open statuses, and that ordering is the point rather than an
    /// accident: a draft is not in review, cannot merge, and its conflicts and red checks
    /// are not a verdict on anything that has been offered to anyone. Resolving it ahead of
    /// the three danger statuses is what keeps drafts out of the attention set, and
    /// therefore out of the icon and the events it drives — which is what makes the
    /// preference safe to turn on.
    case draft
    case conflicted
    case changesRequested
    case checksFailing
    case blocked(on: PRID)
    case readyToMerge
    case approved
    case inReview

    /// Statuses 5–7. Attention is this set *and* the row not being snoozed — see
    /// ``PanelRow/isAttention``, which is the value anything else should read.
    ///
    /// `blocked` is deliberately excluded: it is the layer below's problem. So is `draft`,
    /// which is the author's own — see the case's own note.
    public var isAttentionCandidate: Bool {
        switch self {
        case .conflicted, .changesRequested, .checksFailing: return true
        default: return false
        }
    }

    /// Closed and shipped rows move to Done, and so does a merge whose release can no
    /// longer be followed. `merged` does not: it is still in flight, waiting for a release
    /// tag, and it is what the header's "N shipping" counts.
    public var belongsInDone: Bool {
        switch self {
        case .closed, .shipped, .mergedUntracked: return true
        default: return false
        }
    }

    /// Stable spelling for golden files.
    public var token: String {
        switch self {
        case .closed: return "closed"
        case .shipped(let tag): return "shipped:\(tag)"
        case .mergedUntracked: return "mergedUntracked"
        case .merged: return "merged"
        case .draft: return "draft"
        case .conflicted: return "conflicted"
        case .changesRequested: return "changesRequested"
        case .checksFailing: return "checksFailing"
        case .blocked(let parent): return "blocked:\(parent.rawValue)"
        case .readyToMerge: return "readyToMerge"
        case .approved: return "approved"
        case .inReview: return "inReview"
        }
    }

    /// Every status a row can take, used by the exhaustiveness-style invariant tests.
    /// `blocked` and `shipped` carry payloads, so representative values stand in.
    public static func allCases(sampleParent: PRID, sampleTag: String) -> [RowStatus] {
        [
            .closed,
            .shipped(tag: sampleTag),
            .mergedUntracked,
            .merged,
            .draft,
            .conflicted,
            .changesRequested,
            .checksFailing,
            .blocked(on: sampleParent),
            .readyToMerge,
            .approved,
            .inReview
        ]
    }
}

/// What gets diffed between polls — raw status alone is not enough.
///
/// A pull request that goes `checksFailing` *during* its snooze would write
/// `checksFailing` into the previous model, so at wake time the status is unchanged and
/// no transition exists to detect. With the pair, the row moves from
/// `(checksFailing, suppressed)` to `(checksFailing, active)` — a real transition, which
/// is what lets M4 emit the withheld attention event exactly once, at wake.
public struct EffectiveState: Hashable, Sendable {
    public let status: RowStatus
    public let isSuppressed: Bool

    public init(status: RowStatus, isSuppressed: Bool) {
        self.status = status
        self.isSuppressed = isSuppressed
    }
}

enum RowStatusResolver {
    /// Resolves the one status for a pull request. `parent` is its open stack parent, if any.
    static func resolve(
        pullRequest: PullRequest,
        releaseStage: ReleaseStage,
        parent: PRID?
    ) -> RowStatus {
        // 1–3: terminal states, before any live signal.
        switch pullRequest.state {
        case .closed:
            return .closed
        case .merged:
            switch releaseStage {
            case .released(let tag):
                return .shipped(tag: tag)
            // Merged into a pull request that was closed without merging. The work is not
            // going anywhere, so the row is finished — as plain `closed`, since that is
            // what became of the change. The phrase says which pull request took it down.
            case .mergedIntoAbandonedPullRequest:
                return .closed
            case .mergedIntoBranch:
                return .mergedUntracked
            default:
                return .merged
            }
        case .open:
            break
        }

        // 4–10: open pull requests, first match wins.
        //
        // A draft resolves before every live signal below it — see ``RowStatus/draft``. It
        // is only ever reached when the user has turned drafts on, because with the
        // preference off the search never returns one.
        if pullRequest.isDraft { return .draft }
        if pullRequest.mergeable == .conflicting { return .conflicted }
        if pullRequest.reviewDecision == .changesRequested { return .changesRequested }
        if pullRequest.checks.isFailing { return .checksFailing }
        if let parent { return .blocked(on: parent) }
        if pullRequest.reviewDecision == .approved {
            let ready = pullRequest.checks.isPassing && pullRequest.mergeable == .mergeable
            return ready ? .readyToMerge : .approved
        }
        return .inReview
    }
}
