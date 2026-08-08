import Foundation
import NetKit
import XCTest
@testable import GitHubKit

private struct Probe: Decodable, Equatable {
    var value: String
}

final class GraphQLClientTests: XCTestCase {
    private func client(_ transport: StubTransport, token: String = "ghp_test") -> GraphQLClient {
        GraphQLClient(transport: transport, tokenProvider: StaticTokenProvider(token))
    }

    func testSendsAPostWithBearerAuthAndTheQuery() async throws {
        let transport = StubTransport(responses: [.json(#"{"data":{"value":"ok"}}"#)])
        let result: GraphQLResult<Probe> = try await client(transport)
            .perform(query: "query Q { value }", variables: ["n": .int(3)])

        XCTAssertEqual(result.data, Probe(value: "ok"))

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.url, GitHubAPI.graphQLEndpoint)
        XCTAssertEqual(request.header("Authorization"), "Bearer ghp_test")
        XCTAssertEqual(request.header("Content-Type"), "application/json")
        // GitHub rejects requests without a User-Agent, so this is load-bearing.
        XCTAssertEqual(request.header("User-Agent"), GitHubAPI.userAgent)

        let body = try transport.requestBody(0)
        XCTAssertEqual(body["query"] as? String, "query Q { value }")
        XCTAssertEqual(try transport.requestVariables(0)["n"] as? Int, 3)
    }

    func testTokenIsTrimmedBeforeItGoesOnTheWire() async throws {
        let transport = StubTransport(responses: [.json(#"{"data":{"value":"ok"}}"#)])
        let _: GraphQLResult<Probe> = try await client(transport, token: "  ghp_test\n")
            .perform(query: "query Q { value }")
        XCTAssertEqual(transport.requests.first?.header("Authorization"), "Bearer ghp_test")
    }

    func testMissingTokenNeverReachesTheNetwork() async {
        let transport = StubTransport(responses: [])
        let client = GraphQLClient(transport: transport, tokenProvider: StaticTokenProvider("   "))
        do {
            let _: GraphQLResult<Probe> = try await client.perform(query: "query Q { value }")
            XCTFail("expected a missing-token failure")
        } catch {
            XCTAssertEqual(error as? GitHubError, GitHubError.missingToken)
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testUnauthorizedCarriesGitHubsOwnMessage() async {
        let transport = StubTransport(responses: [
            .json(#"{"message":"Bad credentials"}"#, status: 401)
        ])
        do {
            let _: GraphQLResult<Probe> = try await client(transport).perform(query: "query Q { value }")
            XCTFail("expected an authentication failure")
        } catch {
            XCTAssertEqual(error as? GitHubError, GitHubError.unauthorized("Bad credentials"))
            XCTAssertTrue((error as? GitHubError)?.isAuthenticationFailure == true)
        }
    }

    /// A 403 is GitHub's answer both to a bad token and to a spent allowance. Only the
    /// remaining-count header tells them apart, and only one of the two is worth retrying.
    func testSpentAllowanceIsRateLimitedNotUnauthorized() async {
        let reset = Date(timeIntervalSince1970: 1_800_000_000)
        let transport = StubTransport(responses: [
            .json(
                #"{"message":"API rate limit exceeded"}"#,
                status: 403,
                headers: [
                    "x-ratelimit-remaining": "0",
                    "x-ratelimit-reset": "1800000000"
                ]
            )
        ])
        do {
            let _: GraphQLResult<Probe> = try await client(transport).perform(query: "query Q { value }")
            XCTFail("expected a rate limit failure")
        } catch {
            XCTAssertEqual(error as? GitHubError, GitHubError.rateLimited(resetAt: reset))
            XCTAssertFalse((error as? GitHubError)?.isAuthenticationFailure == true)
        }
    }

    /// GitHub reports an exhausted GraphQL allowance as a 200 carrying a RATE_LIMITED
    /// error. Reading it as an ordinary GraphQL error would let the scheduler keep polling
    /// straight into the wall.
    func testRateLimitedGraphQLErrorIsNotAnOrdinaryError() async {
        let transport = StubTransport(responses: [
            .json(#"{"errors":[{"type":"RATE_LIMITED","message":"API rate limit exceeded"}]}"#)
        ])
        do {
            let _: GraphQLResult<Probe> = try await client(transport).perform(query: "query Q { value }")
            XCTFail("expected a rate limit failure")
        } catch {
            XCTAssertEqual(error as? GitHubError, GitHubError.rateLimited(resetAt: nil))
        }
    }

    /// The reset time is what the scheduler backs off *until*, so it is worth recovering
    /// from the body the same response already carries.
    func testRateLimitedErrorRecoversItsResetTimeFromTheBody() async {
        let transport = StubTransport(responses: [
            .json(
                """
                {"data":{"rateLimit":{"resetAt":"2026-01-10T13:00:00Z"}},
                 "errors":[{"type":"RATE_LIMITED","message":"API rate limit exceeded"}]}
                """
            )
        ])
        do {
            let _: GraphQLResult<Probe> = try await client(transport).perform(query: "query Q { value }")
            XCTFail("expected a rate limit failure")
        } catch {
            XCTAssertEqual(
                error as? GitHubError,
                GitHubError.rateLimited(resetAt: ISO8601DateFormatter().date(from: "2026-01-10T13:00:00Z"))
            )
        }
    }

    func testRateLimitedErrorFallsBackToTheResetHeader() async {
        let transport = StubTransport(responses: [
            .json(
                #"{"errors":[{"type":"RATE_LIMITED","message":"API rate limit exceeded"}]}"#,
                headers: ["x-ratelimit-remaining": "0", "x-ratelimit-reset": "1800000000"]
            )
        ])
        do {
            let _: GraphQLResult<Probe> = try await client(transport).perform(query: "query Q { value }")
            XCTFail("expected a rate limit failure")
        } catch {
            XCTAssertEqual(
                error as? GitHubError,
                GitHubError.rateLimited(resetAt: Date(timeIntervalSince1970: 1_800_000_000))
            )
        }
    }

    /// A token put on the wire in cleartext is disclosed the moment it is sent, so the
    /// request is refused before it is made rather than after it fails.
    func testCredentialsAreNeverSentToANonHTTPSEndpoint() async {
        let endpoint = URL(string: "http://api.github.test/graphql")!
        let transport = StubTransport(responses: [])
        let client = GraphQLClient(
            transport: transport,
            tokenProvider: StaticTokenProvider("ghp_test"),
            endpoint: endpoint
        )
        do {
            let _: GraphQLResult<Probe> = try await client.perform(query: "query Q { value }")
            XCTFail("expected the request to be refused")
        } catch {
            XCTAssertEqual(error as? GitHubError, GitHubError.insecureEndpoint(endpoint))
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testAbsentDataWithErrorsThrows() async {
        let transport = StubTransport(responses: [
            .json(#"{"errors":[{"type":"NOT_FOUND","message":"Could not resolve to a Repository"}]}"#)
        ])
        do {
            let _: GraphQLResult<Probe> = try await client(transport).perform(query: "query Q { value }")
            XCTFail("expected a GraphQL failure")
        } catch {
            XCTAssertEqual(
                error as? GitHubError,
                GitHubError.graphQL(
                    [GraphQLError(message: "Could not resolve to a Repository", type: "NOT_FOUND")]
                )
            )
        }
    }

    /// One inaccessible repository does not invalidate the other forty results, so partial
    /// data comes back with the errors attached rather than being thrown away.
    func testPartialDataIsReturnedWithItsErrors() async throws {
        let transport = StubTransport(responses: [
            .json(#"{"data":{"value":"ok"},"errors":[{"type":"FORBIDDEN","message":"no access"}]}"#)
        ])
        let result: GraphQLResult<Probe> = try await client(transport).perform(query: "query Q { value }")
        XCTAssertEqual(result.data, Probe(value: "ok"))
        XCTAssertEqual(result.errors, [GraphQLError(message: "no access", type: "FORBIDDEN")])
    }

    func testUnreadableBodyIsReportedAsMalformedRatherThanCrashing() async {
        let transport = StubTransport(responses: [
            HTTPResponse(status: 200, headers: [:], body: Data("<html>gateway</html>".utf8))
        ])
        do {
            let _: GraphQLResult<Probe> = try await client(transport).perform(query: "query Q { value }")
            XCTFail("expected a malformed-response failure")
        } catch {
            guard let failure = error as? GitHubError, case .malformedResponse = failure else {
                return XCTFail("expected .malformedResponse, got \(error)")
            }
        }
    }

    func testServerErrorsSurviveAsHTTPStatusForBackoffToRetry() async {
        let transport = StubTransport(responses: [.json(#"{"message":"Server Error"}"#, status: 502)])
        do {
            let _: GraphQLResult<Probe> = try await client(transport).perform(query: "query Q { value }")
            XCTFail("expected an HTTP failure")
        } catch {
            XCTAssertEqual(error as? GitHubError, GitHubError.http(status: 502, message: "Server Error"))
        }
    }

    // MARK: - Classifying 403

    /// GitHub answers a *secondary* rate limit with a 403 while the hourly allowance is
    /// untouched. Reading that as an authentication failure raises the reconnect banner
    /// and the dashed menu bar glyph for what is a few seconds of throttling.
    func testSecondaryRateLimitIsNotAnAuthenticationFailure() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        let withRetryAfter = HTTPResponse(
            status: 403,
            headers: ["x-ratelimit-remaining": "4321", "Retry-After": "60"],
            body: Data(#"{"message":"You have exceeded a secondary rate limit"}"#.utf8)
        )
        XCTAssertEqual(
            GitHubAPI.error(for: withRetryAfter, now: now),
            GitHubError.rateLimited(resetAt: now.addingTimeInterval(60))
        )

        // The header is not always present; the documented phrase is the other signal.
        let messageOnly = HTTPResponse(
            status: 403,
            headers: ["x-ratelimit-remaining": "4321"],
            body: Data(#"{"message":"You have exceeded a secondary rate limit. Please wait."}"#.utf8)
        )
        XCTAssertEqual(
            GitHubAPI.error(for: messageOnly, now: now),
            GitHubError.rateLimited(resetAt: nil)
        )
    }

    /// `Retry-After` is delta-seconds *or* an HTTP-date. Reading it as a number only
    /// recognises the first, so the date form has to classify on the header's presence —
    /// otherwise a throttle with no "secondary rate limit" phrase in the body falls
    /// through to the reconnect path.
    func testAnHTTPDateRetryAfterStillClassifiesAsRateLimited() {
        let response = HTTPResponse(
            status: 403,
            headers: [
                "x-ratelimit-remaining": "4321",
                "Retry-After": "Wed, 21 Oct 2026 07:28:00 GMT"
            ],
            body: Data(#"{"message":"Request blocked"}"#.utf8)
        )
        let error = GitHubAPI.error(for: response, now: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(error, GitHubError.rateLimited(resetAt: nil))
        XCTAssertFalse(error.isAuthenticationFailure)
    }

    /// The distinction the classifier exists for: a genuinely bad token still has to reach
    /// the reconnect path.
    func testABadTokenIsStillAnAuthenticationFailure() {
        let response = HTTPResponse(
            status: 403,
            headers: ["x-ratelimit-remaining": "4321"],
            body: Data(#"{"message":"Bad credentials"}"#.utf8)
        )
        let error = GitHubAPI.error(for: response)
        XCTAssertEqual(error, GitHubError.unauthorized("Bad credentials"))
        XCTAssertTrue(error.isAuthenticationFailure)
    }

    func testVariablesEncodeAsJSON() throws {
        let encoded = try JSONEncoder().encode(
            GraphQLValue.object([
                "cursor": .null,
                "pageSize": .int(50),
                "flag": .bool(true),
                "names": .list([.string("a"), .string("b")])
            ])
        )
        // `null` has to survive as JSON null rather than becoming an omitted key: `after:
        // null` is how a GraphQL connection asks for the first page.
        XCTAssertTrue(String(decoding: encoded, as: UTF8.self).contains("\"cursor\":null"))

        let object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        XCTAssertEqual(object["pageSize"] as? Int, 50)
        XCTAssertEqual(object["flag"] as? Bool, true)
        XCTAssertEqual(object["names"] as? [String], ["a", "b"])
    }
}
