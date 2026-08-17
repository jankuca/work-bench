import Foundation
import NetKit
import PRStackCore
import XCTest
@testable import GitHubKit

final class PullRequestFetchTests: XCTestCase {
    /// `retryDelay` is zero throughout: the sleep between attempts exists so a poll does not
    /// hammer a service that just failed, and there is no service and no scheduler here to be
    /// considerate of — a test that waited three quarters of a second per 502 would only be
    /// asserting that `Task.sleep` works.
    private func client(
        _ transport: StubTransport,
        pageSize: Int = 50,
        pageCap: Int = 10,
        pointBudget: Int = PointBudget.defaultPoints,
        pageRetries: Int = 3
    ) -> GitHubClient {
        GitHubClient(
            transport: transport,
            tokenProvider: StaticTokenProvider("ghp_test"),
            configuration: GitHubClient.Configuration(
                pageSize: pageSize,
                pageCap: pageCap,
                pointBudget: pointBudget,
                pageRetries: pageRetries,
                retryDelay: 0
            )
        )
    }

    // MARK: - Pagination

    /// Not optional in either scope: `all` would otherwise silently drop everything past
    /// the 50th pull request, and `selected` would drop repositories whose pull requests
    /// happen to sort onto a later page.
    func testPaginatesToCompletionAndCarriesTheCursorForward() async throws {
        let transport = StubTransport(responses: [
            .json(SearchPage.json(numbers: [4012, 4011], hasNextPage: true, endCursor: "c1")),
            .json(SearchPage.json(numbers: [4010, 4009], hasNextPage: true, endCursor: "c2")),
            .json(SearchPage.json(numbers: [4008], hasNextPage: false, endCursor: "c3"))
        ])

        let fetch = try await client(transport, pageSize: 2).fetchPullRequests(scope: .all)

        XCTAssertEqual(fetch.pullRequests.map(\.number), [4012, 4011, 4010, 4009, 4008])
        XCTAssertEqual(fetch.pagesFetched, 3)
        XCTAssertEqual(fetch.stopReason, .complete)
        XCTAssertNil(fetch.nextCursor)
        XCTAssertEqual(fetch.viewerLogin, "avery")

        // The first request opens with no cursor, and each later one resumes from the
        // previous page's `endCursor`.
        XCTAssertEqual(transport.requests.count, 3)
        XCTAssertNil(try transport.requestVariables(0)["cursor"] as? String)
        XCTAssertEqual(try transport.requestVariables(1)["cursor"] as? String, "c1")
        XCTAssertEqual(try transport.requestVariables(2)["cursor"] as? String, "c2")
        XCTAssertEqual(try transport.requestVariables(0)["pageSize"] as? Int, 2)
        XCTAssertEqual(
            try transport.requestVariables(0)["query"] as? String,
            "is:pr author:@me -is:draft"
        )
    }

    /// `hasNextPage` with no cursor would page against the same `after` forever.
    func testHasNextPageWithoutACursorStopsRatherThanLooping() async throws {
        let transport = StubTransport(responses: [
            .json(SearchPage.json(numbers: [4012], hasNextPage: true, endCursor: nil))
        ])
        let fetch = try await client(transport).fetchPullRequests(scope: .all)
        XCTAssertEqual(fetch.pagesFetched, 1)
        XCTAssertEqual(fetch.stopReason, .complete)
        XCTAssertEqual(transport.requests.count, 1)
    }

    func testResumesFromASuppliedCursor() async throws {
        let transport = StubTransport(responses: [
            .json(SearchPage.json(numbers: [4008], hasNextPage: false, endCursor: nil))
        ])
        _ = try await client(transport).fetchPullRequests(scope: .all, startingAfter: "c2")
        XCTAssertEqual(try transport.requestVariables(0)["cursor"] as? String, "c2")
    }

    /// The search index shifts between pages, which repeats a node on the boundary. The
    /// result has to be the same whether or not that happened.
    func testRepeatedNodesAcrossPagesAreCollapsed() async throws {
        let transport = StubTransport(responses: [
            .json(SearchPage.json(numbers: [4012, 4011], hasNextPage: true, endCursor: "c1")),
            .json(SearchPage.json(numbers: [4011, 4010], hasNextPage: false, endCursor: nil))
        ])
        let fetch = try await client(transport, pageSize: 2).fetchPullRequests(scope: .all)
        XCTAssertEqual(fetch.pullRequests.map(\.number), [4012, 4011, 4010])
    }

    /// Same number, different repository — the repository is part of the identity
    /// everywhere it matters, so these are two rows, not a duplicate.
    func testSameNumberInDifferentRepositoriesAreDistinct() async throws {
        let transport = StubTransport(responses: [
            .json(SearchPage.json(repo: "acme/billing", numbers: [77], hasNextPage: true, endCursor: "c1")),
            .json(SearchPage.json(repo: "acme/source", numbers: [77], hasNextPage: false, endCursor: nil))
        ])
        let fetch = try await client(transport, pageSize: 1).fetchPullRequests(scope: .all)
        XCTAssertEqual(fetch.pullRequests.map(\.id.rawValue), ["acme/billing#77", "acme/source#77"])
    }

    // MARK: - Bounds

    func testStopsAtThePageCapAndSaysSo() async throws {
        let transport = StubTransport.always(
            .json(SearchPage.json(numbers: [4012], hasNextPage: true, endCursor: "c"))
        )
        let fetch = try await client(transport, pageSize: 1, pageCap: 3).fetchPullRequests(scope: .all)

        XCTAssertEqual(fetch.pagesFetched, 3)
        XCTAssertEqual(fetch.stopReason, .pageCap)
        // Hitting the cap surfaces a warning rather than truncating silently, and the
        // cursor comes back so the next poll can resume.
        XCTAssertEqual(fetch.nextCursor, "c")
        XCTAssertTrue(fetch.warnings.contains { if case .pageCapReached = $0 { return true } else { return false } })
    }

    func testStopsWhenThePointBudgetIsSpent() async throws {
        let transport = StubTransport.always(
            .json(SearchPage.json(numbers: [4012], hasNextPage: true, endCursor: "c", cost: 40))
        )
        let fetch = try await client(transport, pageSize: 1, pointBudget: 100)
            .fetchPullRequests(scope: .all)

        // Three pages at 40 points each: the third crosses 100 and stops the fourth.
        XCTAssertEqual(fetch.pagesFetched, 3)
        XCTAssertEqual(fetch.pointsSpent, 120)
        XCTAssertEqual(fetch.stopReason, .pointBudget)
        XCTAssertEqual(fetch.nextCursor, "c")
    }

    /// Backing off on the *measured* remaining points, before exhaustion, is what avoids
    /// being hard-blocked mid-poll and showing a disconnected icon for the rest of the hour.
    func testStopsWhenGitHubsAllowanceFallsBelowTheFloor() async throws {
        let transport = StubTransport(responses: [
            .json(SearchPage.json(numbers: [4012], hasNextPage: true, endCursor: "c1", remaining: 4_000)),
            .json(SearchPage.json(numbers: [4011], hasNextPage: true, endCursor: "c2", remaining: 400)),
            .json(SearchPage.json(numbers: [4010], hasNextPage: false, endCursor: nil))
        ])
        let fetch = try await client(transport, pageSize: 1).fetchPullRequests(scope: .all)

        XCTAssertEqual(fetch.pagesFetched, 2)
        XCTAssertEqual(fetch.stopReason, .rateLimitFloor)
        XCTAssertEqual(fetch.nextCursor, "c2")
        XCTAssertEqual(fetch.rateLimit?.remaining, 400)
        XCTAssertEqual(transport.remainingSteps, 1, "the third page should never have been requested")
    }

    /// Every bound is checked after the page is banked, so it stops the *next* request
    /// rather than discarding work already paid for.
    func testABoundNeverDiscardsThePageThatTrippedIt() async throws {
        let transport = StubTransport(responses: [
            .json(SearchPage.json(numbers: [4012, 4011], hasNextPage: true, endCursor: "c1", remaining: 10))
        ])
        let fetch = try await client(transport, pageSize: 2).fetchPullRequests(scope: .all)
        XCTAssertEqual(fetch.pullRequests.map(\.number), [4012, 4011])
        XCTAssertEqual(fetch.stopReason, .rateLimitFloor)
    }

    // MARK: - Scope

    func testSelectedScopeSendsOneRequestWithEveryRepositoryQualifier() async throws {
        let transport = StubTransport(responses: [
            .json(SearchPage.json(numbers: [4012], hasNextPage: false, endCursor: nil))
        ])
        _ = try await client(transport).fetchPullRequests(
            scope: .selected(["acme/billing", "acme/source"])
        )
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(
            try transport.requestVariables(0)["query"] as? String,
            "is:pr author:@me -is:draft repo:acme/billing repo:acme/source"
        )
    }

    /// Unchecking every repository must not widen back to the `all` query.
    func testEmptySelectionMakesNoRequestAtAll() async throws {
        let transport = StubTransport(responses: [])
        let fetch = try await client(transport).fetchPullRequests(scope: .selected([]))

        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertEqual(fetch.stopReason, .emptyScope)
        XCTAssertTrue(fetch.pullRequests.isEmpty)
        XCTAssertEqual(fetch.pagesFetched, 0)
    }

    func testAScopeOfOnlyMalformedRepositoriesReportsWhatItDropped() async throws {
        let transport = StubTransport(responses: [])
        let fetch = try await client(transport).fetchPullRequests(scope: .selected(["acme"]))

        XCTAssertTrue(transport.requests.isEmpty)
        XCTAssertEqual(fetch.stopReason, .emptyScope)
        XCTAssertEqual(fetch.warnings, [.repositoryDropped("acme")])
    }

    func testExtraQualifiersReachTheQuery() async throws {
        let transport = StubTransport(responses: [
            .json(SearchPage.json(numbers: [4012], hasNextPage: false, endCursor: nil))
        ])
        _ = try await client(transport).fetchPullRequests(scope: .all, extraQualifiers: ["is:open"])
        XCTAssertEqual(
            try transport.requestVariables(0)["query"] as? String,
            "is:pr author:@me -is:draft is:open"
        )
    }

    func testDraftPreferenceReachesTheQuery() async throws {
        let transport = StubTransport(responses: [
            .json(SearchPage.json(numbers: [4012], hasNextPage: false, endCursor: nil))
        ])
        _ = try await client(transport).fetchPullRequests(scope: .all, includesDrafts: true)
        XCTAssertEqual(
            try transport.requestVariables(0)["query"] as? String,
            "is:pr author:@me"
        )
    }

    // MARK: - Pages GitHub will not answer

    /// A `502` is GitHub's resolver running out of time, and the size of the page is what it
    /// ran out of time on: 50 pull requests, each with its reviews, its review requests and
    /// 20 check contexts. So the same window is asked for again at half the size rather than
    /// the whole poll being lost to it.
    func testAServerErrorRetriesTheSamePageAtHalfTheSize() async throws {
        let transport = StubTransport([
            .respond(.json(SearchPage.json(numbers: [4012, 4011], hasNextPage: true, endCursor: "c1"))),
            .respond(.json(#"{"message":"Server Error"}"#, status: 502)),
            .respond(.json(SearchPage.json(numbers: [4010], hasNextPage: false, endCursor: nil)))
        ])

        let fetch = try await client(transport, pageSize: 20).fetchPullRequests(scope: .all)

        XCTAssertEqual(fetch.pullRequests.map(\.number), [4012, 4011, 4010])
        XCTAssertEqual(fetch.stopReason, .complete)
        // Two banked pages, three requests: the failure is not a page.
        XCTAssertEqual(fetch.pagesFetched, 2)
        XCTAssertEqual(transport.requests.count, 3)

        // The retry asks the same question, smaller — same cursor, half the nodes — and the
        // reduction sticks for the pages after it.
        XCTAssertEqual(try transport.requestVariables(1)["cursor"] as? String, "c1")
        XCTAssertEqual(try transport.requestVariables(2)["cursor"] as? String, "c1")
        XCTAssertEqual(try transport.requestVariables(0)["pageSize"] as? Int, 20)
        XCTAssertEqual(try transport.requestVariables(1)["pageSize"] as? Int, 20)
        XCTAssertEqual(try transport.requestVariables(2)["pageSize"] as? Int, 10)
        XCTAssertTrue(
            fetch.warnings.contains { if case .pageRetried = $0 { return true } else { return false } },
            "a page that had to be asked for twice is worth a line in the footer"
        )
    }

    /// The reduction stops at a floor, and a page GitHub will not answer at any size stops
    /// pagination — with everything before it kept. That is the whole point: a sweep of eight
    /// pages that fails on the seventh used to throw the first six away.
    func testAPageThatNeverAnswersKeepsWhatWasAlreadyFetched() async throws {
        let transport = StubTransport([
            .respond(.json(SearchPage.json(numbers: [4012], hasNextPage: true, endCursor: "c1"))),
            .respond(.json(#"{"message":"Server Error"}"#, status: 504)),
            .respond(.json(#"{"message":"Server Error"}"#, status: 504))
        ])

        let fetch = try await client(transport, pageSize: 1, pageRetries: 1)
            .fetchPullRequests(scope: .all)

        XCTAssertEqual(fetch.pullRequests.map(\.number), [4012])
        XCTAssertEqual(fetch.pagesFetched, 1)
        XCTAssertEqual(fetch.stopReason, .serverError)
        XCTAssertFalse(fetch.stopReason.isComplete)
        // The cursor is the page that failed, so the next poll resumes there rather than
        // walking the pages before it again.
        XCTAssertEqual(fetch.nextCursor, "c1")
        XCTAssertTrue(
            fetch.warnings.contains { if case .searchInterrupted = $0 { return true } else { return false } }
        )
    }

    /// The one case that has to stay an error. Nothing was fetched, so answering with an empty
    /// success would put the panel at "connected, nothing waiting on you" for a GitHub that is
    /// not answering at all.
    func testAFirstPageThatNeverAnswersIsAFailure() async throws {
        let transport = StubTransport([
            .respond(.json(#"{"message":"Server Error"}"#, status: 502)),
            .respond(.json(#"{"message":"Server Error"}"#, status: 502))
        ])

        do {
            _ = try await client(transport, pageRetries: 1).fetchPullRequests(scope: .all)
            XCTFail("a sweep that fetched nothing at all must not report success")
        } catch {
            XCTAssertEqual(error as? GitHubError, GitHubError.http(status: 502, message: "Server Error"))
        }
    }

    /// A rejected token is not a page that was too big, and retrying it at half the size
    /// would spend a poor connection's time on a request that cannot start working.
    func testAnAuthenticationFailureIsNotRetried() async throws {
        let transport = StubTransport(responses: [.json(#"{"message":"Bad credentials"}"#, status: 401)])

        do {
            _ = try await client(transport).fetchPullRequests(scope: .all)
            XCTFail("401 is an answer, not a failure to answer")
        } catch {
            XCTAssertEqual(error as? GitHubError, GitHubError.unauthorized("Bad credentials"))
        }
        XCTAssertEqual(transport.requests.count, 1)
    }

    /// A partly-spent budget handed in is what makes a poll's searches share one allowance
    /// instead of each starting again at the full one.
    func testASharedBudgetCarriesWhatEarlierSearchesSpent() async throws {
        let transport = StubTransport.always(
            .json(SearchPage.json(numbers: [4012], hasNextPage: true, endCursor: "c", cost: 40))
        )
        var spent = PointBudget(points: 100)
        spent.record(80)

        let fetch = try await client(transport, pageSize: 1, pointBudget: 100)
            .fetchPullRequests(scope: .all, budget: spent)

        // One page, not three: 80 points were already gone before this search started.
        XCTAssertEqual(fetch.pagesFetched, 1)
        XCTAssertEqual(fetch.stopReason, .pointBudget)
        // And it reports what *it* spent, not what the poll has spent, or the caller summing
        // the searches would count the earlier ones twice.
        XCTAssertEqual(fetch.pointsSpent, 40)
    }

    // MARK: - Handing off to derivation

    func testTheFetchBecomesASnapshotDerivationCanRead() async throws {
        let transport = StubTransport(responses: [
            .json(SearchPage.json(numbers: [4012, 4011], hasNextPage: false, endCursor: nil))
        ])
        let fetch = try await client(transport).fetchPullRequests(scope: .all)

        let model = Derivation.derive(
            snapshot: fetch.snapshot,
            local: .empty,
            now: Date(timeIntervalSince1970: 1_767_000_000)
        )
        XCTAssertEqual(model.rows.map(\.id.rawValue), ["acme/billing#4012", "acme/billing#4011"])
        XCTAssertEqual(model.summary.openCount, 2)
        XCTAssertFalse(model.showsRepoNames, "one repository in the list, so no repo names")
    }

    /// GraphQL nulls a field whose resolver failed and explains why in `errors`. A DTO
    /// that required `search` would turn that into a decode failure and throw GitHub's own
    /// explanation away.
    func testANullSearchConnectionKeepsGitHubsErrors() async throws {
        let transport = StubTransport(responses: [
            .json(
                """
                {"data":{"search":null},
                 "errors":[{"type":"FORBIDDEN","message":"Resource not accessible"}]}
                """
            )
        ])
        let fetch = try await client(transport).fetchPullRequests(scope: .all)

        XCTAssertTrue(fetch.pullRequests.isEmpty)
        XCTAssertEqual(fetch.stopReason, .complete)
        XCTAssertNil(fetch.nextCursor)
        XCTAssertEqual(
            fetch.warnings,
            [.graphQL(GraphQLError(message: "Resource not accessible", type: "FORBIDDEN"))]
        )
    }

    /// One inaccessible repository does not invalidate the page; the error becomes a
    /// warning the footer can show.
    func testGraphQLErrorsAlongsideDataBecomeWarnings() async throws {
        let page = SearchPage.json(
            numbers: [4012],
            hasNextPage: false,
            endCursor: nil,
            errors: #"[{ "type": "FORBIDDEN", "message": "no access" }]"#
        )
        let transport = StubTransport(responses: [.json(page)])
        let fetch = try await client(transport).fetchPullRequests(scope: .all)

        XCTAssertEqual(fetch.pullRequests.count, 1)
        XCTAssertEqual(
            fetch.warnings,
            [.graphQL(GraphQLError(message: "no access", type: "FORBIDDEN"))]
        )
    }
}
