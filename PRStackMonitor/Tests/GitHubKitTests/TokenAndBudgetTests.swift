import Foundation
import NetKit
import XCTest
@testable import GitHubKit

/// The generic credential providers are `NetKit`'s and are tested there. What belongs
/// here is the GitHub-specific part: which variables are read, in which order.
final class GitHubTokenTests: XCTestCase {
    func testEnvironmentProviderPrefersTheProjectSpecificName() throws {
        let provider = EnvironmentTokenProvider.github(
            environment: ["PRSTACK_GITHUB_TOKEN": "project", "GITHUB_TOKEN": "generic"]
        )
        XCTAssertEqual(try provider.token(), "project")
    }

    func testEnvironmentProviderFallsThroughEmptyValues() throws {
        let provider = EnvironmentTokenProvider.github(
            environment: ["PRSTACK_GITHUB_TOKEN": "  ", "GITHUB_TOKEN": "generic\n"]
        )
        XCTAssertEqual(try provider.token(), "generic")
    }

    /// The one place `MissingCredential` becomes `GitHubError.missingToken`. That
    /// translation is what the panel's connect prompt keys off, so it is worth pinning
    /// rather than trusting: a raw `MissingCredential` reaching `GitHubPanelSource` falls
    /// through to `.unreachable` and shows a network failure for an unconfigured app.
    func testAnAbsentTokenBecomesMissingTokenAtTheClientBoundary() async {
        let client = GitHubClient(
            transport: StubTransport([]),
            tokenProvider: EnvironmentTokenProvider.github(environment: [:])
        )
        do {
            _ = try await client.fetchPullRequests(scope: .all)
            XCTFail("expected the fetch to fail with no token configured")
        } catch {
            XCTAssertEqual(error as? GitHubError, GitHubError.missingToken)
        }
    }
}

final class RateLimitTests: XCTestCase {
    func testFloorIsTenPercentOfTheReportedAllowance() {
        XCTAssertFalse(RateLimit(limit: 5_000, cost: 10, remaining: 500).isBelowFloor)
        XCTAssertTrue(RateLimit(limit: 5_000, cost: 10, remaining: 499).isBelowFloor)
        // A token type with a different allowance is measured against its own.
        XCTAssertTrue(RateLimit(limit: 1_000, cost: 10, remaining: 99).isBelowFloor)
        XCTAssertFalse(RateLimit(limit: 1_000, cost: 10, remaining: 100).isBelowFloor)
    }

    func testAnAbsentLimitFallsBackToTheDocumentedHourlyAllowance() {
        XCTAssertTrue(RateLimit(limit: 0, cost: 10, remaining: 100).isBelowFloor)
        XCTAssertFalse(RateLimit(limit: 0, cost: 10, remaining: 600).isBelowFloor)
    }

    func testBudgetIsSpentNotEstimated() {
        var budget = PointBudget(points: 100)
        XCTAssertFalse(budget.isExhausted)
        budget.record(60)
        XCTAssertEqual(budget.remaining, 40)
        budget.record(60)
        XCTAssertTrue(budget.isExhausted)
        XCTAssertEqual(budget.spent, 120)
        XCTAssertEqual(budget.remaining, 0)
    }

    /// A budget of zero would stop the loop before its first page and leave the panel
    /// permanently empty — a worse failure than ignoring the setting.
    func testANonPositiveBudgetStillAllowsAPage() {
        XCTAssertFalse(PointBudget(points: 0).isExhausted)
        XCTAssertFalse(PointBudget(points: -5).isExhausted)
    }

    func testRESTHeadersParseAndAreAbsentWhenTheyShouldBe() {
        XCTAssertNil(RESTRateLimit.from(HTTPResponse(status: 200)))
        let response = HTTPResponse(
            status: 200,
            headers: ["X-RateLimit-Remaining": "10", "X-RateLimit-Limit": "5000"]
        )
        XCTAssertEqual(RESTRateLimit.from(response)?.remaining, 10)
        XCTAssertEqual(RESTRateLimit.from(response)?.isBelowFloor, true)
    }
}
