import Foundation
import PRStackCore

/// One poll's worth of GitHub work, in the order the plan puts it.
///
/// Two searches and then the release tracker, sequentially. The order is not incidental:
/// the closed search is bounded by the merges already waiting for a tag, and the tracker's
/// input is that set *plus* whatever the two searches just merged — so a pull request that
/// merged five seconds ago is testable against a tag cut four seconds ago on the same poll
/// it first appears.
///
/// This exists as a type rather than as a few lines in the app because it is the only place
/// that ordering is expressed, and the app layer is the one place CI cannot compile
/// (IMPLEMENTATION_PLAN §1).
public struct GitHubPoll {
    private let client: GitHubClient
    private let tracker: (any ReleaseTracker)?
    private let recovery: MergeCommitRecovery?

    /// `tracker` is optional so a poll can run without release tracking — that is what the
    /// debug dump does by default, and what a build with no `Contents: read` scope would
    /// have to do. `recovery` is the §3 fallback for a merged pull request GitHub reports no
    /// merge commit for; it costs nothing when there is none.
    public init(
        client: GitHubClient,
        tracker: (any ReleaseTracker)? = nil,
        recovery: MergeCommitRecovery? = nil
    ) {
        self.client = client
        self.tracker = tracker
        self.recovery = recovery
    }

    public func run(scope: RepoScope, local: LocalState, now: Date) async throws -> GitHubPollResult {
        let open = try await client.fetchOpenPullRequests(scope: scope)
        let closed = try await client.fetchClosedPullRequests(
            scope: scope,
            unbound: local.unboundMerges,
            now: now
        )

        var pullRequests: [PullRequest] = []
        var seen: Set<PRID> = []
        for pullRequest in open.pullRequests + closed.pullRequests {
            // The two searches are disjoint by construction (`is:open` against
            // `is:closed`), but a pull request merged between the two requests would
            // otherwise appear in both, and derivation would draw it twice.
            guard seen.insert(pullRequest.id).inserted else { continue }
            pullRequests.append(pullRequest)
        }

        // Below 10% of the hourly allowance, everything release-related defers to the next
        // poll — recovery included, since it is a GraphQL request in service of a merge
        // that will not be compared this poll anyway (IMPLEMENTATION_PLAN §3).
        var isBelowFloor = (closed.rateLimit ?? open.rateLimit)?.isBelowFloor ?? false

        // A merged pull request with no merge commit has nothing for a tag to contain, and
        // that does not self-correct: the row would sit at `merged · awaiting release` for
        // good. Recovering the commit from trunk before the merges are recorded is what
        // keeps it bindable (IMPLEMENTATION_PLAN §3).
        var recovered = MergeCommitRecoveryResult.empty
        if let recovery, !isBelowFloor, !MergeCommitRecovery.candidates(among: pullRequests).isEmpty {
            recovered = try await recovery.recover(pullRequests)
            // Its own queries count too: the floor can be crossed here.
            isBelowFloor = recovered.rateLimit?.isBelowFloor ?? isBelowFloor
            if !recovered.commits.isEmpty {
                pullRequests = pullRequests.map { pullRequest in
                    guard let oid = recovered.commits[pullRequest.id] else { return pullRequest }
                    var repaired = pullRequest
                    repaired.mergeCommit = oid
                    return repaired
                }
            }
        }

        // A copy, so the tracker sees the merges this poll found without anything here
        // writing to the caller's state. Merging the result back is the caller's job — it
        // owns the file, and it is the only writer (IMPLEMENTATION_PLAN §3).
        var working = local
        working.recordMerges(from: pullRequests)

        var release = ReleaseTrackerResult.empty
        if let tracker {
            // Below the floor the comparison budget drops to zero as well. A merge that has
            // waited weeks can wait for the reset; spending what is left of the allowance on
            // it would cost the *open* list its next poll, which is the half of the panel
            // that is time-sensitive.
            if isBelowFloor {
                let limit = recovered.rateLimit ?? closed.rateLimit ?? open.rateLimit
                let counts = limit.map { "(\($0.remaining) of \($0.limit) points left)" } ?? ""
                release.warnings = [
                    .releaseTrackingDeferred(reason: "GitHub allowance low \(counts)".trimmingCharacters(in: .whitespaces))
                ]
            } else {
                release = try await tracker.poll(unbound: working.unboundMerges, now: now)
            }
        }

        return GitHubPollResult(
            viewerLogin: open.viewerLogin.isEmpty ? closed.viewerLogin : open.viewerLogin,
            pullRequests: pullRequests,
            open: open,
            closed: closed,
            release: release,
            recovery: recovered
        )
    }
}

/// What ``GitHubPoll/run(scope:local:now:)`` produced: the rows, and everything the caller
/// has to fold back into `LocalState` and the footer.
public struct GitHubPollResult: Equatable, Sendable {
    public var viewerLogin: String
    /// Open first, then closed, de-duplicated. Linear resolution runs over these before
    /// derivation sees them.
    public var pullRequests: [PullRequest]
    public var open: PullRequestFetch
    public var closed: PullRequestFetch
    public var release: ReleaseTrackerResult
    /// Merge commits recovered from trunk. Already applied to ``pullRequests`` — this is
    /// here so the dump and the footer can say that it happened.
    public var recovery: MergeCommitRecoveryResult

    public init(
        viewerLogin: String,
        pullRequests: [PullRequest],
        open: PullRequestFetch,
        closed: PullRequestFetch,
        release: ReleaseTrackerResult = .empty,
        recovery: MergeCommitRecoveryResult = .empty
    ) {
        self.viewerLogin = viewerLogin
        self.pullRequests = pullRequests
        self.open = open
        self.closed = closed
        self.release = release
        self.recovery = recovery
    }

    public var snapshot: RawSnapshot {
        RawSnapshot(viewerLogin: viewerLogin, pullRequests: pullRequests)
    }

    public var warnings: [FetchWarning] {
        open.warnings + closed.warnings + recovery.warnings + release.warnings
    }

    /// GraphQL points across both searches and the tag queries.
    public var pointsSpent: Int {
        open.pointsSpent + closed.pointsSpent + recovery.pointsSpent + release.pointsSpent
    }

    /// The most recent accounting either search reported.
    public var rateLimit: RateLimit? {
        release.rateLimit ?? closed.rateLimit ?? open.rateLimit
    }

    /// True when both searches ran to completion. When false the footer says so rather than
    /// presenting a truncated list as the whole picture.
    public var isComplete: Bool {
        open.stopReason.isComplete && closed.stopReason.isComplete
    }

    /// Folds the poll into local state: the merges it found, then the releases they bound
    /// to. The single writer calls this, and nothing else writes either key.
    public func apply(to local: inout LocalState) {
        local.recordMerges(from: pullRequests)
        local.apply(release)
    }
}
