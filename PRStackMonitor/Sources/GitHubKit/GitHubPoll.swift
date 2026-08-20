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
/// Ahead of all of it, optionally, is the priority refresh: one request for the rows the
/// panel is already showing (``refreshKnown(_:scope:includesDrafts:local:now:)``). It is a
/// separate call rather than a step inside ``run(scope:includesDrafts:local:refreshed:now:)``
/// because something has to happen to its answer *between* the two — the rows are resolved
/// against Linear and drawn — and that is the app's business, not this type's. What stays
/// here is the part that has to be right whoever calls it: the refresh's rows are handed
/// back to `run`, which merges them into the sweep's result, so a search that stopped at
/// the page cap cannot drop a row the panel has on screen.
///
/// This exists as a type rather than as a few lines in the app because it is the only place
/// that ordering is expressed, and the app layer is the one place CI cannot compile
/// (IMPLEMENTATION_PLAN §1).
public struct GitHubPoll {
    private let client: GitHubClient
    private let tracker: (any ReleaseTracker)?
    private let recovery: MergeCommitRecovery?
    private let priority: PriorityRefresh?

    /// `tracker` is optional so a poll can run without release tracking — that is what the
    /// debug dump does by default, and what a build with no `Contents: read` scope would
    /// have to do. `recovery` is the §3 fallback for a merged pull request GitHub reports no
    /// merge commit for; it costs nothing when there is none. `priority` is the refresh
    /// above; without one a poll is exactly what it was before it existed.
    public init(
        client: GitHubClient,
        tracker: (any ReleaseTracker)? = nil,
        recovery: MergeCommitRecovery? = nil,
        priority: PriorityRefresh? = nil
    ) {
        self.client = client
        self.tracker = tracker
        self.recovery = recovery
        self.priority = priority
    }

    /// Phase one: the rows named by `ids`, refreshed in one request.
    ///
    /// Answers `.empty` — not an error — when there is no refresher, nothing known, or
    /// nothing in scope. A caller that always calls this and passes whatever it gets to
    /// ``run(scope:includesDrafts:local:refreshed:now:)`` behaves correctly in every one of
    /// those cases.
    ///
    /// `local` is read for one thing: the closed search's lower bound, which is what decides
    /// whether a pull request that has already closed still belongs in the panel. Passing
    /// the same `local` and `now` to both halves is what keeps the refresh and the sweep
    /// agreeing about where that line is.
    public func refreshKnown(
        _ ids: [PRID],
        scope: RepoScope,
        includesDrafts: Bool = false,
        local: LocalState,
        now: Date
    ) async throws -> KnownPullRequestFetch {
        guard let priority, !ids.isEmpty else { return .empty }
        return try await priority.refresh(
            ids,
            scope: scope,
            includesDrafts: includesDrafts,
            closedSince: MergedPullRequestSearch.lowerBound(unbound: local.unboundMerges, now: now)
        )
    }

    /// `includesDrafts` is the Settings preference, read once per poll and applied to both
    /// searches so the two halves cannot disagree about what a poll covers.
    ///
    /// `refreshed` is phase one's answer, as ``refreshKnown(_:scope:includesDrafts:local:now:)``
    /// returned it — already filtered to rows the panel may show. Passing `.empty` runs the
    /// poll exactly as it ran before the refresh existed.
    ///
    /// `resuming` is where the last poll's searches stopped, if they stopped short. A poll
    /// that resumes covers the *rest* of the list rather than the whole of it, so its result
    /// is a patch over what the caller already has and says so
    /// (``GitHubPollResult/isResumed``); handing it back ``SweepCursors/none`` is a poll that
    /// starts at page one, which is every poll after a sweep that finished.
    ///
    /// `progress` is the first-sync stepper's reporter, threaded to the two searches (which
    /// report their own running counts) and used here for the release-tags step. Optional,
    /// and nil on every steady-state poll: with no reporter this runs exactly as it did
    /// before the stepper existed.
    public func run(
        scope: RepoScope,
        includesDrafts: Bool = false,
        local: LocalState,
        refreshed: KnownPullRequestFetch = .empty,
        resuming cursors: SweepCursors = .none,
        now: Date,
        progress: SyncProgressReporter? = nil
    ) async throws -> GitHubPollResult {
        // One budget for the whole poll rather than one per search. Each search used to be
        // given the full allowance, and the priority refresh none at all, so a poll could
        // spend three times what IMPLEMENTATION_PLAN §3's budget says before any bound
        // noticed. The refresh has already spent its share by the time this is called.
        var budget = PointBudget(points: client.pointBudget)
        budget.record(refreshed.pointsSpent)

        let fingerprint = GitHubPoll.fingerprint(
            scope: scope,
            includesDrafts: includesDrafts,
            local: local,
            now: now
        )
        let resumed = cursors.usable(for: fingerprint)

        let open = try await client.fetchOpenPullRequests(
            scope: scope,
            includesDrafts: includesDrafts,
            startingAfter: resumed.open,
            budget: budget,
            progress: progress
        )
        budget.record(open.pointsSpent)
        let closed = try await client.fetchClosedPullRequests(
            scope: scope,
            includesDrafts: includesDrafts,
            unbound: local.unboundMerges,
            now: now,
            startingAfter: resumed.closed,
            budget: budget,
            progress: progress
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

        // Then whatever the priority refresh found that the searches did not return.
        //
        // Ordinarily that is nothing — the refresh only ever asks for rows the searches
        // cover, and a search that ran to completion returns every one of them, so the
        // dedup above discards the older copy of each. It is not nothing when a search
        // stopped early: at the page cap, at the point budget, or at the rate limit floor,
        // the sweep comes back missing rows that are on screen right now, and replacing the
        // panel with it would make them vanish for no reason the user can see. They are
        // kept, one poll old at worst, until a sweep that reaches them says otherwise.
        for pullRequest in refreshed.pullRequests {
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
                // Deferred, so the step never runs and never shows.
                progress?(.skipped(.releaseTags))
                let limit = recovered.rateLimit ?? closed.rateLimit ?? open.rateLimit
                let counts = limit.map { "(\($0.remaining) of \($0.limit) points left)" } ?? ""
                release.warnings = [
                    .releaseTrackingDeferred(reason: "GitHub allowance low \(counts)".trimmingCharacters(in: .whitespaces))
                ]
            } else {
                let pending = working.unboundMerges
                // The step only exists when there is a merge to place; an empty poll runs the
                // tracker (it returns quickly) but shows nothing for it.
                if pending.isEmpty {
                    progress?(.skipped(.releaseTags))
                } else {
                    progress?(.began(.releaseTags))
                    progress?(.advanced(.releaseTags, found: pending.count, total: pending.count))
                }
                release = try await tracker.poll(unbound: pending, now: now)
                if !pending.isEmpty { progress?(.finished(.releaseTags)) }
            }
        }

        var viewerLogin = open.viewerLogin.isEmpty ? closed.viewerLogin : open.viewerLogin
        if viewerLogin.isEmpty { viewerLogin = refreshed.viewerLogin }

        return GitHubPollResult(
            viewerLogin: viewerLogin,
            pullRequests: pullRequests,
            open: open,
            closed: closed,
            release: release,
            recovery: recovered,
            priority: refreshed,
            resumedFrom: resumed,
            cursors: SweepCursors.next(
                fingerprint: fingerprint,
                open: open.nextCursor,
                closed: closed.nextCursor,
                after: resumed
            )
        )
    }

    /// What makes two polls' searches the same searches, for
    /// ``SweepCursors/usable(for:)``.
    ///
    /// The query texts themselves rather than a hash of the inputs behind them: they are
    /// what GitHub's cursors are positions in, so anything that changes a query — a
    /// repository checked in Settings, the drafts preference, the closed search's lower bound
    /// moving onto a new day as an old merge finally ships — changes this too, and any cursor
    /// held from before it is discarded rather than applied to a list it no longer describes.
    static func fingerprint(
        scope: RepoScope,
        includesDrafts: Bool,
        local: LocalState,
        now: Date
    ) -> String {
        let open = SearchQuery.build(
            scope: scope,
            includesDrafts: includesDrafts,
            extraQualifiers: MergedPullRequestSearch.openQualifiers
        )
        let closed = SearchQuery.build(
            scope: scope,
            includesDrafts: includesDrafts,
            extraQualifiers: MergedPullRequestSearch.qualifiers(
                unbound: local.unboundMerges,
                now: now
            )
        )
        return [open?.text ?? "", closed?.text ?? ""].joined(separator: " | ")
    }
}

/// What ``GitHubPoll/run(scope:includesDrafts:local:now:)`` produced: the rows, and
/// everything the caller has to fold back into `LocalState` and the footer.
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
    /// The priority refresh this poll ran ahead of the searches, already merged into
    /// ``pullRequests``. Here for its points, its warnings and the diagnostics.
    public var priority: KnownPullRequestFetch
    /// Where this poll's searches picked up, when they picked up rather than started.
    public var resumedFrom: SweepCursors
    /// Where they stopped, for the next poll to resume from — ``SweepCursors/none`` when both
    /// reached the end and there is nothing to carry forward.
    public var cursors: SweepCursors

    public init(
        viewerLogin: String,
        pullRequests: [PullRequest],
        open: PullRequestFetch,
        closed: PullRequestFetch,
        release: ReleaseTrackerResult = .empty,
        recovery: MergeCommitRecoveryResult = .empty,
        priority: KnownPullRequestFetch = .empty,
        resumedFrom: SweepCursors = .none,
        cursors: SweepCursors = .none
    ) {
        self.viewerLogin = viewerLogin
        self.pullRequests = pullRequests
        self.open = open
        self.closed = closed
        self.release = release
        self.recovery = recovery
        self.priority = priority
        self.resumedFrom = resumedFrom
        self.cursors = cursors
    }

    /// Whether this poll carried on from where the last one stopped, and therefore never
    /// looked at the pages before that point.
    ///
    /// The caller needs this to know what to do with ``pullRequests``: a poll that started at
    /// page one is the whole list and replaces what came before it, and a resumed one is the
    /// tail of the list and has to be merged over it. Replacing on a resumed poll would drop
    /// every row from the pages it deliberately skipped.
    public var isResumed: Bool { resumedFrom.isResumable }

    public var snapshot: RawSnapshot {
        RawSnapshot(viewerLogin: viewerLogin, pullRequests: pullRequests)
    }

    /// In the order the requests went out, so a footer or a dump reads chronologically.
    public var warnings: [FetchWarning] {
        priority.warnings + open.warnings + closed.warnings + recovery.warnings + release.warnings
    }

    /// GraphQL points across the refresh, both searches and the tag queries.
    public var pointsSpent: Int {
        priority.pointsSpent + open.pointsSpent + closed.pointsSpent
            + recovery.pointsSpent + release.pointsSpent
    }

    /// The most recent accounting any of them reported.
    public var rateLimit: RateLimit? {
        release.rateLimit ?? closed.rateLimit ?? open.rateLimit ?? priority.rateLimit
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
