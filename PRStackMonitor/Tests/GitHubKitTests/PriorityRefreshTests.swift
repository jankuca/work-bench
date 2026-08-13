import Foundation
import NetKit
import PRStackCore
import XCTest
@testable import GitHubKit

/// The refresh that runs ahead of a poll's searches: one request for the rows the panel is
/// already showing.
final class PriorityRefreshTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-01-20T12:00:00Z")!
    private let endpoint = URL(string: "https://api.github.test/graphql")!

    private func refresher(_ transport: StubTransport, batchLimit: Int = 50) -> PriorityRefresh {
        PriorityRefresh(
            transport: transport,
            tokenProvider: StaticTokenProvider("ghp_test"),
            configuration: PriorityRefresh.Configuration(batchLimit: batchLimit, endpoint: endpoint)
        )
    }

    private func id(_ number: Int, repo: String = "acme/billing") -> PRID {
        PRID(repo: repo, number: number)
    }

    /// The closed search's lower bound for a poll with nothing waiting on a tag — the same
    /// value the sweep computes, which is the point of passing it in rather than inventing
    /// a window here.
    private var window: Date {
        MergedPullRequestSearch.lowerBound(unbound: [:], now: now)
    }

    private func query(_ transport: StubTransport, _ index: Int) throws -> String {
        try XCTUnwrap(transport.requestBody(index)["query"] as? String)
    }

    // MARK: - The request

    /// The whole list in one request, and no pagination: a second round trip would spend
    /// the latency this exists to save.
    func testTheWholeListGoesOutInOneRequest() async throws {
        let transport = StubTransport(responses: [.json(KnownPage.json(numbers: [10, 11]))])

        let result = try await refresher(transport).refresh(
            [id(10), id(11)],
            scope: .all,
            includesDrafts: false,
            closedSince: window
        )

        XCTAssertEqual(transport.requests.count, 1)
        let text = try query(transport, 0)
        XCTAssertTrue(text.contains("repository(owner: \"acme\", name: \"billing\")"))
        XCTAssertTrue(text.contains("pullRequest(number: 10)"))
        XCTAssertTrue(text.contains("pullRequest(number: 11)"))
        // The same field set the search selects, or a row would redraw differently
        // depending on which query produced it.
        XCTAssertTrue(text.contains("fragment PullRequestFields on PullRequest"))
        XCTAssertTrue(text.contains("...PullRequestFields"))

        XCTAssertEqual(result.pullRequests.map(\.number), [10, 11])
        XCTAssertEqual(result.viewerLogin, "avery")
        XCTAssertEqual(result.pointsSpent, 8)
        XCTAssertEqual(result.rateLimit?.remaining, 4_900)
    }

    /// The aliases come back in a dictionary. Ordering the answer by the *request* is what
    /// keeps a poll from reshuffling the panel for nothing.
    func testTheAnswerIsOrderedByTheRequestRatherThanTheResponse() async throws {
        let transport = StubTransport(responses: [.json(KnownPage.json(numbers: [11, 10]))])

        let result = try await refresher(transport).refresh(
            [id(10), id(11)],
            scope: .all,
            includesDrafts: false,
            closedSince: window
        )

        XCTAssertEqual(result.pullRequests.map(\.number), [10, 11])
    }

    /// A repository the token cannot see, and a pull request that has been deleted, both
    /// answer null. Neither is a failure — the searches will say so a moment later.
    func testANullAliasIsSkippedRatherThanFailingTheRefresh() async throws {
        let transport = StubTransport(responses: [.json(KnownPage.json(numbers: [10, nil]))])

        let result = try await refresher(transport).refresh(
            [id(10), id(12)],
            scope: .all,
            includesDrafts: false,
            closedSince: window
        )

        XCTAssertEqual(result.requested.map(\.number), [10, 12])
        XCTAssertEqual(result.pullRequests.map(\.number), [10])
    }

    /// Asking by id bypasses every qualifier the searches carry, so the answer is put back
    /// through the same bounds. A pull request that has become a draft is one the panel is
    /// not showing while the preference is off.
    func testADraftIsDroppedUnlessTheSettingIsOn() async throws {
        let hidden = StubTransport(responses: [.json(KnownPage.json(numbers: [10], isDraft: true))])
        let shown = StubTransport(responses: [.json(KnownPage.json(numbers: [10], isDraft: true))])

        let withoutDrafts = try await refresher(hidden).refresh(
            [id(10)],
            scope: .all,
            includesDrafts: false,
            closedSince: window
        )
        let withDrafts = try await refresher(shown).refresh(
            [id(10)],
            scope: .all,
            includesDrafts: true,
            closedSince: window
        )

        XCTAssertEqual(withoutDrafts.pullRequests, [])
        XCTAssertEqual(withDrafts.pullRequests.map(\.number), [10])
    }

    /// The other bound: a pull request closed before the merged search reaches back is
    /// outside both searches, and drawing it would make the refresh disagree with the sweep
    /// that lands seconds later.
    func testAPullRequestClosedBeforeTheWindowIsDropped() async throws {
        let old = StubTransport(responses: [
            .json(KnownPage.json(numbers: [10], state: "CLOSED", updatedAt: "2025-11-01T08:00:00Z"))
        ])
        let recent = StubTransport(responses: [
            .json(KnownPage.json(numbers: [10], state: "CLOSED", updatedAt: "2026-01-19T08:00:00Z"))
        ])

        let dropped = try await refresher(old).refresh(
            [id(10)],
            scope: .all,
            includesDrafts: false,
            closedSince: window
        )
        let kept = try await refresher(recent).refresh(
            [id(10)],
            scope: .all,
            includesDrafts: false,
            closedSince: window
        )

        XCTAssertEqual(dropped.pullRequests, [])
        XCTAssertEqual(kept.pullRequests.map(\.number), [10])
    }

    /// A repository the user has unchecked in Settings is not asked about at all. Asking
    /// would spend points on a row the sweep is not going to return.
    func testARepositoryOutsideTheScopeIsNeverAskedFor() async throws {
        let transport = StubTransport(responses: [])

        let result = try await refresher(transport).refresh(
            [id(10)],
            scope: .selected(["acme/web"]),
            includesDrafts: false,
            closedSince: window
        )

        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertEqual(result, .empty)
    }

    /// One request means a bounded one. The list is cut from the end, so the rows nearest
    /// the top of the panel are the ones that survive.
    func testTheBatchLimitCapsTheRequest() async throws {
        let transport = StubTransport(responses: [.json(KnownPage.json(numbers: [10, 11]))])

        let result = try await refresher(transport, batchLimit: 2).refresh(
            [id(10), id(11), id(12)],
            scope: .all,
            includesDrafts: false,
            closedSince: window
        )

        XCTAssertEqual(result.requested.map(\.number), [10, 11])
        XCTAssertFalse(try query(transport, 0).contains("pullRequest(number: 12)"))
    }

    /// Which ids are worth asking for, without a network in the way: the order is the
    /// caller's and is preserved, duplicates go, and so does anything that cannot be
    /// spelled into the query.
    func testCandidatesKeepTheCallersOrderAndDropTheRest() {
        let candidates = PriorityRefresh.candidates(
            [id(12), id(11), id(12), id(10, repo: "acme/web")],
            scope: .selected(["acme/billing"])
        )

        XCTAssertEqual(candidates, [id(12), id(11)])
    }

    // MARK: - Failure

    /// The refresh is an optimisation over a sweep that is about to run anyway, so a
    /// failure that is not about the connection is a warning and the poll carries on.
    func testAFailureIsAWarningRatherThanAnError() async throws {
        let transport = StubTransport(responses: [.json("{\"message\":\"boom\"}", status: 500)])

        let result = try await refresher(transport).refresh(
            [id(10)],
            scope: .all,
            includesDrafts: false,
            closedSince: window
        )

        XCTAssertEqual(result.pullRequests, [])
        XCTAssertEqual(result.warnings.count, 1)
        XCTAssertEqual(
            result.warnings.first?.description.contains("could not refresh the rows"),
            true
        )
    }

    /// The two that are about the connection are not swallowed: a rejected token has to
    /// reach the panel as a rejected token, from whichever request first saw it.
    func testARejectedTokenEndsThePoll() async throws {
        let transport = StubTransport(responses: [.json("{\"message\":\"Bad credentials\"}", status: 401)])

        do {
            _ = try await refresher(transport).refresh(
                [id(10)],
                scope: .all,
                includesDrafts: false,
                closedSince: window
            )
            XCTFail("a rejected token must end the poll rather than becoming a warning")
        } catch let error as GitHubError {
            XCTAssertTrue(error.isAuthenticationFailure)
        }
    }

    // MARK: - Feeding the sweep

    private func client(_ transport: StubTransport) -> GitHubClient {
        GitHubClient(
            transport: transport,
            tokenProvider: StaticTokenProvider("ghp_test"),
            configuration: GitHubClient.Configuration(endpoint: endpoint)
        )
    }

    private func pullRequest(_ number: Int, title: String) -> PullRequest {
        PullRequest(
            repo: "acme/billing",
            number: number,
            title: title,
            headRef: "avery/branch-\(number)",
            baseRef: "main",
            updatedAt: now
        )
    }

    /// A search that stopped at the page cap comes back missing rows that are on screen
    /// right now. Replacing the panel with it would make them vanish for no reason the user
    /// can see, so the refresh's copy is kept until a sweep that reaches them says
    /// otherwise.
    func testARefreshedRowTheSearchesDidNotReturnSurvivesTheSweep() async throws {
        let transport = StubTransport(responses: [
            .json(SearchPage.json(numbers: [10], hasNextPage: false, endCursor: nil)),
            .json(SearchPage.json(numbers: [], hasNextPage: false, endCursor: nil))
        ])

        let result = try await GitHubPoll(client: client(transport)).run(
            scope: .all,
            local: .empty,
            refreshed: KnownPullRequestFetch(pullRequests: [pullRequest(99, title: "Beyond the page cap")]),
            now: now
        )

        XCTAssertEqual(result.pullRequests.map(\.number), [10, 99])
    }

    /// And where both have the row, the search wins: it ran second, so it is the newer of
    /// the two answers.
    func testTheSearchWinsOverTheRefreshForTheSameRow() async throws {
        let transport = StubTransport(responses: [
            .json(SearchPage.json(numbers: [10], hasNextPage: false, endCursor: nil)),
            .json(SearchPage.json(numbers: [], hasNextPage: false, endCursor: nil))
        ])

        let result = try await GitHubPoll(client: client(transport)).run(
            scope: .all,
            local: .empty,
            refreshed: KnownPullRequestFetch(pullRequests: [pullRequest(10, title: "One poll older")]),
            now: now
        )

        XCTAssertEqual(result.pullRequests.count, 1)
        XCTAssertEqual(result.pullRequests.first?.title, "Pull request 10")
    }

    /// Without a refresher a poll is exactly the poll it was before any of this existed.
    func testAPollWithoutARefresherAsksForNothingExtra() async throws {
        let transport = StubTransport(responses: [
            .json(SearchPage.json(numbers: [10], hasNextPage: false, endCursor: nil)),
            .json(SearchPage.json(numbers: [], hasNextPage: false, endCursor: nil))
        ])
        let poll = GitHubPoll(client: client(transport))

        let refreshed = try await poll.refreshKnown([id(10)], scope: .all, local: .empty, now: now)
        let result = try await poll.run(scope: .all, local: .empty, refreshed: refreshed, now: now)

        XCTAssertEqual(refreshed, .empty)
        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertEqual(result.pullRequests.map(\.number), [10])
    }
}
