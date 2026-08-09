import Foundation
import NetKit

/// One tag that could contain a merge commit.
public struct TagCandidate: Equatable, Sendable {
    public var name: String
    /// The commit the tag points at. One level deeper than `target.oid` for an annotated
    /// tag, and `nil` for a tag pointing at something that is not a commit at all — a tag
    /// on a tree or a blob, which git allows and nothing here can ship.
    public var commit: String?
    /// The tag's **own** timestamp: `tagger.date` for an annotated tag, the target commit's
    /// `committedDate` for a lightweight one, which is the only date it carries.
    public var taggedAt: Date

    public init(name: String, commit: String?, taggedAt: Date) {
        self.name = name
        self.commit = commit
        self.taggedAt = taggedAt
    }

    /// Oldest first, name as the tie-break.
    ///
    /// The tie-break is not decoration. Two tags cut on the same commit share a timestamp,
    /// and the binding they produce is **permanent** — so an order that depended on which
    /// one the API happened to list first would pin a pull request to a different release
    /// depending on the poll it bound in.
    public static func precedes(_ lhs: TagCandidate, _ rhs: TagCandidate) -> Bool {
        if lhs.taggedAt != rhs.taggedAt { return lhs.taggedAt < rhs.taggedAt }
        return lhs.name < rhs.name
    }

    /// `nil` when the ref carries no name or no date of its own — there is nothing to order
    /// it by, and a candidate that cannot be ordered cannot be tested oldest-first.
    init?(_ ref: TagRefDTO) {
        guard let name = ref.name, !name.isEmpty, let target = ref.target else { return nil }

        if target.typeName == "Tag" {
            // Annotated: the commit is one level in, and the tag's date is the tagger's.
            let commit = target.target?.oid
            guard let taggedAt = target.tagger?.date ?? target.target?.committedDate else { return nil }
            self.init(name: name, commit: commit, taggedAt: taggedAt)
        } else {
            guard let taggedAt = target.committedDate else { return nil }
            self.init(name: name, commit: target.oid, taggedAt: taggedAt)
        }
    }
}

/// One repository's worth of matching tags.
public struct TagFetch: Equatable, Sendable {
    public var repository: String
    /// Matching the configured glob, oldest first by ``TagCandidate/precedes(_:_:)``.
    public var candidates: [TagCandidate]
    public var pagesFetched: Int
    public var pointsSpent: Int
    public var rateLimit: RateLimit?
    /// False when pagination stopped at the page cap, so the candidate list may be missing
    /// tags — which shows up as a pull request that is not shipped *yet*, rather than as an
    /// error.
    public var isComplete: Bool
    public var warnings: [FetchWarning]

    public init(
        repository: String,
        candidates: [TagCandidate],
        pagesFetched: Int = 0,
        pointsSpent: Int = 0,
        rateLimit: RateLimit? = nil,
        isComplete: Bool = true,
        warnings: [FetchWarning] = []
    ) {
        self.repository = repository
        self.candidates = candidates
        self.pagesFetched = pagesFetched
        self.pointsSpent = pointsSpent
        self.rateLimit = rateLimit
        self.isComplete = isComplete
        self.warnings = warnings
    }
}

/// Reads a repository's release tags, paginated to completion.
public struct TagRefsClient {
    public struct Configuration: Equatable, Sendable {
        /// GitHub's maximum for this connection.
        public var pageSize: Int
        /// A safety cap, as on the pull request search. Ten pages is a thousand matching
        /// tags in one repository, which is far past the point where the pattern is wrong.
        public var pageCap: Int
        public var endpoint: URL

        public init(pageSize: Int = 100, pageCap: Int = 10, endpoint: URL = GitHubAPI.graphQLEndpoint) {
            self.pageSize = min(100, max(1, pageSize))
            self.pageCap = max(1, pageCap)
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

    /// Every tag in `repository` matching `glob`, oldest first.
    ///
    /// Walking every page is not optional: a repository that tags often can easily push the
    /// matching tag past the first page, and a truncated candidate list produces a false
    /// "not shipped yet" that never self-corrects.
    ///
    /// **Server ordering is for pagination determinism only.** `TAG_COMMIT_DATE` sorts by
    /// the *target commit's* date, not by when the tag was cut, so a tag created today
    /// against an older commit sorts ahead of one cut last week against a newer commit.
    /// Since the binding is permanent, taking the server's first hit can pin a pull request
    /// to a later release forever — so the candidates are re-sorted locally by their own
    /// timestamps before anything is compared.
    public func fetchCandidates(repository: String, glob: Glob) async throws -> TagFetch {
        guard let (owner, name) = TagRefsClient.ownerAndName(repository) else {
            return TagFetch(
                repository: repository,
                candidates: [],
                warnings: [.repositoryDropped(repository)]
            )
        }

        let prefix = glob.literalPrefix
        var warnings: [FetchWarning] = []
        var candidates: [TagCandidate] = []
        var seen: Set<String> = []
        var rateLimit: RateLimit?
        var pointsSpent = 0
        var pages = 0
        var cursor: String?
        var isComplete = true

        pagination: while true {
            let result: GraphQLResult<TagRefsPayload> = try await graphQL.perform(
                query: TagRefsQuery.text,
                variables: TagRefsQuery.variables(
                    owner: owner,
                    name: name,
                    // Omitted entirely when the pattern opens with a wildcard: `*-prod` has
                    // no prefix, and any guess would hide tags the glob would have matched.
                    prefilter: prefix.isEmpty ? nil : prefix,
                    pageSize: configuration.pageSize,
                    cursor: cursor
                )
            )
            pages += 1
            warnings.append(contentsOf: result.errors.map(FetchWarning.graphQL))
            if let reported = result.data.rateLimit?.rateLimit {
                rateLimit = reported
                pointsSpent += max(0, reported.cost)
            }

            let connection = result.data.repository?.refs
            for ref in (connection?.nodes ?? []).compactMap({ $0 }) {
                guard let candidate = TagCandidate(ref) else { continue }
                // The glob in full, locally. The server-side `query` is a substring filter
                // and admits far more than the pattern does.
                guard glob.matches(candidate.name) else { continue }
                // Tags are unique by name; a repeat can only be the ref list shifting under
                // pagination, and keeping the first sighting makes the answer the same
                // either way.
                guard seen.insert(candidate.name).inserted else { continue }
                candidates.append(candidate)
            }

            let pageInfo = connection?.pageInfo
            let hasNextPage = (pageInfo?.hasNextPage ?? false) && pageInfo?.endCursor != nil
            guard hasNextPage else { break pagination }
            cursor = pageInfo?.endCursor

            if pages >= configuration.pageCap {
                isComplete = false
                warnings.append(.tagPageCapReached(repository: repository, pages: pages))
                break pagination
            }
        }

        candidates.sort(by: TagCandidate.precedes)
        return TagFetch(
            repository: repository,
            candidates: candidates,
            pagesFetched: pages,
            pointsSpent: pointsSpent,
            rateLimit: rateLimit,
            isComplete: isComplete,
            warnings: warnings
        )
    }

    /// `owner/name`, split once and validated the same way the search qualifiers are.
    static func ownerAndName(_ repository: String) -> (owner: String, name: String)? {
        let trimmed = repository.trimmingCharacters(in: .whitespacesAndNewlines)
        guard RepoScope.isWellFormed(trimmed) else { return nil }
        let parts = trimmed.split(separator: "/")
        return (String(parts[0]), String(parts[1]))
    }
}
