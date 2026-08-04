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
    case merged
    // Open pull requests only, first match wins.
    case conflicted
    case changesRequested
    case checksFailing
    case blocked(on: PRID)
    case readyToMerge
    case approved
    case inReview

    /// Statuses 4–6. Attention is this set *and* the row not being snoozed — see
    /// ``PanelRow/isAttention``, which is the value anything else should read.
    ///
    /// `blocked` is deliberately excluded: it is the layer below's problem.
    public var isAttentionCandidate: Bool {
        switch self {
        case .conflicted, .changesRequested, .checksFailing: return true
        default: return false
        }
    }

    /// Closed and shipped rows move to Done. `merged` does not: it is still in flight,
    /// waiting for a release tag, and it is what the header's "N shipping" counts.
    public var belongsInDone: Bool {
        switch self {
        case .closed, .shipped: return true
        default: return false
        }
    }

    /// Stable spelling for golden files.
    public var token: String {
        switch self {
        case .closed: return "closed"
        case .shipped(let tag): return "shipped:\(tag)"
        case .merged: return "merged"
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
            .merged,
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
            if case .released(let tag) = releaseStage { return .shipped(tag: tag) }
            return .merged
        case .open:
            break
        }

        // 4–9: open pull requests, first match wins.
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
