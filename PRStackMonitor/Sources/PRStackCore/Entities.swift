import Foundation

// MARK: - Scalars

/// GitHub's tri-state for a pull request. `closed` means closed *without* merging;
/// a merged pull request reports `merged`, never `closed`. The row status precedence
/// in ``RowStatus`` depends on that distinction.
public enum GitHubState: String, Codable, Sendable {
    case open
    case merged
    case closed
}

public enum ReviewDecision: String, Codable, Sendable {
    case approved
    case changesRequested
    case reviewRequired
}

public enum ReviewState: String, Codable, Sendable {
    case approved
    case changesRequested
    case commented
    case pending
    case dismissed
    /// Asked for a review and has not submitted one. Not a state GitHub reports on a
    /// review — there is no review yet — it comes from the pull request's open review
    /// requests, which is the only place a reviewer who has done nothing exists at all.
    case requested
}

public enum Mergeable: String, Codable, Sendable {
    case mergeable
    case conflicting
    case unknown
}

/// The check rollup for a pull request's head commit.
///
/// Modelled as a struct rather than an enum with a payload so the fixture JSON stays
/// readable (`"checks": "passing"` or `"checks": {"state": "failing", "failingCount": 2}`)
/// and so the failing count survives round-tripping.
public struct CheckRollup: Hashable, Sendable {
    public enum State: String, Codable, Sendable {
        case noChecks
        case running
        case passing
        case failing
    }

    public var state: State
    /// How many contexts are failing. Feeds the row's status phrase (`2 checks failed`);
    /// it is not part of ``RowStatus``, which only records *that* checks are failing.
    public var failingCount: Int

    public init(state: State, failingCount: Int = 0) {
        self.state = state
        // Only a failing rollup carries a count. Without this, `{"state":"passing",
        // "failingCount":3}` decodes to a value that produces the same `digestToken` as
        // plain `"passing"` but compares unequal to it — the count is reachable through
        // `==` and `hash` while never reaching the digest.
        self.failingCount = state == .failing ? max(0, failingCount) : 0
    }

    public static let noChecks = CheckRollup(state: .noChecks)
    public static let running = CheckRollup(state: .running)
    public static let passing = CheckRollup(state: .passing)
    public static func failing(_ count: Int) -> CheckRollup {
        CheckRollup(state: .failing, failingCount: count)
    }

    public var isFailing: Bool { state == .failing }
    public var isPassing: Bool { state == .passing }

    /// Stable, process-independent spelling for the unread digest. Never use
    /// `hashValue` here: Swift's hashing is seeded per process, so a digest built
    /// from it would differ across launches and mark everything unread on relaunch.
    public var digestToken: String {
        state == .failing ? "failing:\(failingCount)" : state.rawValue
    }
}

extension CheckRollup: Codable {
    private enum CodingKeys: String, CodingKey {
        case state
        case failingCount
    }

    public init(from decoder: any Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let raw = try? single.decode(String.self) {
            guard let state = State(rawValue: raw) else {
                throw DecodingError.dataCorruptedError(
                    in: single,
                    debugDescription: "Unknown check rollup state '\(raw)'"
                )
            }
            self.init(state: state, failingCount: state == .failing ? 1 : 0)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let state = try container.decode(State.self, forKey: .state)
        let failingCount = try container.decodeIfPresent(Int.self, forKey: .failingCount)
        self.init(state: state, failingCount: failingCount ?? (state == .failing ? 1 : 0))
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(state, forKey: .state)
        try container.encode(failingCount, forKey: .failingCount)
    }
}

// MARK: - Linear

/// A Linear issue linked from a pull request, already resolved to its project.
///
/// `LinearKit` produces these at M5; `PRStackCore` only consumes them, and cares about
/// exactly two things: the order they arrive in, and whether each one has a project.
public struct IssueRef: Hashable, Sendable {
    /// The human-readable identifier, e.g. `BIL-312`. Kept in full throughout — never
    /// split into team key and number, which is what makes cross-team number collisions
    /// (`BIL-97` vs `SRC-97`) impossible to introduce here.
    public var identifier: String
    public var url: URL
    public var projectID: String?
    public var projectName: String?

    public init(identifier: String, url: URL? = nil, projectID: String? = nil, projectName: String? = nil) {
        self.identifier = identifier
        self.url = url ?? IssueRef.defaultURL(for: identifier)
        self.projectID = projectID
        self.projectName = projectName
    }

    public var hasProject: Bool { projectID != nil }

    static func defaultURL(for identifier: String) -> URL {
        URL(string: "https://linear.app/issue/\(identifier)") ?? URL(fileURLWithPath: "/")
    }
}

extension IssueRef: Codable {
    private enum CodingKeys: String, CodingKey {
        case identifier
        case url
        case projectID = "projectId"
        case projectName
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            identifier: try container.decode(String.self, forKey: .identifier),
            url: try container.decodeIfPresent(URL.self, forKey: .url),
            projectID: try container.decodeIfPresent(String.self, forKey: .projectID),
            projectName: try container.decodeIfPresent(String.self, forKey: .projectName)
        )
    }
}

// MARK: - Reviewers

public struct ReviewerState: Hashable, Sendable, Codable {
    public var login: String
    public var avatarURL: URL?
    public var state: ReviewState

    public init(login: String, avatarURL: URL? = nil, state: ReviewState) {
        self.login = login
        self.avatarURL = avatarURL
        self.state = state
    }
}

// MARK: - Release

/// Semantic release stage.
///
/// v1's tag tracker only ever produces the first three cases; `deploying` and
/// `deployFailed` exist so a future `DeploymentAPITracker` can populate them without
/// changing this type or the views that switch over it (IMPLEMENTATION_PLAN §3).
public enum ReleaseStage: Hashable, Sendable {
    case unmerged
    case mergedAwaitingTag
    case released(tag: String)
    /// Reserved — not produced in v1.
    case deploying(tag: String)
    /// Reserved — not produced in v1.
    case deployFailed(tag: String)

    /// Stable spelling for unread digests and golden files.
    public var digestToken: String {
        switch self {
        case .unmerged: return "unmerged"
        case .mergedAwaitingTag: return "mergedAwaitingTag"
        case .released(let tag): return "released:\(tag)"
        case .deploying(let tag): return "deploying:\(tag)"
        case .deployFailed(let tag): return "deployFailed:\(tag)"
        }
    }
}

// MARK: - Pull request

public struct PullRequest: Equatable, Sendable {
    /// `owner/name`.
    public var repo: String
    public var number: Int
    public var title: String
    /// Nullable, and carried through deliberately: the body is the third source in the
    /// Linear identifier scan, so dropping it silently files body-only references under
    /// `Other` (IMPLEMENTATION_PLAN §3).
    public var body: String?
    public var url: URL
    public var headRef: String
    public var baseRef: String
    public var isDraft: Bool
    public var state: GitHubState
    /// Only the viewer's own pull requests may act as stack parents, so authorship has
    /// to survive as far as derivation.
    public var authorLogin: String
    public var reviewDecision: ReviewDecision?
    public var reviews: [ReviewerState]
    public var checks: CheckRollup
    public var mergeable: Mergeable
    public var mergeCommit: String?
    public var createdAt: Date
    public var updatedAt: Date
    public var mergedAt: Date?
    public var commentCount: Int
    public var lastCommentAt: Date?
    /// Ordered, may be empty. The order comes from the pull request's own fields
    /// (branch, then title, then body), never from API response order, which is what
    /// keeps ``primaryIssue`` stable across polls.
    public var linearIssues: [IssueRef]

    public init(
        repo: String,
        number: Int,
        title: String,
        body: String? = nil,
        url: URL? = nil,
        headRef: String,
        baseRef: String,
        isDraft: Bool = false,
        state: GitHubState = .open,
        authorLogin: String = "",
        reviewDecision: ReviewDecision? = nil,
        reviews: [ReviewerState] = [],
        checks: CheckRollup = .noChecks,
        mergeable: Mergeable = .unknown,
        mergeCommit: String? = nil,
        createdAt: Date? = nil,
        updatedAt: Date,
        mergedAt: Date? = nil,
        commentCount: Int = 0,
        lastCommentAt: Date? = nil,
        linearIssues: [IssueRef] = []
    ) {
        self.repo = repo
        self.number = number
        self.title = title
        self.body = body
        self.url = url ?? PullRequest.defaultURL(repo: repo, number: number)
        self.headRef = headRef
        self.baseRef = baseRef
        self.isDraft = isDraft
        self.state = state
        self.authorLogin = authorLogin
        self.reviewDecision = reviewDecision
        self.reviews = reviews
        self.checks = checks
        self.mergeable = mergeable
        self.mergeCommit = mergeCommit
        self.createdAt = createdAt ?? updatedAt
        self.updatedAt = updatedAt
        self.mergedAt = mergedAt
        self.commentCount = commentCount
        self.lastCommentAt = lastCommentAt
        self.linearIssues = linearIssues
    }

    public var id: PRID { PRID(repo: repo, number: number) }

    /// First linked issue that has a project; falls back to the first linked issue;
    /// nil when none are linked. Drives section placement and the meta line.
    public var primaryIssue: IssueRef? {
        linearIssues.first(where: { $0.hasProject }) ?? linearIssues.first
    }

    /// The `+N` affix in the meta line — how many tickets this pull request resolves
    /// beyond the primary one.
    public var additionalIssueCount: Int {
        max(0, linearIssues.count - 1)
    }

    static func defaultURL(repo: String, number: Int) -> URL {
        URL(string: "https://github.com/\(repo)/pull/\(number)") ?? URL(fileURLWithPath: "/")
    }
}

extension PullRequest: Codable {
    private enum CodingKeys: String, CodingKey {
        case repo
        case number
        case title
        case body
        case url
        case headRef
        case baseRef
        case isDraft
        case state
        case authorLogin = "author"
        case reviewDecision
        case reviews
        case checks
        case mergeable
        case mergeCommit
        case createdAt
        case updatedAt
        case mergedAt
        case commentCount
        case lastCommentAt
        case linearIssues
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        // Identity is checked here rather than trusted downstream. `PullRequest.id` is what
        // `LocalState` persists, and its decoder drops a key it cannot parse — so an id that
        // cannot survive its own `rawValue` would take the user's dismissal or snooze for
        // that pull request with it, silently, on the next launch. This is the one place
        // untrusted input becomes a `PRID`, so it is the one place worth guarding.
        let repo = try container.decode(String.self, forKey: .repo)
        let number = try container.decode(Int.self, forKey: .number)
        guard PRID.isWellFormed(repo: repo, number: number) else {
            throw DecodingError.dataCorruptedError(
                forKey: .repo,
                in: container,
                debugDescription: "Expected 'owner/name' and a positive number, got '\(repo)' and \(number)"
            )
        }

        self.init(
            repo: repo,
            number: number,
            title: try container.decodeIfPresent(String.self, forKey: .title) ?? "",
            body: try container.decodeIfPresent(String.self, forKey: .body),
            url: try container.decodeIfPresent(URL.self, forKey: .url),
            headRef: try container.decodeIfPresent(String.self, forKey: .headRef) ?? "",
            baseRef: try container.decodeIfPresent(String.self, forKey: .baseRef) ?? "",
            isDraft: try container.decodeIfPresent(Bool.self, forKey: .isDraft) ?? false,
            state: try container.decodeIfPresent(GitHubState.self, forKey: .state) ?? .open,
            authorLogin: try container.decodeIfPresent(String.self, forKey: .authorLogin) ?? "",
            reviewDecision: try container.decodeIfPresent(ReviewDecision.self, forKey: .reviewDecision),
            reviews: try container.decodeIfPresent([ReviewerState].self, forKey: .reviews) ?? [],
            checks: try container.decodeIfPresent(CheckRollup.self, forKey: .checks) ?? .noChecks,
            mergeable: try container.decodeIfPresent(Mergeable.self, forKey: .mergeable) ?? .unknown,
            mergeCommit: try container.decodeIfPresent(String.self, forKey: .mergeCommit),
            createdAt: try container.decodeIfPresent(Date.self, forKey: .createdAt),
            updatedAt: try container.decode(Date.self, forKey: .updatedAt),
            mergedAt: try container.decodeIfPresent(Date.self, forKey: .mergedAt),
            commentCount: try container.decodeIfPresent(Int.self, forKey: .commentCount) ?? 0,
            lastCommentAt: try container.decodeIfPresent(Date.self, forKey: .lastCommentAt),
            linearIssues: try container.decodeIfPresent([IssueRef].self, forKey: .linearIssues) ?? []
        )
    }
}
