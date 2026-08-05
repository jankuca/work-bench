import Foundation
import XCTest
@testable import GitHubKit

final class TokenProviderTests: XCTestCase {
    func testEnvironmentProviderPrefersTheProjectSpecificName() throws {
        let provider = EnvironmentTokenProvider(
            environment: ["PRSTACK_GITHUB_TOKEN": "project", "GITHUB_TOKEN": "generic"]
        )
        XCTAssertEqual(try provider.token(), "project")
    }

    func testEnvironmentProviderFallsThroughEmptyValues() throws {
        let provider = EnvironmentTokenProvider(
            environment: ["PRSTACK_GITHUB_TOKEN": "  ", "GITHUB_TOKEN": "generic\n"]
        )
        XCTAssertEqual(try provider.token(), "generic")
    }

    func testAbsentTokenIsMissingTokenNotAnEmptyString() {
        let provider = EnvironmentTokenProvider(environment: [:])
        XCTAssertThrowsError(try provider.token()) { error in
            XCTAssertEqual(error as? GitHubError, GitHubError.missingToken)
        }
    }

    func testFirstAvailableTakesTheFirstProviderThatHasOne() throws {
        let provider = FirstAvailableTokenProvider([
            EnvironmentTokenProvider(environment: [:]),
            StaticTokenProvider("from-keychain")
        ])
        XCTAssertEqual(try provider.token(), "from-keychain")
    }

    /// A store that is present but refuses to answer is a real failure. Masking it with a
    /// later provider that happens to have nothing would report "not connected" for what
    /// is actually a broken keychain.
    func testFirstAvailableSurfacesARealFailureRatherThanMaskingIt() {
        struct Broken: TokenProvider {
            struct Failure: Error {}
            func token() throws -> String { throw Failure() }
        }
        let provider = FirstAvailableTokenProvider([Broken(), EnvironmentTokenProvider(environment: [:])])
        XCTAssertThrowsError(try provider.token()) { error in
            XCTAssertTrue(error is Broken.Failure)
        }
    }

    func testFirstAvailableWithNothingConfiguredIsMissingToken() {
        let provider = FirstAvailableTokenProvider([EnvironmentTokenProvider(environment: [:])])
        XCTAssertThrowsError(try provider.token()) { error in
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
