import Foundation
import NetKit
import PRStackCore

/// Finds the pull request that owns a branch somebody else's merge landed on.
///
/// The one thing the panel cannot work out for itself. Both sweeps carry
/// ``SearchQuery/baseQualifiers`` — `is:pr author:@me` — so a colleague's pull request is
/// never fetched, and `StackLayout` only ever indexes the viewer's own. When you open a
/// pull request on top of theirs and it is merged into their branch, no amount of local
/// walking reaches the thing that decides whether your change shipped.
///
/// So it is asked for directly, by branch: `pullRequests(headRefName:)` rather than a
/// search. The difference matters twice over — the search index lags a merge by up to a
/// minute, and every search this app makes is author-scoped, while this reads the
/// repository live and answers for whoever wrote it.
///
/// Chains resolve in rounds inside one call: each answer carries the next base branch, so a
/// stack three deep costs three requests rather than three polls. The rounds are capped by
/// ``MergeChain/maximumDepth``, and what a round cannot settle simply has no anchor written
/// for it — the row goes on reading `merged · awaiting release` until a later poll asks
/// again, which is exactly where it was before.
public struct BaseBranchResolver {
    public struct Configuration: Equatable, Sendable {
        /// How many levels of chain one call will follow.
        public var maximumDepth: Int
        /// How many distinct branches one round asks about. They are aliased into a single
        /// document, so this bounds the size of one request rather than a number of them.
        public var branchesPerRound: Int
        /// How many pull requests to read per branch. More than one because a branch name
        /// can have been reused; ``MergeChain/claims(_:child:)`` picks between them, and
        /// anything ambiguous is left unresolved rather than guessed at.
        public var candidatesPerBranch: Int
        public var endpoint: URL

        public init(
            maximumDepth: Int = MergeChain.maximumDepth,
            branchesPerRound: Int = MergeChain.anchorLookupLimit,
            candidatesPerBranch: Int = 5,
            endpoint: URL = GitHubAPI.graphQLEndpoint
        ) {
            self.maximumDepth = min(16, max(1, maximumDepth))
            self.branchesPerRound = min(50, max(1, branchesPerRound))
            self.candidatesPerBranch = min(20, max(1, candidatesPerBranch))
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

    /// Resolves each pull request's chain as far as it goes.
    ///
    /// Throws only for failures that end the poll. A repository that will not answer, a
    /// branch nothing owns, an ambiguous branch name — each of those is one pull request's
    /// problem, reported as a warning, and every other chain still resolves.
    public func resolve(_ pullRequests: [PullRequest], now: Date) async throws -> BaseBranchResolution {
        var result = BaseBranchResolution()
        guard !pullRequests.isEmpty else { return result }

        /// One chain, mid-walk. `merged` is when the thing that landed on this branch
        /// merged, which is what ``MergeChain/claims(_:child:)`` tests the candidates
        /// against — at the first level that is the row's own merge, deeper in it is the
        /// parent's.
        struct Walk {
            let id: PRID
            var repo: String
            var branch: String
            var merged: Date
            var seen: Set<PRID>
        }

        var walks: [Walk] = pullRequests.compactMap { pullRequest in
            guard let mergedAt = pullRequest.mergedAt, !pullRequest.baseRef.isEmpty else { return nil }
            return Walk(
                id: pullRequest.id,
                repo: pullRequest.repo,
                branch: pullRequest.baseRef,
                merged: mergedAt,
                seen: [pullRequest.id]
            )
        }

        var round = 0
        while !walks.isEmpty, round < configuration.maximumDepth {
            round += 1

            let branches = BaseBranchResolver.distinctBranches(
                of: walks.map { BranchKey(repo: $0.repo, ref: $0.branch) },
                limit: configuration.branchesPerRound
            )
            guard let query = BaseBranchQuery.text(
                for: branches,
                candidates: configuration.candidatesPerBranch
            ) else { break }

            let payload: GraphQLResult<BaseBranchPayload>
            do {
                payload = try await graphQL.perform(query: query)
            } catch let error as GitHubError {
                // An expired token or a spent allowance ends the poll; anything narrower
                // leaves these chains for the next one, which is where they already were.
                if error.endsThePoll { throw error }
                result.warnings.append(.baseBranchUnresolved(reason: error.description))
                return result
            }

            result.warnings.append(contentsOf: payload.errors.map(FetchWarning.graphQL))
            if let reported = payload.data.rateLimit?.rateLimit {
                result.rateLimit = reported
                result.pointsSpent += max(0, reported.cost)
            }

            // Keyed by the branch each answer *produces*, read off the nodes themselves
            // rather than inferred from an alias — the same discipline the priority
            // refresh uses, and for the same reason.
            let index = MergeChain.headIndex(payload.data.pullRequests)

            var next: [Walk] = []
            for walk in walks {
                let key = BranchKey(repo: walk.repo, ref: walk.branch)
                // Not asked about this round: the branch cap deferred it. Carried forward
                // untouched so the next round picks it up.
                guard branches.contains(key) else {
                    next.append(walk)
                    continue
                }

                let candidates = (index[key] ?? []).filter { candidate in
                    guard !walk.seen.contains(candidate.id) else { return false }
                    return BaseBranchResolver.claims(candidate, mergedAt: walk.merged)
                }

                guard let parent = candidates.first else {
                    // Nothing owns the branch. That is an answer, not a failure: a merge
                    // into a long-lived integration branch has no pull request to follow,
                    // and saying so is what stops the row asking forever.
                    result.anchors[walk.id] = MergeAnchor(
                        outcome: .untracked(branch: walk.branch),
                        checkedAt: now
                    )
                    continue
                }
                guard candidates.count == 1 else {
                    // A reused branch name with two live claims. Left unresolved rather
                    // than guessed at: the binding downstream of this is permanent.
                    result.warnings.append(
                        .baseBranchAmbiguous(repository: walk.repo, branch: walk.branch)
                    )
                    continue
                }

                switch parent.state {
                case .open:
                    result.anchors[walk.id] = MergeAnchor(outcome: .pending(parent.id), checkedAt: now)
                case .closed:
                    result.anchors[walk.id] = MergeAnchor(outcome: .abandoned(parent.id), checkedAt: now)
                case .merged:
                    guard let parentMergedAt = parent.mergedAt else {
                        result.warnings.append(
                            .baseBranchUnresolved(reason: "\(parent.id) reports no merge date")
                        )
                        continue
                    }
                    guard parent.mergedIntoDefaultBranch else {
                        // Another level. The chain continues from the parent's own base.
                        var advanced = walk
                        advanced.branch = parent.baseRef
                        advanced.merged = parentMergedAt
                        advanced.seen.insert(parent.id)
                        guard !parent.baseRef.isEmpty else { continue }
                        next.append(advanced)
                        continue
                    }
                    guard let commit = parent.mergeCommit, !commit.isEmpty else {
                        // Reached trunk with nothing for a tag to contain. Left unresolved
                        // so a later poll can try again — GitHub fills this field for
                        // squash and rebase merges alike, so an absence here is transient
                        // far more often than it is permanent.
                        result.warnings.append(
                            .baseBranchUnresolved(reason: "\(parent.id) reports no merge commit")
                        )
                        continue
                    }
                    result.anchors[walk.id] = MergeAnchor(
                        outcome: .landed(root: parent.id, commit: commit, mergedAt: parentMergedAt),
                        checkedAt: now
                    )
                }
            }

            walks = next

            // The floor stops the walk between rounds. Whatever resolved is kept, and the
            // chains still walking resume on a later poll from wherever their last anchor
            // left them.
            if let limit = result.rateLimit, limit.isBelowFloor {
                result.warnings.append(
                    .releaseTrackingDeferred(
                        reason: "GitHub allowance low (\(limit.remaining) of \(limit.limit) points left)"
                    )
                )
                break
            }
        }

        return result
    }

    /// Whether a candidate pull request can be the one something merged into at `mergedAt`.
    ///
    /// ``MergeChain/claims(_:child:)`` with the child reduced to the one thing it is asked
    /// about, because deeper in a walk there is no child pull request any more — only the
    /// moment the level below it merged.
    static func claims(_ parent: PullRequest, mergedAt: Date) -> Bool {
        guard parent.createdAt <= mergedAt else { return false }
        guard let parentMergedAt = parent.mergedAt else { return true }
        return mergedAt <= parentMergedAt
    }

    /// The branches to ask about this round, de-duplicated and capped, in a stable order.
    ///
    /// Sorted rather than taken in walk order so two polls over the same state ask about
    /// the same branches: which chains get the round's allowance must not depend on
    /// dictionary iteration.
    static func distinctBranches(of keys: [BranchKey], limit: Int) -> Set<BranchKey> {
        var seen: Set<BranchKey> = []
        var ordered: [BranchKey] = []
        for key in keys.sorted(by: { left, right in
            if left.repo != right.repo { return left.repo < right.repo }
            return left.ref < right.ref
        }) {
            guard seen.insert(key).inserted else { continue }
            ordered.append(key)
        }
        return Set(ordered.prefix(max(0, limit)))
    }
}

/// What one resolution pass learned. A **value**, handed back to whoever owns `LocalState`
/// rather than written from here — the same single-writer rule the release tracker follows.
public struct BaseBranchResolution: Equatable, Sendable {
    /// The chain outcome per pull request, ready for ``LocalState/recordAnchor(_:for:)``.
    public var anchors: [PRID: MergeAnchor]
    public var pointsSpent: Int
    public var rateLimit: RateLimit?
    public var warnings: [FetchWarning]

    public init(
        anchors: [PRID: MergeAnchor] = [:],
        pointsSpent: Int = 0,
        rateLimit: RateLimit? = nil,
        warnings: [FetchWarning] = []
    ) {
        self.anchors = anchors
        self.pointsSpent = pointsSpent
        self.rateLimit = rateLimit
        self.warnings = warnings
    }

    public static let empty = BaseBranchResolution()

    public var isEmpty: Bool { anchors.isEmpty && warnings.isEmpty }
}

extension LocalState {
    /// Merges a resolution pass's findings in. The one place merge anchors enter local
    /// state.
    public mutating func apply(_ resolution: BaseBranchResolution) {
        // Sorted, so a pass that resolves several chains writes them in the same order
        // every run. Nothing here depends on the order, but the state file is meant to be
        // diffable between two writes of the same state.
        for id in resolution.anchors.keys.sorted(by: PRID.panelOrder) {
            guard let anchor = resolution.anchors[id] else { continue }
            recordAnchor(anchor, for: id)
        }
    }
}

/// One aliased `repository { pullRequests(headRefName:) }` per branch, in a single query.
///
/// `pullRequests(headRefName:)` rather than `search`: it is not author-scoped, and it reads
/// the repository rather than the search index, which lags a merge by up to a minute.
enum BaseBranchQuery {
    /// The document, or nil when no branch survived validation.
    ///
    /// Owner and name are interpolated, which is safe for the same reason it is in
    /// ``KnownPullRequestQuery``: both halves have been through ``RepoScope/isWellFormed(_:)``.
    /// The branch has *not* — a ref may contain almost anything — so it is escaped rather
    /// than trusted, and a branch that cannot be spelled safely is dropped.
    static func text(for branches: Set<BranchKey>, candidates: Int) -> String? {
        var selections: [String] = []
        let ordered = branches.sorted { left, right in
            if left.repo != right.repo { return left.repo < right.repo }
            return left.ref < right.ref
        }

        for (index, key) in ordered.enumerated() {
            guard let (owner, name) = TagRefsClient.ownerAndName(key.repo),
                  let ref = BaseBranchQuery.escaped(key.ref) else { continue }
            selections.append(
                "  b\(index): repository(owner: \"\(owner)\", name: \"\(name)\")"
                    + " { pullRequests(headRefName: \(ref), first: \(candidates),"
                    + " orderBy: { field: CREATED_AT, direction: DESC })"
                    + " { nodes { ...PullRequestFields } } }"
            )
        }
        guard !selections.isEmpty else { return nil }

        return """
        query BaseBranchPullRequests {
          rateLimit { limit cost remaining resetAt }
        \(selections.joined(separator: "\n"))
        }

        \(PullRequestQuery.fields)
        """
    }

    /// A branch name as a GraphQL string literal, or nil when it cannot be one.
    ///
    /// Git allows characters in a ref that GraphQL's string syntax does not carry
    /// literally, so the two that matter are escaped and the ones that cannot appear in a
    /// document at all are refused. A refused branch resolves to nothing, which reads the
    /// same as a branch nobody owns — no request is made and no anchor is written.
    static func escaped(_ ref: String) -> String? {
        guard !ref.isEmpty, ref.count <= 255 else { return nil }
        // A ref cannot contain these, and a document must not: rejecting rather than
        // escaping keeps the query text something a person can read in a debug dump.
        guard !ref.contains(where: { $0.isNewline || $0 == "\u{0}" }) else { return nil }
        let escaped = ref
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}

/// The wire shape of ``BaseBranchQuery``: `rateLimit`, and one aliased repository per
/// branch.
///
/// The aliases are `b0`, `b1`, … — a set no `CodingKey` enum can list — so the keys are
/// read dynamically. Nothing is inferred from an alias: every node carries its own
/// repository and head branch, which is what the caller keys the answer on.
struct BaseBranchPayload: Decodable, Equatable {
    var rateLimit: RateLimitDTO?
    var pullRequests: [PullRequest]

    init(rateLimit: RateLimitDTO? = nil, pullRequests: [PullRequest] = []) {
        self.rateLimit = rateLimit
        self.pullRequests = pullRequests
    }

    private struct AliasKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }

        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    private struct RepositoryEntry: Decodable, Equatable {
        var pullRequests: NodeList? = nil

        struct NodeList: Decodable, Equatable {
            var nodes: [PullRequestNodeDTO?]? = nil
        }
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: AliasKey.self)
        var rateLimit: RateLimitDTO?
        var mapped: [PullRequest] = []

        for key in container.allKeys {
            if key.stringValue == "rateLimit" {
                rateLimit = try container.decodeIfPresent(RateLimitDTO.self, forKey: key)
                continue
            }
            guard let entry = try container.decodeIfPresent(RepositoryEntry.self, forKey: key) else {
                continue
            }
            for node in entry.pullRequests?.nodes ?? [] {
                guard let node else { continue }
                // A node that cannot become a domain value is dropped rather than reported:
                // this query asks a repository for its own pull requests, so a skip here is
                // a shape the mapper does not recognise, and one unusable candidate must
                // not take the branch's other candidates with it.
                guard case .mapped(let pullRequest) = PullRequestMapper.map(node) else { continue }
                mapped.append(pullRequest)
            }
        }

        self.init(rateLimit: rateLimit, pullRequests: mapped)
    }
}
