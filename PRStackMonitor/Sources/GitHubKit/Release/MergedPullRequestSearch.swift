import Foundation
import PRStackCore

/// The second search of a poll: the pull requests that have already left the open list.
///
/// Its lower bound is **dynamic, not a fixed window**. It starts at the oldest merge still
/// waiting for a release tag, defaulting to 14 days back when nothing is waiting. A fixed
/// 14-day window would drop a long-unbound pull request out of the query, lose its merge
/// commit, and strand the row at `merged · awaiting release` forever — exactly the case
/// PRD §10 says should resolve quietly whenever the tag finally appears
/// (IMPLEMENTATION_PLAN §3).
///
/// One qualifier wider than the plan's `is:merged`: this asks for `is:closed`, which is
/// merged **and** closed-without-merging. Both are terminal states the precedence table
/// resolves and both belong in Done, so narrowing to merges would make a pull request the
/// user closed vanish from the panel the moment the open search stopped returning it. The
/// bound and the cost are unchanged — still one search, still anchored on the oldest
/// unbound merge, since for a merged pull request `closed:` and `merged:` are the same
/// instant.
public enum MergedPullRequestSearch {
    /// How far back the first poll of a fresh install looks.
    public static let coldStartWindow: TimeInterval = 14 * 24 * 60 * 60

    /// The qualifiers that restrict the *open* half of the poll.
    ///
    /// The plan's search is deliberately unbounded in time, which is right for the query it
    /// describes but wrong once there are two of them: without this, every poll re-fetches
    /// every pull request the user has ever authored, and the merged query's careful lower
    /// bound saves nothing.
    public static let openQualifiers = ["is:open"]

    /// The oldest merge still waiting for a tag, or `now` minus the cold-start window.
    ///
    /// Never later than the cold-start floor: a state file whose only unbound merge is from
    /// this morning must not shrink the window that catches yesterday's merges.
    public static func lowerBound(unbound: [PRID: UnboundMerge], now: Date) -> Date {
        let coldStart = now.addingTimeInterval(-coldStartWindow)
        guard let oldest = unbound.values.map(\.mergedAt).min() else { return coldStart }
        return min(oldest, coldStart)
    }

    /// `["is:closed", "closed:>=2026-01-09"]`.
    ///
    /// Day granularity, floored: GitHub accepts a full timestamp, but a day is the unit the
    /// user can reason about in a debug dump, and rounding *down* to it can only widen the
    /// window — a bound that rounded up would silently skip the merge it was computed from.
    public static func qualifiers(since bound: Date) -> [String] {
        ["is:closed", "closed:>=\(dayFormatter.string(from: bound))"]
    }

    public static func qualifiers(unbound: [PRID: UnboundMerge], now: Date) -> [String] {
        qualifiers(since: lowerBound(unbound: unbound, now: now))
    }

    /// `ISO8601DateFormatter`, not `DateFormatter`: it is fixed to UTC and to the proleptic
    /// Gregorian calendar, so the qualifier cannot pick up the user's locale — which is how
    /// a Japanese-calendar year would end up in a search query.
    private static let dayFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()
}

extension GitHubClient {
    /// The open half of a poll — the rows the panel is mostly about.
    public func fetchOpenPullRequests(
        scope: RepoScope,
        includesDrafts: Bool = false,
        startingAfter cursor: String? = nil,
        budget: PointBudget? = nil,
        progress: SyncProgressReporter? = nil
    ) async throws -> PullRequestFetch {
        try await fetchPullRequests(
            scope: scope,
            includesDrafts: includesDrafts,
            extraQualifiers: MergedPullRequestSearch.openQualifiers,
            startingAfter: cursor,
            budget: budget,
            stage: .openPullRequests,
            progress: progress
        )
    }

    /// The closed half, bounded by the oldest merge still waiting for a tag.
    ///
    /// `includesDrafts` reaches this half too, and it is not redundant: a merge is never a
    /// draft, but a draft abandoned and closed is, and Done showing it while the open list
    /// showed the same pull request an hour earlier is the consistent reading.
    public func fetchClosedPullRequests(
        scope: RepoScope,
        includesDrafts: Bool = false,
        unbound: [PRID: UnboundMerge],
        now: Date,
        startingAfter cursor: String? = nil,
        budget: PointBudget? = nil,
        progress: SyncProgressReporter? = nil
    ) async throws -> PullRequestFetch {
        try await fetchPullRequests(
            scope: scope,
            includesDrafts: includesDrafts,
            extraQualifiers: MergedPullRequestSearch.qualifiers(unbound: unbound, now: now),
            startingAfter: cursor,
            budget: budget,
            stage: .mergedPullRequests,
            progress: progress
        )
    }
}
