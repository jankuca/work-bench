import Foundation
import NetKit
import XCTest
@testable import GitHubKit
@testable import PRStackCore

/// Following a merge that landed on somebody else's branch.
///
/// The case these exist for is the one no local walk can reach: you open a pull request on
/// top of a colleague's, it is merged into their branch, and their pull request decides
/// whether your change ever shipped. Both of the poll's searches carry `author:@me`, so
/// theirs is never fetched — this is the only thing that asks about it.
final class BaseBranchResolverTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_767_900_000)

    private func resolver(
        _ transport: StubTransport,
        configuration: BaseBranchResolver.Configuration = BaseBranchResolver.Configuration()
    ) -> BaseBranchResolver {
        BaseBranchResolver(
            transport: transport,
            tokenProvider: StaticTokenProvider("ghp_test"),
            configuration: configuration
        )
    }

    private func mine(
        _ number: Int,
        base: String,
        mergedAt: String = "2026-01-08T10:00:00Z"
    ) -> PullRequest {
        PullRequest(
            repo: "acme/billing",
            number: number,
            title: "Mine \(number)",
            headRef: "avery/mine-\(number)",
            baseRef: base,
            defaultBranch: "main",
            state: .merged,
            mergeCommit: "mine\(number)",
            createdAt: BaseBranchResolverTests.date("2026-01-07T10:00:00Z"),
            updatedAt: BaseBranchResolverTests.date(mergedAt),
            mergedAt: BaseBranchResolverTests.date(mergedAt)
        )
    }

    private static func date(_ text: String) -> Date {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: text) ?? Date(timeIntervalSince1970: 0)
    }

    /// One aliased repository per branch asked about, in the order the query aliased them.
    /// Each entry is that alias's node list, already comma-joined.
    private func page(_ aliases: [String], cost: Int = 4) -> String {
        var fields = [
            """
            "rateLimit": {
              "limit": 5000, "cost": \(cost), "remaining": 4900,
              "resetAt": "2026-01-10T13:00:00Z"
            }
            """
        ]
        for (index, nodes) in aliases.enumerated() {
            fields.append("\"b\(index)\": { \"pullRequests\": { \"nodes\": [\(nodes)] } }")
        }
        return "{ \"data\": { \(fields.joined(separator: ",\n")) } }"
    }

    private func node(
        _ number: Int,
        head: String,
        base: String,
        state: String,
        mergedAt: String? = nil,
        mergeCommit: String? = nil,
        createdAt: String = "2026-01-01T10:00:00Z"
    ) -> String {
        """
        {
          "__typename": "PullRequest",
          "number": \(number),
          "title": "Theirs \(number)",
          "url": "https://github.com/acme/billing/pull/\(number)",
          "headRefName": "\(head)",
          "baseRefName": "\(base)",
          "isDraft": false,
          "state": "\(state)",
          "createdAt": "\(createdAt)",
          "updatedAt": "2026-01-09T10:00:00Z",
          "mergedAt": \(mergedAt.map { "\"\($0)\"" } ?? "null"),
          "mergeCommit": \(mergeCommit.map { "{ \"oid\": \"\($0)\" }" } ?? "null"),
          "author": { "login": "morgan" },
          "repository": {
            "nameWithOwner": "acme/billing",
            "defaultBranchRef": { "name": "main" }
          }
        }
        """
    }

    // MARK: - The single-level cases

    /// Their pull request is still open, so nothing has shipped and nothing is lost. The
    /// row names it rather than claiming to be awaiting a release of its own.
    func testAnOpenForeignParentResolvesToPending() async throws {
        let child = mine(10, base: "morgan/feature")
        let transport = StubTransport(responses: [
            .json(page([node(99, head: "morgan/feature", base: "main", state: "OPEN")]))
        ])

        let result = try await resolver(transport).resolve([child], now: now)

        XCTAssertEqual(
            result.anchors[child.id]?.outcome,
            .pending(PRID(repo: "acme/billing", number: 99))
        )
        XCTAssertEqual(result.anchors[child.id]?.checkedAt, now)
    }

    /// Their pull request merged to trunk. What a tag has to contain is *its* merge commit —
    /// the child's own is on a branch that a squash may have rewritten away, which is the
    /// whole reason this row was stranded.
    func testAMergedForeignParentResolvesToTheCommitItPutOnTrunk() async throws {
        let child = mine(20, base: "morgan/feature")
        let transport = StubTransport(responses: [
            .json(page([node(
                99,
                head: "morgan/feature",
                base: "main",
                state: "MERGED",
                mergedAt: "2026-01-09T09:00:00Z",
                mergeCommit: "trunkoid"
            )]))
        ])

        let result = try await resolver(transport).resolve([child], now: now)

        XCTAssertEqual(
            result.anchors[child.id]?.outcome,
            .landed(
                root: PRID(repo: "acme/billing", number: 99),
                commit: "trunkoid",
                mergedAt: BaseBranchResolverTests.date("2026-01-09T09:00:00Z")
            )
        )
    }

    func testAClosedForeignParentResolvesToAbandoned() async throws {
        let child = mine(30, base: "morgan/feature")
        let transport = StubTransport(responses: [
            .json(page([node(99, head: "morgan/feature", base: "main", state: "CLOSED")]))
        ])

        let result = try await resolver(transport).resolve([child], now: now)

        XCTAssertEqual(
            result.anchors[child.id]?.outcome,
            .abandoned(PRID(repo: "acme/billing", number: 99))
        )
    }

    /// A long-lived integration branch nobody opened a pull request for. That is an answer,
    /// not a failure — and saying so is what stops the row asking forever.
    func testABranchNoPullRequestOwnsResolvesToUntracked() async throws {
        let child = mine(40, base: "develop")
        let transport = StubTransport(responses: [.json(page([""]))])

        let result = try await resolver(transport).resolve([child], now: now)

        XCTAssertEqual(result.anchors[child.id]?.outcome, .untracked(branch: "develop"))
    }

    // MARK: - Chains

    /// Several levels of somebody else's stack, resolved inside one call: each answer
    /// carries the next base branch, so a chain costs a request per level rather than a
    /// poll per level.
    func testAChainIsFollowedAcrossRoundsUntilItReachesTrunk() async throws {
        let child = mine(50, base: "morgan/leaf")
        let transport = StubTransport(responses: [
            .json(page([node(
                98,
                head: "morgan/leaf",
                base: "morgan/root",
                state: "MERGED",
                mergedAt: "2026-01-08T20:00:00Z",
                mergeCommit: "leafoid"
            )])),
            .json(page([node(
                99,
                head: "morgan/root",
                base: "main",
                state: "MERGED",
                mergedAt: "2026-01-09T09:00:00Z",
                mergeCommit: "rootoid"
            )]))
        ])

        let result = try await resolver(transport).resolve([child], now: now)

        XCTAssertEqual(transport.requests.count, 2, "one request per level, not one poll per level")
        XCTAssertEqual(
            result.anchors[child.id]?.outcome,
            .landed(
                root: PRID(repo: "acme/billing", number: 99),
                commit: "rootoid",
                mergedAt: BaseBranchResolverTests.date("2026-01-09T09:00:00Z")
            ),
            "the commit that reached trunk is the root's, not the intermediate level's"
        )
    }

    /// A stack deeper than the cap must not become an unbounded walk. The chain here never
    /// reaches trunk, so only the cap ends it.
    func testTheWalkStopsAtTheDepthCap() async throws {
        let child = mine(60, base: "morgan/l1")
        let transport = StubTransport(responses: (1...3).map { level -> HTTPResponse in
            .json(page([node(
                90 + level,
                head: "morgan/l\(level)",
                base: "morgan/l\(level + 1)",
                state: "MERGED",
                mergedAt: "2026-01-08T20:00:00Z",
                mergeCommit: "oid\(level)"
            )]))
        })

        let configuration = BaseBranchResolver.Configuration(maximumDepth: 3)
        let result = try await resolver(transport, configuration: configuration).resolve([child], now: now)

        XCTAssertEqual(transport.requests.count, 3)
        XCTAssertEqual(
            result.anchors[child.id]?.outcome,
            .unresolved(branch: "morgan/l4"),
            "an unfinished walk records that it could not answer rather than guessing at one"
        )
        XCTAssertFalse(result.anchors[child.id]?.outcome.isSettled ?? true)
    }

    // MARK: - Never turning a failure into a finding

    /// `untracked` is terminal: it moves the row to Done and stops it asking. It must only
    /// ever be written off an answer that actually came back, never off a question that was
    /// never put — a ref too long for the query to carry is enough to trigger that.
    func testABranchTheQueryCannotSpellIsUnresolvedRatherThanUntracked() async throws {
        let unspellable = String(repeating: "b", count: 300)
        let child = mine(100, base: unspellable)
        let transport = StubTransport(responses: [])

        let result = try await resolver(transport).resolve([child], now: now)

        XCTAssertEqual(result.anchors[child.id]?.outcome, .unresolved(branch: unspellable))
        XCTAssertTrue(transport.requests.isEmpty, "there was nothing it could ask")
    }

    /// A response that reported errors may have nulled a repository, and an empty answer is
    /// then indistinguishable from a branch nobody owns. Writing `untracked` off that would
    /// retire a row permanently on the strength of a failure.
    func testAnErroredResponseDoesNotProduceATerminalUntracked() async throws {
        let child = mine(110, base: "morgan/feature")
        let errored = """
        {
          "data": { "b0": null },
          "errors": [ { "message": "Could not resolve to a Repository" } ]
        }
        """
        let transport = StubTransport(responses: [.json(errored)])

        let result = try await resolver(transport).resolve([child], now: now)

        XCTAssertEqual(result.anchors[child.id]?.outcome, .unresolved(branch: "morgan/feature"))
        XCTAssertFalse(result.anchors[child.id]?.outcome.isSettled ?? true)
    }

    /// The document reports the branches it aliased, which is what keeps "never asked" apart
    /// from "asked and got nothing".
    func testTheDocumentReportsOnlyTheBranchesItCouldAskAbout() throws {
        let good = BranchKey(repo: "acme/billing", ref: "morgan/feature")
        let unspellable = BranchKey(repo: "acme/billing", ref: String(repeating: "b", count: 300))

        let document = try XCTUnwrap(BaseBranchQuery.document(for: [good, unspellable], candidates: 5))

        XCTAssertEqual(document.branches, [good])
        XCTAssertFalse(BaseBranchQuery.canSpell(unspellable))
        XCTAssertTrue(BaseBranchQuery.canSpell(good))
    }

    // MARK: - Refusing to guess

    /// Two pull requests whose lifetimes both cover the merge. The binding downstream of
    /// this is permanent, so an ambiguous branch is reported and left alone.
    func testAnAmbiguousBranchIsReportedRatherThanGuessed() async throws {
        let child = mine(70, base: "team/shared")
        let both = [
            node(98, head: "team/shared", base: "main", state: "OPEN"),
            node(99, head: "team/shared", base: "main", state: "OPEN")
        ].joined(separator: ",")
        let transport = StubTransport(responses: [.json(page([both]))])

        let result = try await resolver(transport).resolve([child], now: now)

        XCTAssertEqual(
            result.anchors[child.id]?.outcome,
            .unresolved(branch: "team/shared"),
            "recorded rather than dropped, so the backoff applies — but never as a terminal answer"
        )
        XCTAssertFalse(
            result.anchors[child.id]?.outcome.isSettled ?? true,
            "an ambiguous branch is a failure to answer, not a finding"
        )
        XCTAssertEqual(
            result.warnings,
            [.baseBranchAmbiguous(repository: "acme/billing", branch: "team/shared")]
        )
    }

    /// A candidate that was created after the merge cannot be the pull request it went
    /// into — the reused-branch-name case, which would otherwise bind the row to a release
    /// months on the wrong side of it.
    func testACandidateCreatedAfterTheMergeIsNotAClaim() async throws {
        let child = mine(80, base: "team/integration", mergedAt: "2026-01-08T10:00:00Z")
        let transport = StubTransport(responses: [.json(page([node(
            99,
            head: "team/integration",
            base: "main",
            state: "OPEN",
            createdAt: "2026-02-01T10:00:00Z"
        )]))])

        let result = try await resolver(transport).resolve([child], now: now)

        XCTAssertEqual(
            result.anchors[child.id]?.outcome,
            .untracked(branch: "team/integration"),
            "nothing that could have taken this merge owns the branch"
        )
    }

    // MARK: - The query

    func testTheQueryAsksByHeadBranchRatherThanSearching() throws {
        let text = try XCTUnwrap(
            BaseBranchQuery.text(
                for: [BranchKey(repo: "acme/billing", ref: "morgan/feature")],
                candidates: 5
            )
        )

        XCTAssertTrue(text.contains("repository(owner: \"acme\", name: \"billing\")"))
        XCTAssertTrue(text.contains("headRefName: \"morgan/feature\""))
        XCTAssertFalse(
            text.contains("search("),
            "a search would be author-scoped and would lag the merge by up to a minute"
        )
    }

    /// A branch name is not validated the way a repository name is — a ref may contain a
    /// quote or a backslash — so it is escaped rather than trusted.
    func testABranchNameIsEscapedIntoTheDocument() throws {
        XCTAssertEqual(BaseBranchQuery.escaped("plain"), "\"plain\"")
        XCTAssertEqual(BaseBranchQuery.escaped("has\"quote"), "\"has\\\"quote\"")
        XCTAssertEqual(BaseBranchQuery.escaped("has\\backslash"), "\"has\\\\backslash\"")
        XCTAssertNil(BaseBranchQuery.escaped(""))
        XCTAssertNil(BaseBranchQuery.escaped("has\nnewline"))
    }

    /// Which branches a round asks about must not depend on dictionary iteration, or two
    /// polls over the same state would spend the allowance on different chains.
    func testTheBranchesAskedAboutAreDeterministic() {
        let keys = [
            BranchKey(repo: "acme/billing", ref: "z"),
            BranchKey(repo: "acme/billing", ref: "a"),
            BranchKey(repo: "acme/api", ref: "m"),
            BranchKey(repo: "acme/billing", ref: "a")
        ]

        let first = BaseBranchResolver.distinctBranches(of: keys, limit: 2)
        let second = BaseBranchResolver.distinctBranches(of: Array(keys.reversed()), limit: 2)

        XCTAssertEqual(first, second)
        XCTAssertEqual(
            first,
            [BranchKey(repo: "acme/api", ref: "m"), BranchKey(repo: "acme/billing", ref: "a")]
        )
    }

    // MARK: - Failure

    /// One unreachable repository is not the poll's problem. An expired token is.
    func testATransportFailureIsAWarningRatherThanAThrow() async throws {
        let child = mine(90, base: "morgan/feature")
        let transport = StubTransport(responses: [.json("{}", status: 500)])

        let result = try await resolver(transport).resolve([child], now: now)

        XCTAssertTrue(result.anchors.isEmpty)
        XCTAssertFalse(result.warnings.isEmpty)
    }

    func testAnExpiredTokenEndsThePoll() async {
        let child = mine(91, base: "morgan/feature")
        let transport = StubTransport(responses: [.json("{}", status: 401)])

        do {
            _ = try await resolver(transport).resolve([child], now: now)
            XCTFail("an expired credential has to end the poll rather than become a warning")
        } catch let error as GitHubError {
            XCTAssertTrue(error.isAuthenticationFailure)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    /// Nothing to follow is not a request.
    func testNoInputMakesNoRequest() async throws {
        let transport = StubTransport(responses: [])
        let result = try await resolver(transport).resolve([], now: now)

        XCTAssertTrue(result.isEmpty)
        XCTAssertTrue(transport.requests.isEmpty)
    }
}
