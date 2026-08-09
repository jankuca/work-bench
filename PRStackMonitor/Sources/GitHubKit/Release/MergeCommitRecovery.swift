import Foundation
import NetKit
import PRStackCore

/// The fallback for a merged pull request GitHub reports no merge commit for.
///
/// IMPLEMENTATION_PLAN §3 step 1: *"record `mergeCommit.oid` and `mergedAt`. Fallback if the
/// oid is absent (squash rewrote history): match `(#NNNN)` in recent trunk commit messages."*
///
/// It is rare — GitHub fills `mergeCommit` for squash and rebase merges alike — but it is not
/// self-correcting: with no commit there is nothing for a tag to contain, so the row sits at
/// `merged · awaiting release` for good. One query per affected repository, and only when
/// there is an affected repository, is a cheap way to close that.
public struct MergeCommitRecovery {
    public struct Configuration: Equatable, Sendable {
        /// How far back down the default branch to look. A hundred commits is a few days in
        /// a busy repository and months in a quiet one; past that, the merge is old enough
        /// that the tag which would have shipped it has long since been cut.
        public var historyDepth: Int
        public var endpoint: URL

        public init(historyDepth: Int = 100, endpoint: URL = GitHubAPI.graphQLEndpoint) {
            self.historyDepth = min(100, max(1, historyDepth))
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

    /// Which of `pullRequests` this can help: merged, dated, and missing a commit.
    public static func candidates(among pullRequests: [PullRequest]) -> [PullRequest] {
        pullRequests.filter { pullRequest in
            pullRequest.state == .merged
                && pullRequest.mergedAt != nil
                && (pullRequest.mergeCommit?.isEmpty ?? true)
        }
    }

    public func recover(_ pullRequests: [PullRequest]) async throws -> MergeCommitRecoveryResult {
        var result = MergeCommitRecoveryResult()
        let candidates = MergeCommitRecovery.candidates(among: pullRequests)
        guard !candidates.isEmpty else { return result }

        for repository in Set(candidates.map(\.repo)).sorted() {
            guard let (owner, name) = TagRefsClient.ownerAndName(repository) else {
                result.warnings.append(.repositoryDropped(repository))
                continue
            }

            let payload: GraphQLResult<TrunkHistoryPayload>
            do {
                payload = try await graphQL.perform(
                    query: TrunkHistoryQuery.text,
                    variables: TrunkHistoryQuery.variables(
                        owner: owner,
                        name: name,
                        depth: configuration.historyDepth
                    )
                )
            } catch let error as GitHubError {
                if error.endsThePoll { throw error }
                result.warnings.append(
                    .releaseTrackingFailed(repository: repository, reason: error.description)
                )
                continue
            }

            result.warnings.append(contentsOf: payload.errors.map(FetchWarning.graphQL))
            if let reported = payload.data.rateLimit?.rateLimit {
                result.rateLimit = reported
                result.pointsSpent += max(0, reported.cost)
            }

            let commits = payload.data.repository?.defaultBranchRef?.target?.history?.nodes ?? []
            let byNumber = MergeCommitRecovery.index(commits.compactMap { $0 })
            for candidate in candidates where candidate.repo == repository {
                guard let oid = byNumber[candidate.number] else { continue }
                result.commits[candidate.id] = oid
            }
        }

        return result
    }

    /// Pull request number → the **oldest** trunk commit that mentions it.
    ///
    /// `history` comes back newest first, so this walks it in reverse. That matters when a
    /// number appears twice: a revert names the pull request it undoes, and taking the newer
    /// commit would test containment against the revert rather than against the merge.
    static func index(_ commits: [TrunkCommitDTO]) -> [Int: String] {
        var byNumber: [Int: String] = [:]
        for commit in commits.reversed() {
            guard let oid = commit.oid, !oid.isEmpty else { continue }
            for number in MergeCommitRecovery.referencedNumbers(in: commit.messageHeadline ?? "") {
                // First writer wins, and walking in reverse makes that the oldest commit.
                // Assigning unconditionally would let the newest mention overwrite it,
                // which is the revert case exactly.
                guard byNumber[number] == nil else { continue }
                byNumber[number] = oid
            }
        }
        return byNumber
    }

    /// Every `(#NNNN)` in a commit message, in order.
    ///
    /// The parenthesised form specifically, which is what GitHub's squash and merge commits
    /// use. A bare `#4012` in prose — "reverts the approach from #4012" — is a mention, not
    /// a merge, and matching it would bind the wrong commit permanently.
    static func referencedNumbers(in message: String) -> [Int] {
        let characters = Array(message)
        var numbers: [Int] = []
        var index = 0

        while index < characters.count {
            guard characters[index] == "(",
                  index + 1 < characters.count,
                  characters[index + 1] == "#" else {
                index += 1
                continue
            }

            var cursor = index + 2
            var digits = ""
            while cursor < characters.count, characters[cursor].isASCII, characters[cursor].isNumber {
                digits.append(characters[cursor])
                cursor += 1
            }

            if cursor < characters.count, characters[cursor] == ")", let number = Int(digits), number > 0 {
                numbers.append(number)
                index = cursor + 1
            } else {
                index += 1
            }
        }
        return numbers
    }
}

/// Merge commits recovered from trunk, for pull requests GitHub reported none for.
public struct MergeCommitRecoveryResult: Equatable, Sendable {
    public var commits: [PRID: String]
    public var pointsSpent: Int
    public var rateLimit: RateLimit?
    public var warnings: [FetchWarning]

    public init(
        commits: [PRID: String] = [:],
        pointsSpent: Int = 0,
        rateLimit: RateLimit? = nil,
        warnings: [FetchWarning] = []
    ) {
        self.commits = commits
        self.pointsSpent = pointsSpent
        self.rateLimit = rateLimit
        self.warnings = warnings
    }

    public static let empty = MergeCommitRecoveryResult()
}

enum TrunkHistoryQuery {
    /// The default branch is read, never configured — trunk is whatever each repository
    /// reports (IMPLEMENTATION_PLAN §3), so this asks for it rather than taking a name.
    static let text = """
    query TrunkHistory($owner: String!, $name: String!, $depth: Int!) {
      rateLimit { limit cost remaining resetAt }
      repository(owner: $owner, name: $name) {
        defaultBranchRef {
          name
          target {
            __typename
            ... on Commit {
              history(first: $depth) {
                nodes { oid messageHeadline }
              }
            }
          }
        }
      }
    }
    """

    static func variables(owner: String, name: String, depth: Int) -> [String: GraphQLValue] {
        ["owner": .string(owner), "name": .string(name), "depth": .int(depth)]
    }
}

struct TrunkHistoryPayload: Decodable, Equatable {
    var rateLimit: RateLimitDTO? = nil
    var repository: TrunkRepositoryDTO? = nil
}

struct TrunkRepositoryDTO: Decodable, Equatable {
    var defaultBranchRef: TrunkRefDTO? = nil
}

struct TrunkRefDTO: Decodable, Equatable {
    var name: String? = nil
    var target: TrunkTargetDTO? = nil
}

struct TrunkTargetDTO: Decodable, Equatable {
    var typeName: String? = nil
    var history: CommitHistoryDTO? = nil

    private enum CodingKeys: String, CodingKey {
        case typeName = "__typename"
        case history
    }
}

struct CommitHistoryDTO: Decodable, Equatable {
    var nodes: [TrunkCommitDTO?]? = nil
}

struct TrunkCommitDTO: Decodable, Equatable {
    var oid: String? = nil
    var messageHeadline: String? = nil
}
