import Foundation
import NetKit
import PRStackCore
import XCTest
@testable import GitHubKit

final class MergeCommitRecoveryTests: XCTestCase {
    private let endpoint = URL(string: "https://api.github.test/graphql")!
    private let mergedAt = ISO8601DateFormatter().date(from: "2026-01-18T10:00:00Z")!

    private func recovery(_ transport: StubTransport, depth: Int = 100) -> MergeCommitRecovery {
        MergeCommitRecovery(
            transport: transport,
            tokenProvider: StaticTokenProvider("ghp_test"),
            configuration: MergeCommitRecovery.Configuration(historyDepth: depth, endpoint: endpoint)
        )
    }

    private func merged(_ number: Int, repo: String = "acme/billing", commit: String? = nil) -> PullRequest {
        PullRequest(
            repo: repo,
            number: number,
            title: "Merged \(number)",
            headRef: "avery/branch-\(number)",
            baseRef: "main",
            state: .merged,
            mergeCommit: commit,
            updatedAt: mergedAt,
            mergedAt: mergedAt
        )
    }

    /// `history` comes back newest first.
    private func history(_ commits: [(oid: String, headline: String)], remaining: Int = 4_900) -> String {
        let nodes = commits.map { commit -> String in
            // A revert's headline quotes the commit it undoes, so the escaping is not
            // hypothetical — unescaped, the fixture is not JSON at all.
            let headline = commit.headline
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "\"", with: "\\\"")
            return #"{"oid":"\#(commit.oid)","messageHeadline":"\#(headline)"}"#
        }
        return """
        {
          "data": {
            "rateLimit": {
              "limit": 5000, "cost": 1, "remaining": \(remaining), "resetAt": "2026-01-20T13:00:00Z"
            },
            "repository": {
              "defaultBranchRef": {
                "name": "main",
                "target": {
                  "__typename": "Commit",
                  "history": { "nodes": [\(nodes.joined(separator: ","))] }
                }
              }
            }
          }
        }
        """
    }

    func testTheParenthesisedFormIsWhatCounts() {
        XCTAssertEqual(
            MergeCommitRecovery.referencedNumbers(in: "Invoice renderer (#4012)"),
            [4012]
        )
        XCTAssertEqual(
            MergeCommitRecovery.referencedNumbers(in: "Revert \"A (#12)\" (#34)"),
            [12, 34]
        )
        // A bare mention is not a merge, and binding on it would be permanent.
        XCTAssertEqual(MergeCommitRecovery.referencedNumbers(in: "reverts #4012"), [])
        XCTAssertEqual(MergeCommitRecovery.referencedNumbers(in: "chore: bump (#)"), [])
        XCTAssertEqual(MergeCommitRecovery.referencedNumbers(in: "chore (#0)"), [])
        XCTAssertEqual(MergeCommitRecovery.referencedNumbers(in: "no references here"), [])
    }

    func testAMissingMergeCommitIsRecoveredFromTrunk() async throws {
        let transport = StubTransport(responses: [
            .json(history([
                ("newest", "Something else (#4099)"),
                ("squashed", "Invoice renderer (#4012)")
            ]))
        ])

        let result = try await recovery(transport).recover([merged(4012)])

        XCTAssertEqual(result.commits, [PRID(repo: "acme/billing", number: 4012): "squashed"])
        XCTAssertEqual(result.pointsSpent, 1)
        let variables = try transport.requestVariables(0)
        XCTAssertEqual(variables["owner"] as? String, "acme")
        XCTAssertEqual(variables["depth"] as? Int, 100)
    }

    /// A revert names the pull request it undoes. Taking the newer commit would test
    /// containment against the revert, and bind the wrong release permanently.
    func testTheOldestMentionWins() async throws {
        let transport = StubTransport(responses: [
            .json(history([
                ("revert", "Revert \"Invoice renderer (#4012)\""),
                ("merge", "Invoice renderer (#4012)")
            ]))
        ])

        let result = try await recovery(transport).recover([merged(4012)])
        XCTAssertEqual(result.commits[PRID(repo: "acme/billing", number: 4012)], "merge")
    }

    /// The common case, and it has to stay free: nothing is missing a commit, so no request
    /// goes out at all.
    func testNoRequestWhenEveryMergeAlreadyHasItsCommit() async throws {
        let transport = StubTransport(responses: [])
        let result = try await recovery(transport).recover([merged(4012, commit: "9f1c2ab")])

        XCTAssertEqual(result, .empty)
        XCTAssertTrue(transport.requests.isEmpty)
    }

    /// One query per affected repository, not per pull request.
    func testOneQueryPerRepository() async throws {
        let transport = StubTransport(responses: [
            .json(history([("a", "One (#1)"), ("b", "Two (#2)")])),
            .json(history([("c", "Three (#3)")]))
        ])

        let result = try await recovery(transport).recover([
            merged(1),
            merged(2),
            merged(3, repo: "acme/web")
        ])

        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertEqual(result.commits.count, 3)
        XCTAssertEqual(result.commits[PRID(repo: "acme/web", number: 3)], "c")
    }

    /// The floor applies between repositories too. `GitHubPoll` only sees the allowance
    /// this returns, so it can stop the tag pass but not these requests.
    func testALowAllowanceStopsAfterTheCurrentRepository() async throws {
        let transport = StubTransport(responses: [
            .json(history([("a", "One (#1)")], remaining: 400))
        ])

        let result = try await recovery(transport).recover([merged(1), merged(3, repo: "acme/web")])

        XCTAssertEqual(transport.requests.count, 1, "the second repository is not read")
        // Whatever the first repository recovered is kept.
        XCTAssertEqual(result.commits, [PRID(repo: "acme/billing", number: 1): "a"])
        XCTAssertEqual(
            result.warnings.last?.description.contains("deferred release tracking"),
            true
        )
    }

    /// A pull request nothing on trunk mentions is left alone rather than guessed at. It
    /// stays at `merged · awaiting release`, which per PRD §10 is quiet by design.
    func testAnUnmatchedPullRequestIsLeftAlone() async throws {
        let transport = StubTransport(responses: [.json(history([("x", "Unrelated (#99)")]))])
        let result = try await recovery(transport).recover([merged(4012)])
        XCTAssertTrue(result.commits.isEmpty)
    }

    /// Recovery is a GraphQL request in service of a merge that will not be compared this
    /// poll anyway, so below the floor it defers with everything else release-related.
    func testALowAllowanceSkipsRecoveryEntirely() async throws {
        let transport = StubTransport(responses: [
            .json(SearchPage.json(numbers: [], hasNextPage: false, endCursor: nil)),
            .json(
                SearchPage.json(
                    numbers: [4012],
                    hasNextPage: false,
                    endCursor: nil,
                    remaining: 400,
                    state: "MERGED",
                    mergedAt: "2026-01-18T10:00:00Z"
                )
            )
        ])
        let client = GitHubClient(
            transport: transport,
            tokenProvider: StaticTokenProvider("ghp_test"),
            configuration: GitHubClient.Configuration(endpoint: endpoint)
        )

        let result = try await GitHubPoll(client: client, recovery: recovery(transport))
            .run(scope: .all, local: .empty, now: mergedAt)

        XCTAssertEqual(transport.requests.count, 2, "no trunk history request")
        XCTAssertEqual(result.recovery, .empty)
        XCTAssertNil(result.pullRequests.first?.mergeCommit)
    }

    func testTheRecoveredCommitReachesTheMergeRecord() async throws {
        let transport = StubTransport(responses: [
            .json(SearchPage.json(numbers: [], hasNextPage: false, endCursor: nil)),
            .json(
                SearchPage.json(
                    numbers: [4012],
                    hasNextPage: false,
                    endCursor: nil,
                    state: "MERGED",
                    mergedAt: "2026-01-18T10:00:00Z"
                )
            ),
            .json(history([("squashed", "Invoice renderer (#4012)")]))
        ])
        let client = GitHubClient(
            transport: transport,
            tokenProvider: StaticTokenProvider("ghp_test"),
            configuration: GitHubClient.Configuration(endpoint: endpoint)
        )

        let result = try await GitHubPoll(client: client, recovery: recovery(transport))
            .run(scope: .all, local: .empty, now: mergedAt)

        let id = PRID(repo: "acme/billing", number: 4012)
        XCTAssertEqual(result.pullRequests.first?.mergeCommit, "squashed")

        var local = LocalState.empty
        result.apply(to: &local)
        XCTAssertEqual(local.unboundMerges[id]?.mergeCommit, "squashed")
    }
}
