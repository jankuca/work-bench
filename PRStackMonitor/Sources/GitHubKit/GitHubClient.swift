import Foundation
import NetKit
import PRStackCore

/// Why a fetch stopped paginating.
///
/// Only `complete` means the caller is looking at every pull request in scope. The other
/// four all mean "there is more, and here is the cursor to resume from", which the footer
/// surfaces rather than pretending the list is whole (IMPLEMENTATION_PLAN §3).
public enum FetchStopReason: String, Equatable, Sendable {
    /// Pagination ran to `hasNextPage == false`.
    case complete
    /// The scope selects no repositories, so no request was made.
    case emptyScope
    /// The 10-page safety cap.
    case pageCap
    /// The per-poll point budget.
    case pointBudget
    /// GitHub's remaining allowance fell below 10%.
    case rateLimitFloor
    /// GitHub did not answer a page, and asking again at a smaller size did not help
    /// either. The pages that *did* land are kept, and ``PullRequestFetch/nextCursor``
    /// resumes at the one that failed — losing a whole sweep to one 502 is the failure this
    /// case exists to avoid.
    case serverError

    public var isComplete: Bool { self == .complete || self == .emptyScope }
}

/// Something the user should be able to see in the footer, that is not an error.
public enum FetchWarning: Equatable, Sendable, CustomStringConvertible {
    case pageCapReached(pages: Int, fetched: Int)
    case pointBudgetExhausted(spent: Int, limit: Int)
    /// GitHub did not answer a page, so it was asked for again: same cursor, `pageSize`
    /// nodes — half of what the attempt before it asked for, until the floor.
    case pageRetried(pageSize: Int, reason: String)
    /// Pagination gave up on a page GitHub would not answer, keeping everything before it.
    case searchInterrupted(pages: Int, fetched: Int, reason: String)
    case rateLimitFloorReached(remaining: Int, limit: Int, resetAt: Date?)
    case repositoryDropped(String)
    case nodeSkipped(String)
    case graphQL(GraphQLError)
    /// Release tracking (M6) — the tag list for one repository was truncated.
    case tagPageCapReached(repository: String, pages: Int)
    /// The per-poll `compare` budget. The remainder resumes next poll, and nothing is
    /// re-tested because every negative is persisted.
    case comparisonBudgetExhausted(spent: Int, limit: Int)
    /// One repository's release tracking failed. Only that repository's merges are
    /// affected; every other row, and every other repository, is unchanged.
    case releaseTrackingFailed(repository: String, reason: String)
    /// Release tracking was not attempted, or was cut short. A merge that has waited weeks
    /// can wait for the allowance to reset; the open list cannot.
    case releaseTrackingDeferred(reason: String)
    /// The priority refresh of the rows already on screen did not answer. Nothing is lost
    /// but latency: the searches behind it cover the same rows.
    case priorityRefreshFailed(reason: String)
    /// A merge into another pull request's branch could not be followed this poll. The row
    /// keeps saying `awaiting release`, which is where it already was, and a later poll
    /// asks again.
    case baseBranchUnresolved(reason: String)
    /// More than one pull request claims the branch a merge landed on, so which one it
    /// went into cannot be told. Left unresolved deliberately — the release binding downstream of
    /// this is permanent.
    case baseBranchAmbiguous(repository: String, branch: String)

    public var description: String {
        switch self {
        case .pageCapReached(let pages, let fetched):
            return "stopped at the \(pages)-page cap with \(fetched) pull requests; more remain"
        case .pointBudgetExhausted(let spent, let limit):
            return "spent \(spent) of \(limit) GraphQL points this poll; the rest resumes next poll"
        case .pageRetried(let pageSize, let reason):
            return "GitHub did not answer a page (\(reason)); asking again for \(pageSize) at a time"
        case .searchInterrupted(let pages, let fetched, let reason):
            return "stopped after \(pages) page(s) with \(fetched) pull requests: \(reason);"
                + " the rest resumes next poll"
        case .tagPageCapReached(let repository, let pages):
            return "stopped reading \(repository)'s tags at the \(pages)-page cap; "
                + "a release cut before those may not be found yet"
        case .comparisonBudgetExhausted(let spent, let limit):
            return "spent \(spent) of \(limit) release comparisons this poll; the rest resumes next poll"
        case .baseBranchUnresolved(let reason):
            return "could not follow a merge to the pull request it went into: \(reason)"
        case .baseBranchAmbiguous(let repository, let branch):
            // Count-neutral: the resolver reports this for any candidate count other than
            // one, and it reads up to `candidatesPerBranch` of them.
            return "more than one pull request in \(repository) claims '\(branch)'; "
                + "not guessing which one the merge went into"
        case .releaseTrackingFailed(let repository, let reason):
            return "could not check \(repository)'s releases: \(reason)"
        case .releaseTrackingDeferred(let reason):
            return "deferred release tracking: \(reason)"
        case .priorityRefreshFailed(let reason):
            return "could not refresh the rows already on screen ahead of the search: \(reason)"
        case .rateLimitFloorReached(let remaining, let limit, let resetAt):
            let when = resetAt.map { ISO8601DateFormatter().string(from: $0) } ?? "unknown"
            return "GitHub allowance low (\(remaining) of \(limit) left, resets \(when)); backing off"
        case .repositoryDropped(let repository):
            return "ignored '\(repository)': not a usable owner/name"
        case .nodeSkipped(let reason):
            return reason
        case .graphQL(let error):
            return "GitHub reported: \(error.description)"
        }
    }
}

/// One poll's worth of GitHub data.
public struct PullRequestFetch: Equatable, Sendable {
    public var viewerLogin: String
    public var pullRequests: [PullRequest]
    public var pagesFetched: Int
    /// Non-nil when there is more to fetch. Hand it back as `startingAfter` on the next
    /// poll to resume exactly where this one stopped.
    public var nextCursor: String?
    public var stopReason: FetchStopReason
    public var pointsSpent: Int
    /// GitHub's accounting as of the last page.
    public var rateLimit: RateLimit?
    public var warnings: [FetchWarning]
    /// GitHub's own count of everything the search matches — its `issueCount`, as of the
    /// last page. Nil when no page landed to report one. It is the denominator the first-sync
    /// stepper shows as "12 of 47"; the paging cap and the point budget mean the fetch itself
    /// may hold fewer than this, which is exactly why the total is worth stating.
    public var searchTotal: Int?

    public init(
        viewerLogin: String,
        pullRequests: [PullRequest],
        pagesFetched: Int,
        nextCursor: String?,
        stopReason: FetchStopReason,
        pointsSpent: Int,
        rateLimit: RateLimit?,
        warnings: [FetchWarning],
        searchTotal: Int? = nil
    ) {
        self.viewerLogin = viewerLogin
        self.pullRequests = pullRequests
        self.pagesFetched = pagesFetched
        self.nextCursor = nextCursor
        self.stopReason = stopReason
        self.pointsSpent = pointsSpent
        self.rateLimit = rateLimit
        self.warnings = warnings
        self.searchTotal = searchTotal
    }

    /// What ``PRStackCore`` derives from, **before** Linear resolution.
    ///
    /// Every `linearIssues` here is empty. `LinearKit.LinearResolver` fills them in between
    /// this and derivation, so the live callers build their snapshot from
    /// `resolution.pullRequests` rather than from this. It remains because a GitHub-only
    /// poll is still a valid panel — that is what the app shows with no Linear key — and
    /// because the tests derive from it directly.
    public var snapshot: RawSnapshot {
        RawSnapshot(viewerLogin: viewerLogin, pullRequests: pullRequests)
    }
}

/// The GitHub half of one poll: a paginated search, mapped to domain values.
public struct GitHubClient {
    public struct Configuration: Equatable, Sendable {
        /// The smallest page the reduction in ``pageRetries`` walks down to.
        ///
        /// Below this the request stops being a page of a search and starts being a round
        /// trip per pull request: five nodes still carries every field a row is drawn from,
        /// and an account that cannot be read five at a time is not one a smaller page will
        /// rescue.
        public static let minimumPageSize = 5

        /// The most attempts ``pageRetries`` will honour, and the longest ``retryDelay`` will
        /// wait between them.
        ///
        /// Both bound the same thing from different sides: how long one page can hold up a
        /// poll. Ten attempts a quarter of a minute apart is already far past the point where
        /// waiting has stopped being the answer — the cursor comes back, and the next poll
        /// costs nothing to try again with.
        public static let maximumPageRetries = 10
        public static let longestRetryDelay: TimeInterval = 15

        /// GitHub's own maximum for a search connection.
        public var pageSize: Int
        /// The safety cap from IMPLEMENTATION_PLAN §3 — 10 pages, 500 pull requests.
        public var pageCap: Int
        /// GraphQL points one poll may spend.
        public var pointBudget: Int
        /// How many extra attempts a whole pagination gets when GitHub answers `502`/`504`
        /// or the connection stalls, each one asking for half as many pull requests as the
        /// last (down to ``minimumPageSize``).
        ///
        /// Spent across the pagination rather than restored per page, exactly like the page
        /// size the attempts reduce: a sweep that spends two of them on page one has one
        /// left for page nine. Per-page would be the wrong shape — ten pages could then cost
        /// thirty extra requests on the connection least able to afford them, which is the
        /// connection this exists for.
        ///
        /// Three, because the reduction is what does the work: 50 → 25 → 12 → 6 covers the
        /// whole useful range, and a fourth attempt at a size GitHub has already failed
        /// three times is spending a poor connection's time on a page the next poll resumes
        /// for free.
        public var pageRetries: Int
        /// What to wait between those attempts. Zero skips the sleep altogether, which is
        /// what the tests set — there is no scheduler in a test to be late for.
        ///
        /// Clamped to ``longestRetryDelay``, and a value that is not a finite number becomes
        /// zero. That is not defensive decoration: the wait is converted to nanoseconds as a
        /// `UInt64`, and that conversion **traps** on an infinite or absurd `Double`. A
        /// configuration mistake should cost a badly timed retry, not the app.
        public var retryDelay: TimeInterval
        public var endpoint: URL

        public init(
            pageSize: Int = 50,
            pageCap: Int = 10,
            pointBudget: Int = PointBudget.defaultPoints,
            pageRetries: Int = 3,
            retryDelay: TimeInterval = 0.75,
            endpoint: URL = GitHubAPI.graphQLEndpoint
        ) {
            self.pageSize = min(100, max(1, pageSize))
            self.pageCap = max(1, pageCap)
            self.pointBudget = pointBudget
            self.pageRetries = min(Configuration.maximumPageRetries, max(0, pageRetries))
            // `isFinite` first: an infinite or NaN delay would survive `min`/`max` — and
            // `max(0, .nan)` is 0 only by accident of how comparison treats NaN — and then
            // trap when the sleep converts it to a `UInt64` of nanoseconds.
            self.retryDelay = retryDelay.isFinite
                ? min(Configuration.longestRetryDelay, max(0, retryDelay))
                : 0
            self.endpoint = endpoint
        }

        /// What to wait before the `attempt`-th retry of a page: the delay, growing with the
        /// attempt, and never past ``longestRetryDelay``.
        ///
        /// The cap applies to the *product*, not just to ``retryDelay``. Clamping only the
        /// base would let a configuration at the cap wait ten times it — 150 seconds before
        /// the last of ten attempts, and 825 across them, which is a poll blocked for a
        /// quarter of an hour by a page the next poll would resume for free.
        ///
        /// A function rather than three lines in the loop because it is the only arithmetic
        /// here a test can check without waiting for it — and because it is where the cap is
        /// enforced against a ``retryDelay`` that was set after construction, past the
        /// initializer's bounds: `min` against a finite cap answers with the cap for an
        /// infinite or a NaN delay as much as for a merely large one, so what this returns is
        /// always convertible to a `UInt64` of nanoseconds.
        func delay(forAttempt attempt: Int) -> TimeInterval {
            min(Configuration.longestRetryDelay, retryDelay * Double(max(1, attempt)))
        }
    }

    private let graphQL: GraphQLClient
    private let configuration: Configuration

    /// What one poll may spend across every search it runs, for the caller that runs more
    /// than one of them (``GitHubPoll``) and has to share a single budget between them.
    public var pointBudget: Int { configuration.pointBudget }

    public init(
        transport: any HTTPTransport,
        tokenProvider: any TokenProvider,
        configuration: Configuration = Configuration()
    ) {
        self.graphQL = GraphQLClient(
            transport: transport,
            tokenProvider: tokenProvider,
            endpoint: configuration.endpoint
        )
        self.configuration = configuration
    }

    /// Fetches the viewer's pull requests in `scope`, paginating until the search is
    /// exhausted or a bound is hit.
    ///
    /// Pagination is not optional in either scope: `all` would otherwise silently drop
    /// everything past the 50th pull request, and `selected` would drop repositories whose
    /// pull requests happen to sort onto a later page.
    ///
    /// `extraQualifiers` are appended to the search verbatim. The plan's query is
    /// deliberately unbounded in time, so this is how a caller narrows it — `is:open` for
    /// a quick look, or the dynamic merged-PR lower bound M6 needs.
    ///
    /// `includesDrafts` widens the search to work in progress. Off by default, and the
    /// caller passing it is the app reading one preference per poll — see
    /// ``SearchQuery/build(scope:includesDrafts:extraQualifiers:)``.
    ///
    /// `budget` is for a caller running more than one search in a poll: pass the budget the
    /// earlier ones have already been spending and this search shares what is left of it
    /// instead of starting again at the full allowance. Omitting it gives this search a
    /// budget of its own, which is right for a single search and wrong for a poll made of
    /// three.
    ///
    /// `stage`/`progress` are the first-sync stepper's, and both optional: with no reporter
    /// this pages exactly as it always has. When given, the reporter is told the step began,
    /// then handed a running count and GitHub's `issueCount` total after each page, then told
    /// it finished — so the panel can say "12 of 47" while the pages are still landing.
    public func fetchPullRequests(
        scope: RepoScope,
        includesDrafts: Bool = false,
        extraQualifiers: [String] = [],
        startingAfter cursor: String? = nil,
        budget shared: PointBudget? = nil,
        stage: SyncStage? = nil,
        progress: SyncProgressReporter? = nil
    ) async throws -> PullRequestFetch {
        guard let query = SearchQuery.build(
            scope: scope,
            includesDrafts: includesDrafts,
            extraQualifiers: extraQualifiers
        ) else {
            // An empty selection is not the same query as `all`, and must not be run as
            // one. No request goes out — and the step, having nothing to do, is skipped
            // rather than shown running against a search that never happens.
            if let stage { progress?(.skipped(stage)) }
            return PullRequestFetch(
                viewerLogin: "",
                pullRequests: [],
                pagesFetched: 0,
                nextCursor: nil,
                stopReason: .emptyScope,
                pointsSpent: 0,
                rateLimit: nil,
                warnings: droppedWarnings(for: scope)
            )
        }

        if let stage { progress?(.began(stage)) }

        var warnings = query.droppedRepositories.map(FetchWarning.repositoryDropped)
        var budget = shared ?? PointBudget(points: configuration.pointBudget)
        // What *this* search spent, as opposed to what the shared budget has spent across the
        // poll. The caller sums these, so reporting the budget's total here would count the
        // searches before this one a second time.
        var spent = 0
        var collected: [PullRequest] = []
        var seen: Set<PRID> = []
        var viewerLogin = ""
        var rateLimit: RateLimit?
        var pages = 0
        var nextCursor = cursor
        var stopReason: FetchStopReason = .complete
        // GitHub's `issueCount` from the last page that reported one — the stepper's total.
        var searchTotal: Int?
        // Reduced, never restored, for the rest of this pagination: an account whose page of
        // 50 GitHub could not compute will not compute page eight of 50 either. Smaller pages
        // mean the page cap covers fewer pull requests, which is what `nextCursor` and the
        // next poll are for.
        var pageSize = configuration.pageSize
        // Read through the same bound the initializer applies, because a `Configuration` is a
        // struct of `var`s: a caller can build a valid one and then set `pageRetries` to
        // `Int.max`, and this loop would retry a page that never comes good until the poll
        // was cancelled. Clamping where the value is *used* costs a line and cannot drift
        // out of step the way a second copy of the field list in `init` would.
        //
        // The wait needs no such guard: ``Configuration/delay(forAttempt:)`` caps the product
        // it returns, and `min` against a finite cap answers with the cap for an infinite or
        // NaN delay too, so the conversion to nanoseconds stays in range whatever was set.
        let allowedRetries = min(Configuration.maximumPageRetries, max(0, configuration.pageRetries))
        var retriesLeft = allowedRetries

        pagination: while true {
            let result: GraphQLResult<SearchPayload>
            do {
                let received: GraphQLResult<SearchPayload> = try await graphQL.perform(
                    query: PullRequestQuery.text,
                    variables: PullRequestQuery.variables(
                        query: query.text,
                        pageSize: pageSize,
                        cursor: nextCursor
                    )
                )
                // A `200` carrying a null connection and an execution failure is a 504 with
                // a success status on it, and it has to be raised as one. Read as an answer
                // it says "no more results": pagination would stop at `complete`, drop the
                // cursor, and the panel would replace its rows with a list that stops
                // wherever GitHub gave up — the truncation is invisible precisely because
                // nothing reports a failure.
                if received.data.search == nil, received.errors.contains(where: \.isExecutionFailure) {
                    throw GitHubError.graphQL(received.errors)
                }
                result = received
            } catch let error as GitHubError where error.isServerSideFailure {
                // GitHub either could not compute this page in time or the connection did
                // not survive asking for it. Both answer to a smaller page, so the same
                // window is asked for again — same cursor, half the nodes — rather than the
                // whole poll being thrown away for one page.
                guard retriesLeft > 0 else {
                    // Out of attempts. Everything already banked is still true and
                    // `nextCursor` points at the page that failed, so the sweep resumes
                    // there instead of walking these pages again — but only if something
                    // *was* banked. A first page that never landed is an outage, and
                    // reporting it as a successful empty poll would put the panel at
                    // "connected, nothing waiting on you" for a GitHub that is down.
                    guard pages > 0 else { throw error }
                    stopReason = .serverError
                    warnings.append(
                        .searchInterrupted(
                            pages: pages,
                            fetched: collected.count,
                            reason: error.description
                        )
                    )
                    break pagination
                }
                retriesLeft -= 1
                // Halved, down to the floor — and never *up* to it, which is what the outer
                // `min` is for: a caller that asked for pages of one (the dump does, to watch
                // pagination run) must not have its page size grown by a failure.
                let halved = max(Configuration.minimumPageSize, pageSize / 2)
                pageSize = min(pageSize, halved)
                warnings.append(.pageRetried(pageSize: pageSize, reason: error.description))
                if configuration.retryDelay > 0 {
                    // Growing, so the second attempt gives a service that has now failed twice
                    // longer than the first did. Throws on cancellation, which is the right
                    // answer: a poll the panel closing cancelled must not sit here waiting.
                    let delay = configuration.delay(forAttempt: allowedRetries - retriesLeft)
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
                continue pagination
            }
            pages += 1
            warnings.append(contentsOf: result.errors.map(FetchWarning.graphQL))

            let payload = result.data
            if viewerLogin.isEmpty, let login = payload.viewer?.login {
                viewerLogin = login
            }
            if let reported = payload.rateLimit?.rateLimit {
                rateLimit = reported
                budget.record(reported.cost)
                spent += max(0, reported.cost)
            }

            for node in (payload.search?.nodes ?? []).compactMap({ $0 }) {
                switch PullRequestMapper.map(node) {
                case .mapped(let pullRequest):
                    // The search index can shift between pages, which repeats a node on the
                    // page boundary. Keeping the first sighting makes the result the same
                    // whether or not that happened.
                    guard seen.insert(pullRequest.id).inserted else { continue }
                    collected.append(pullRequest)
                case .skipped(let reason):
                    warnings.append(.nodeSkipped(reason))
                }
            }

            // Reported per page and kept: the count is stable across pages of one search, but
            // a page GitHub failed the connection on carries none, so the last real one holds.
            if let reported = payload.search?.issueCount { searchTotal = reported }
            if let stage {
                progress?(.advanced(stage, found: collected.count, total: searchTotal))
            }

            // A null `search` means GitHub failed the connection and said why in `errors`,
            // which are already banked as warnings above. Treating it as the end of
            // pagination is right: there is no cursor to go on with.
            let pageInfo = payload.search?.pageInfo
            let hasNextPage = (pageInfo?.hasNextPage ?? false) && pageInfo?.endCursor != nil
            guard hasNextPage else {
                nextCursor = nil
                stopReason = .complete
                break pagination
            }
            nextCursor = pageInfo?.endCursor

            // Bounds are checked after the page is banked, so each one stops the *next*
            // request rather than discarding work already paid for.
            //
            // That holds for a shared budget too, and deliberately: a search whose budget was
            // already spent by the ones before it still sends its first page. A poll made of
            // two searches would otherwise be able to return *nothing at all* for one half of
            // the panel — no open list, or no Done section — which is a worse answer than one
            // page of overspend against an allowance the 10% floor above is what really
            // guards. The budget bounds how far a poll pages, not whether it looks.
            if let rateLimit, rateLimit.isBelowFloor {
                stopReason = .rateLimitFloor
                warnings.append(
                    .rateLimitFloorReached(
                        remaining: rateLimit.remaining,
                        limit: rateLimit.limit,
                        resetAt: rateLimit.resetAt
                    )
                )
                break pagination
            }
            if budget.isExhausted {
                stopReason = .pointBudget
                warnings.append(.pointBudgetExhausted(spent: budget.spent, limit: budget.limit))
                break pagination
            }
            if pages >= configuration.pageCap {
                stopReason = .pageCap
                warnings.append(.pageCapReached(pages: pages, fetched: collected.count))
                break pagination
            }
        }

        // Finished however pagination stopped — completed, capped, or interrupted after
        // banking pages. The one exit that does not reach here is the first-page outage that
        // throws above, which is a failure the step must not report as a tidy finish.
        if let stage { progress?(.finished(stage)) }

        return PullRequestFetch(
            viewerLogin: viewerLogin,
            pullRequests: collected,
            pagesFetched: pages,
            nextCursor: nextCursor,
            stopReason: stopReason,
            pointsSpent: spent,
            rateLimit: rateLimit,
            warnings: warnings,
            searchTotal: searchTotal
        )
    }

    private func droppedWarnings(for scope: RepoScope) -> [FetchWarning] {
        guard case .selected(let requested) = scope else { return [] }
        return requested
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !RepoScope.isWellFormed($0) }
            .map(FetchWarning.repositoryDropped)
    }
}
