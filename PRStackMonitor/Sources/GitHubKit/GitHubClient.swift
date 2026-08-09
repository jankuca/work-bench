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

    public var isComplete: Bool { self == .complete || self == .emptyScope }
}

/// Something the user should be able to see in the footer, that is not an error.
public enum FetchWarning: Equatable, Sendable, CustomStringConvertible {
    case pageCapReached(pages: Int, fetched: Int)
    case pointBudgetExhausted(spent: Int, limit: Int)
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

    public var description: String {
        switch self {
        case .pageCapReached(let pages, let fetched):
            return "stopped at the \(pages)-page cap with \(fetched) pull requests; more remain"
        case .pointBudgetExhausted(let spent, let limit):
            return "spent \(spent) of \(limit) GraphQL points this poll; the rest resumes next poll"
        case .tagPageCapReached(let repository, let pages):
            return "stopped reading \(repository)'s tags at the \(pages)-page cap; "
                + "a release cut before those may not be found yet"
        case .comparisonBudgetExhausted(let spent, let limit):
            return "spent \(spent) of \(limit) release comparisons this poll; the rest resumes next poll"
        case .releaseTrackingFailed(let repository, let reason):
            return "could not check \(repository)'s releases: \(reason)"
        case .releaseTrackingDeferred(let reason):
            return "deferred release tracking: \(reason)"
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

    public init(
        viewerLogin: String,
        pullRequests: [PullRequest],
        pagesFetched: Int,
        nextCursor: String?,
        stopReason: FetchStopReason,
        pointsSpent: Int,
        rateLimit: RateLimit?,
        warnings: [FetchWarning]
    ) {
        self.viewerLogin = viewerLogin
        self.pullRequests = pullRequests
        self.pagesFetched = pagesFetched
        self.nextCursor = nextCursor
        self.stopReason = stopReason
        self.pointsSpent = pointsSpent
        self.rateLimit = rateLimit
        self.warnings = warnings
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
        /// GitHub's own maximum for a search connection.
        public var pageSize: Int
        /// The safety cap from IMPLEMENTATION_PLAN §3 — 10 pages, 500 pull requests.
        public var pageCap: Int
        /// GraphQL points one poll may spend.
        public var pointBudget: Int
        public var endpoint: URL

        public init(
            pageSize: Int = 50,
            pageCap: Int = 10,
            pointBudget: Int = PointBudget.defaultPoints,
            endpoint: URL = GitHubAPI.graphQLEndpoint
        ) {
            self.pageSize = min(100, max(1, pageSize))
            self.pageCap = max(1, pageCap)
            self.pointBudget = pointBudget
            self.endpoint = endpoint
        }
    }

    private let graphQL: GraphQLClient
    private let configuration: Configuration

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
    public func fetchPullRequests(
        scope: RepoScope,
        extraQualifiers: [String] = [],
        startingAfter cursor: String? = nil
    ) async throws -> PullRequestFetch {
        guard let query = SearchQuery.build(scope: scope, extraQualifiers: extraQualifiers) else {
            // An empty selection is not the same query as `all`, and must not be run as
            // one. No request goes out.
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

        var warnings = query.droppedRepositories.map(FetchWarning.repositoryDropped)
        var budget = PointBudget(points: configuration.pointBudget)
        var collected: [PullRequest] = []
        var seen: Set<PRID> = []
        var viewerLogin = ""
        var rateLimit: RateLimit?
        var pages = 0
        var nextCursor = cursor
        var stopReason: FetchStopReason = .complete

        pagination: while true {
            let result: GraphQLResult<SearchPayload> = try await graphQL.perform(
                query: PullRequestQuery.text,
                variables: PullRequestQuery.variables(
                    query: query.text,
                    pageSize: configuration.pageSize,
                    cursor: nextCursor
                )
            )
            pages += 1
            warnings.append(contentsOf: result.errors.map(FetchWarning.graphQL))

            let payload = result.data
            if viewerLogin.isEmpty, let login = payload.viewer?.login {
                viewerLogin = login
            }
            if let reported = payload.rateLimit?.rateLimit {
                rateLimit = reported
                budget.record(reported.cost)
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

        return PullRequestFetch(
            viewerLogin: viewerLogin,
            pullRequests: collected,
            pagesFetched: pages,
            nextCursor: nextCursor,
            stopReason: stopReason,
            pointsSpent: budget.spent,
            rateLimit: rateLimit,
            warnings: warnings
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
