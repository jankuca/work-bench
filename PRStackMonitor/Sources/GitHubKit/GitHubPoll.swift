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

    /// `tracker` is optional so a poll can run without release tracking — that is what the
    /// debug dump does by default, and what a build with no `Contents: read` scope would
    /// have to do.
    public init(client: GitHubClient, tracker: (any ReleaseTracker)? = nil) {
        self.client = client
        self.tracker = tracker
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

        // A copy, so the tracker sees the merges this poll found without anything here
        // writing to the caller's state. Merging the result back is the caller's job — it
        // owns the file, and it is the only writer (IMPLEMENTATION_PLAN §3).
        var working = local
        working.recordMerges(from: pullRequests)

        var release = ReleaseTrackerResult.empty
        if let tracker {
            release = try await tracker.poll(unbound: working.unboundMerges, now: now)
        }

        return GitHubPollResult(
            viewerLogin: open.viewerLogin.isEmpty ? closed.viewerLogin : open.viewerLogin,
            pullRequests: pullRequests,
            open: open,
            closed: closed,
            release: release
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

    public init(
        viewerLogin: String,
        pullRequests: [PullRequest],
        open: PullRequestFetch,
        closed: PullRequestFetch,
        release: ReleaseTrackerResult = .empty
    ) {
        self.viewerLogin = viewerLogin
        self.pullRequests = pullRequests
        self.open = open
        self.closed = closed
        self.release = release
    }

    public var snapshot: RawSnapshot {
        RawSnapshot(viewerLogin: viewerLogin, pullRequests: pullRequests)
    }

    public var warnings: [FetchWarning] {
        open.warnings + closed.warnings + release.warnings
    }

    /// GraphQL points across both searches and the tag queries.
    public var pointsSpent: Int {
        open.pointsSpent + closed.pointsSpent + release.pointsSpent
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
