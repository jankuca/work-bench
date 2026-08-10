import Foundation

/// The wire shape of the pull request search.
///
/// Almost every field is optional, which is deliberate rather than lazy. `search(type:
/// ISSUE)` returns a union: `... on PullRequest` fills the fields for pull requests and
/// leaves `{ "__typename": "Issue" }` for everything else. A DTO with required fields
/// would throw on the first issue in the results and lose the whole page, so the shape is
/// permissive here and the requirements are enforced once, in ``PullRequestMapper``,
/// where a node that cannot become a domain value is reported as a warning instead.
struct SearchPayload: Decodable, Equatable {
    var rateLimit: RateLimitDTO? = nil
    var viewer: ActorDTO? = nil
    /// Optional for the same reason as everything else here, and this one is load-bearing:
    /// GraphQL nulls a field whose resolver failed and explains why in `errors`. A required
    /// `search` would make that response a decode failure, so the client would report
    /// `malformedResponse` and throw GitHub's own explanation away.
    var search: SearchConnectionDTO? = nil
}

struct RateLimitDTO: Decodable, Equatable {
    var limit: Int? = nil
    var cost: Int? = nil
    var remaining: Int? = nil
    var resetAt: Date? = nil

    var rateLimit: RateLimit {
        RateLimit(
            limit: limit ?? RateLimit.assumedHourlyLimit,
            cost: cost ?? 0,
            remaining: remaining ?? RateLimit.assumedHourlyLimit,
            resetAt: resetAt
        )
    }
}

struct SearchConnectionDTO: Decodable, Equatable {
    var issueCount: Int? = nil
    var pageInfo: PageInfoDTO? = nil
    var nodes: [PullRequestNodeDTO?]? = nil
}

struct PageInfoDTO: Decodable, Equatable {
    var hasNextPage: Bool? = nil
    var endCursor: String? = nil
}

struct ActorDTO: Decodable, Equatable {
    var login: String? = nil
    var avatarUrl: String? = nil
}

struct RepositoryDTO: Decodable, Equatable {
    var nameWithOwner: String? = nil
    var defaultBranchRef: RefDTO? = nil
}

struct RefDTO: Decodable, Equatable {
    var name: String? = nil
}

struct CommitRefDTO: Decodable, Equatable {
    var oid: String? = nil
}

struct CommentConnectionDTO: Decodable, Equatable {
    var totalCount: Int? = nil
    var nodes: [CommentDTO?]? = nil
}

struct CommentDTO: Decodable, Equatable {
    var createdAt: Date? = nil
}

struct ReviewConnectionDTO: Decodable, Equatable {
    var nodes: [ReviewDTO?]? = nil
}

struct ReviewDTO: Decodable, Equatable {
    var author: ActorDTO? = nil
    var state: String? = nil
    var submittedAt: Date? = nil
}

struct ReviewRequestConnectionDTO: Decodable, Equatable {
    var nodes: [ReviewRequestDTO?]? = nil
}

struct ReviewRequestDTO: Decodable, Equatable {
    var requestedReviewer: RequestedReviewerDTO? = nil
}

/// One member of the `RequestedReviewer` union. A `User` answers with `login`, a `Team`
/// with `slug`, and the two remaining members (`Bot`, `Mannequin`) answer with neither,
/// which is what ``name`` returning nil means.
struct RequestedReviewerDTO: Decodable, Equatable {
    var typeName: String? = nil
    // User
    var login: String? = nil
    var avatarUrl: String? = nil
    // Team
    var slug: String? = nil

    private enum CodingKeys: String, CodingKey {
        case typeName = "__typename"
        case login
        case avatarUrl
        case slug
    }

    /// What to put under the avatar, whichever half of the union answered.
    var name: String? {
        for candidate in [login, slug] {
            if let candidate, !candidate.isEmpty { return candidate }
        }
        return nil
    }
}

struct CommitConnectionDTO: Decodable, Equatable {
    var nodes: [CommitWrapperDTO?]? = nil
}

struct CommitWrapperDTO: Decodable, Equatable {
    var commit: CommitDTO? = nil
}

struct CommitDTO: Decodable, Equatable {
    var statusCheckRollup: StatusCheckRollupDTO? = nil
}

struct StatusCheckRollupDTO: Decodable, Equatable {
    var state: String? = nil
    var contexts: CheckContextConnectionDTO? = nil
}

struct CheckContextConnectionDTO: Decodable, Equatable {
    var totalCount: Int? = nil
    var nodes: [CheckContextDTO?]? = nil
}

/// One member of the `StatusCheckRollupContext` union — a `CheckRun` (Actions and most
/// apps) or a `StatusContext` (legacy commit statuses). Both sets of fields land here and
/// `typeName` says which half is populated.
struct CheckContextDTO: Decodable, Equatable {
    var typeName: String? = nil
    // CheckRun
    var name: String? = nil
    var conclusion: String? = nil
    var status: String? = nil
    var detailsUrl: String? = nil
    // StatusContext
    var context: String? = nil
    var state: String? = nil
    var targetUrl: String? = nil

    private enum CodingKeys: String, CodingKey {
        case typeName = "__typename"
        case name
        case conclusion
        case status
        case detailsUrl
        case context
        case state
        case targetUrl
    }

    /// Where this check reports, whichever half of the union it came from. Nothing renders
    /// it yet — the status phrase M3 draws is `2 checks failed`, from ``name`` and the
    /// rollup — but the query selects it, and a field that is selected and then dropped at
    /// decode time is a cost paid for nothing.
    var reportURL: String? { detailsUrl ?? targetUrl }
}

struct PullRequestNodeDTO: Decodable, Equatable {
    var typeName: String? = nil
    var number: Int? = nil
    var title: String? = nil
    /// Nullable on the wire and carried through deliberately: the body is the third source
    /// in the Linear identifier scan (M5), so dropping it here would silently file
    /// body-only references under `Other`.
    var body: String? = nil
    var url: String? = nil
    var headRefName: String? = nil
    var baseRefName: String? = nil
    var isDraft: Bool? = nil
    var state: String? = nil
    var createdAt: Date? = nil
    var updatedAt: Date? = nil
    var mergedAt: Date? = nil
    var mergeable: String? = nil
    var reviewDecision: String? = nil
    var mergeCommit: CommitRefDTO? = nil
    var author: ActorDTO? = nil
    var repository: RepositoryDTO? = nil
    var comments: CommentConnectionDTO? = nil
    var reviews: ReviewConnectionDTO? = nil
    var reviewRequests: ReviewRequestConnectionDTO? = nil
    var commits: CommitConnectionDTO? = nil

    private enum CodingKeys: String, CodingKey {
        case typeName = "__typename"
        case number
        case title
        case body
        case url
        case headRefName
        case baseRefName
        case isDraft
        case state
        case createdAt
        case updatedAt
        case mergedAt
        case mergeable
        case reviewDecision
        case mergeCommit
        case author
        case repository
        case comments
        case reviews
        case reviewRequests
        case commits
    }

    var isPullRequest: Bool { typeName == nil || typeName == "PullRequest" }
}
