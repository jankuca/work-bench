import Foundation
import NetKit
import PRStackCore

/// The rows the panel is already showing, refreshed in one request ahead of the sweep.
///
/// A poll's two searches page through everything in scope. On a small account that is one
/// request; on a large one it is ten, plus a second search behind them, and until the last
/// page lands nothing on screen has moved — the row whose checks went red four minutes ago
/// is still green because the poll that would have said so is on page seven of a list the
/// user is not looking at.
///
/// The rows the user *is* looking at are a much smaller set, and they are known by id, so
/// they can be asked for directly: one request, no pagination, and the panel is current for
/// what it is currently drawing while the sweep runs underneath it.
///
/// This is an addition to the plan's two searches (IMPLEMENTATION_PLAN §3), not a
/// replacement for either. Only the searches can find a pull request that is *new* — this
/// one can refresh nothing it has not been told about — so it runs first and the sweep
/// still runs to completion behind it, at the same cadence and against the same budget.
public struct PriorityRefresh {
    /// How many pull requests one refresh asks for.
    ///
    /// One request, always: a single round trip is the whole point, so a longer list is
    /// truncated rather than split. Fifty is the search's own page size, which puts the
    /// refresh at roughly the cost of the sweep's first page — a tenth of what a ten-page
    /// sweep spends, which is the case this exists for.
    public static let defaultBatchLimit = 50

    public struct Configuration: Equatable, Sendable {
        /// See ``PriorityRefresh/defaultBatchLimit``.
        public var batchLimit: Int
        public var endpoint: URL

        public init(
            batchLimit: Int = PriorityRefresh.defaultBatchLimit,
            endpoint: URL = GitHubAPI.graphQLEndpoint
        ) {
            self.batchLimit = min(100, max(1, batchLimit))
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

    /// Which of `ids` are worth asking for, in the order given and capped at `limit`.
    ///
    /// The order is the caller's priority order and is preserved exactly, so a truncated
    /// list keeps the rows nearest the top of the panel. Repositories outside a `selected`
    /// scope are dropped here rather than filtered out of the answer: asking for them would
    /// spend points on rows the sweep is not going to return anyway.
    public static func candidates(
        _ ids: [PRID],
        scope: RepoScope,
        limit: Int = PriorityRefresh.defaultBatchLimit
    ) -> [PRID] {
        let selection = PriorityRefresh.selection(in: scope)
        var seen: Set<PRID> = []
        var result: [PRID] = []

        for id in ids {
            guard result.count < max(0, limit) else { break }
            // The same predicate the search qualifiers are built through. An id that cannot
            // be split into owner and name cannot be spelled into this query either.
            guard TagRefsClient.ownerAndName(id.repo) != nil else { continue }
            if let selection, !selection.contains(id.repo.lowercased()) { continue }
            guard seen.insert(id).inserted else { continue }
            result.append(id)
        }
        return result
    }

    /// Whether a refreshed pull request is one the panel may still show.
    ///
    /// A refresh asks by id, which bypasses every qualifier the searches carry — so a pull
    /// request that has since become a draft, or that has been closed for longer than the
    /// merged search reaches back, would arrive here and be drawn for the few seconds until
    /// the sweep landed and dropped it. Applying the searches' own bounds to the answer is
    /// what keeps the two halves of a poll saying the same thing.
    ///
    /// `bound` is the closed search's lower bound — ``MergedPullRequestSearch/lowerBound(unbound:now:)``.
    /// A pull request that closed before it is outside both searches and belongs to neither.
    /// `mergedAt` is the merge instant; a pull request closed *without* merging carries no
    /// closing timestamp at all, so `updatedAt` stands in — closing a pull request updates
    /// it, so the two are the same instant until somebody comments on it afterwards, which
    /// can only widen the window.
    public static func keeps(
        _ pullRequest: PullRequest,
        scope: RepoScope,
        includesDrafts: Bool,
        closedSince bound: Date
    ) -> Bool {
        if let selection = PriorityRefresh.selection(in: scope),
           !selection.contains(pullRequest.repo.lowercased()) {
            return false
        }
        guard includesDrafts || !pullRequest.isDraft else { return false }
        guard pullRequest.state != .open else { return true }
        return (pullRequest.mergedAt ?? pullRequest.updatedAt) >= bound
    }

    /// The selected repositories, lowercased for comparison, or nil for the `all` scope —
    /// where every repository qualifies and there is nothing to compare against.
    private static func selection(in scope: RepoScope) -> Set<String>? {
        guard !scope.isAll else { return nil }
        return Set(scope.normalizedRepositories.map { $0.lowercased() })
    }

    /// Refreshes the pull requests `ids` names: one request, whatever comes back.
    ///
    /// Never throws for anything the sweep is about to answer for anyway. A repository that
    /// has been renamed, a pull request that has been deleted, a partial `FORBIDDEN` — all
    /// of them arrive as a null field and a warning, and the searches that follow are
    /// unaffected. Only the two failures that end the poll for everyone — a rejected
    /// credential and an exhausted allowance — are rethrown, along with cancellation, which
    /// is not a failure at all.
    public func refresh(
        _ ids: [PRID],
        scope: RepoScope,
        includesDrafts: Bool,
        closedSince bound: Date
    ) async throws -> KnownPullRequestFetch {
        let requested = PriorityRefresh.candidates(ids, scope: scope, limit: configuration.batchLimit)
        guard let query = KnownPullRequestQuery.text(for: requested) else {
            return KnownPullRequestFetch.empty
        }

        var result = KnownPullRequestFetch(requested: requested)

        let response: GraphQLResult<KnownPullRequestPayload>
        do {
            response = try await graphQL.perform(query: query)
        } catch let error as GitHubError {
            if error.endsThePoll { throw error }
            result.warnings.append(.priorityRefreshFailed(reason: error.description))
            return result
        }

        result.warnings.append(contentsOf: response.errors.map(FetchWarning.graphQL))
        if let reported = response.data.rateLimit?.rateLimit {
            result.rateLimit = reported
            result.pointsSpent = max(0, reported.cost)
        }
        result.viewerLogin = response.data.viewer?.login ?? ""

        var byID: [PRID: PullRequest] = [:]
        for node in response.data.pullRequests {
            switch PullRequestMapper.map(node) {
            case .mapped(let pullRequest):
                guard PriorityRefresh.keeps(
                    pullRequest,
                    scope: scope,
                    includesDrafts: includesDrafts,
                    closedSince: bound
                ) else { continue }
                byID[pullRequest.id] = pullRequest
            case .skipped(let reason):
                result.warnings.append(.nodeSkipped(reason))
            }
        }

        // Rebuilt in the order the ids were asked for rather than in the order they were
        // answered. The aliases come back in a dictionary, and a panel whose rows changed
        // places because a JSON object decoded in a different order would be a poll that
        // reshuffled itself for nothing.
        result.pullRequests = requested.compactMap { byID[$0] }
        return result
    }
}

/// What one priority refresh produced.
public struct KnownPullRequestFetch: Equatable, Sendable {
    public var viewerLogin: String
    /// The refreshed pull requests, in the order they were asked for, already filtered to
    /// the ones the panel may still show (``PriorityRefresh/keeps(_:scope:includesDrafts:closedSince:)``).
    ///
    /// Shorter than ``requested`` whenever a pull request has left the panel's scope, been
    /// deleted, or become invisible to the token. Which of those it was is not
    /// distinguished: every one of them means "the sweep will say", and the sweep is a few
    /// seconds behind this.
    public var pullRequests: [PullRequest]
    /// The ids this asked for, after the scope and the batch limit were applied.
    public var requested: [PRID]
    public var pointsSpent: Int
    public var rateLimit: RateLimit?
    public var warnings: [FetchWarning]

    public init(
        viewerLogin: String = "",
        pullRequests: [PullRequest] = [],
        requested: [PRID] = [],
        pointsSpent: Int = 0,
        rateLimit: RateLimit? = nil,
        warnings: [FetchWarning] = []
    ) {
        self.viewerLogin = viewerLogin
        self.pullRequests = pullRequests
        self.requested = requested
        self.pointsSpent = pointsSpent
        self.rateLimit = rateLimit
        self.warnings = warnings
    }

    /// No refresh ran — nothing known, nothing in scope, or no refresher configured.
    public static let empty = KnownPullRequestFetch()

    /// Whether this is worth showing the user. An empty refresh is not a failure and not a
    /// state change; it is a poll that had nothing to say yet.
    public var isEmpty: Bool { pullRequests.isEmpty }
}

/// One aliased `repository { pullRequest }` per known id, in a single query.
///
/// Aliases rather than `nodes(ids:)` because the app never sees a pull request's GraphQL
/// node id — a ``PRID`` is `owner/name#number`, which is what the panel, the state file and
/// every user-visible surface are keyed on. Storing node ids beside them to enable this
/// query would be a second identity to keep in step, and one that a repository transfer
/// invalidates silently.
enum KnownPullRequestQuery {
    /// The document, or nil when no id survived validation and there is nothing to ask.
    ///
    /// Owner and name are interpolated into the query text rather than passed as variables:
    /// one variable pair per id would mean forty declarations in the operation signature to
    /// say what forty literals say. That is only safe because both halves have been through
    /// ``RepoScope/isWellFormed(_:)``, which admits ASCII letters, digits, `.`, `_` and `-`
    /// and nothing else — no quote, no brace and no whitespace can reach the document — and
    /// the number is an `Int`. Ids that do not pass are dropped rather than escaped.
    static func text(for ids: [PRID]) -> String? {
        var selections: [String] = []
        for (index, id) in ids.enumerated() {
            guard let (owner, name) = TagRefsClient.ownerAndName(id.repo), id.number > 0 else { continue }
            selections.append(
                "  pr\(index): repository(owner: \"\(owner)\", name: \"\(name)\")"
                    + " { pullRequest(number: \(id.number)) { ...PullRequestFields } }"
            )
        }
        guard !selections.isEmpty else { return nil }

        return """
        query KnownPullRequests {
          rateLimit { limit cost remaining resetAt }
          viewer { login }
        \(selections.joined(separator: "\n"))
        }

        \(PullRequestQuery.fields)
        """
    }
}

/// The wire shape of ``KnownPullRequestQuery``: `rateLimit`, `viewer`, and one aliased
/// repository per id.
///
/// The aliases are `pr0`, `pr1`, … — a set no `CodingKey` enum can list — so the keys are
/// read dynamically. Nothing is inferred from an alias: every node carries its own
/// repository and number, which is what the caller keys the answer on. Both levels are
/// optional, and both nulls happen: a repository the token cannot see answers null, and so
/// does a pull request that has been deleted or transferred away.
struct KnownPullRequestPayload: Decodable, Equatable {
    var rateLimit: RateLimitDTO?
    var viewer: ActorDTO?
    var pullRequests: [PullRequestNodeDTO]

    init(
        rateLimit: RateLimitDTO? = nil,
        viewer: ActorDTO? = nil,
        pullRequests: [PullRequestNodeDTO] = []
    ) {
        self.rateLimit = rateLimit
        self.viewer = viewer
        self.pullRequests = pullRequests
    }

    private struct AliasKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }

        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    private struct RepositoryEntry: Decodable, Equatable {
        var pullRequest: PullRequestNodeDTO? = nil
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AliasKey.self)
        var rateLimit: RateLimitDTO?
        var viewer: ActorDTO?
        var nodes: [PullRequestNodeDTO] = []

        for key in container.allKeys {
            switch key.stringValue {
            case "rateLimit":
                rateLimit = try container.decodeIfPresent(RateLimitDTO.self, forKey: key)
            case "viewer":
                viewer = try container.decodeIfPresent(ActorDTO.self, forKey: key)
            default:
                guard let entry = try container.decodeIfPresent(RepositoryEntry.self, forKey: key),
                      let node = entry.pullRequest else { continue }
                nodes.append(node)
            }
        }

        self.init(rateLimit: rateLimit, viewer: viewer, pullRequests: nodes)
    }
}
