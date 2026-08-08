import Foundation
import NetKit
import XCTest
@testable import GitHubKit

final class RESTClientTests: XCTestCase {
    private let base = URL(string: "https://api.github.test")!

    private func client(_ transport: StubTransport, etags: any ETagStore) -> RESTClient {
        RESTClient(
            transport: transport,
            tokenProvider: StaticTokenProvider("ghp_test"),
            baseURL: base,
            etagStore: etags
        )
    }

    func testFirstRequestIsUnconditionalAndStoresTheValidator() async throws {
        let etags = InMemoryETagStore()
        let transport = StubTransport(responses: [
            .json(#"{"status":"behind"}"#, headers: ["ETag": "W/\"abc\""])
        ])

        let result = try await client(transport, etags: etags)
            .get(path: "/repos/acme/billing/compare/v1.2.0...9f1c2ab")

        XCTAssertEqual(result.payload, .changed(Data(#"{"status":"behind"}"#.utf8)))
        XCTAssertNil(transport.requests[0].header("If-None-Match"))
        XCTAssertEqual(
            etags.etag(for: base.absoluteString + "/repos/acme/billing/compare/v1.2.0...9f1c2ab"),
            "W/\"abc\""
        )
    }

    /// The whole point: a repeated comparison costs a 304, and a 304 costs nothing against
    /// the REST allowance.
    func testSecondRequestIsConditionalAndA304IsUnchangedNotAnError() async throws {
        let etags = InMemoryETagStore()
        let transport = StubTransport(responses: [
            .json(#"{"status":"behind"}"#, headers: ["ETag": "W/\"abc\""]),
            HTTPResponse(status: 304, headers: ["ETag": "W/\"abc\""])
        ])
        let client = self.client(transport, etags: etags)

        _ = try await client.get(path: "/repos/acme/billing/compare/v1.2.0...9f1c2ab")
        let second = try await client.get(path: "/repos/acme/billing/compare/v1.2.0...9f1c2ab")

        XCTAssertEqual(transport.requests[1].header("If-None-Match"), "W/\"abc\"")
        XCTAssertTrue(second.payload.isUnchanged)
        XCTAssertNil(second.payload.data)
    }

    /// Keeping a validator after a failure would make the next successful request answer
    /// 304 against a body that was never received.
    func testAFailedRequestDiscardsTheStoredValidator() async throws {
        let etags = InMemoryETagStore()
        let key = base.absoluteString + "/repos/acme/billing/compare/v1.2.0...9f1c2ab"
        etags.setETag("W/\"stale\"", for: key)

        let transport = StubTransport(responses: [.json(#"{"message":"Not Found"}"#, status: 404)])
        do {
            _ = try await client(transport, etags: etags)
                .get(path: "/repos/acme/billing/compare/v1.2.0...9f1c2ab")
            XCTFail("expected a 404 to throw")
        } catch {
            XCTAssertEqual(error as? GitHubError, GitHubError.http(status: 404, message: "Not Found"))
        }
        XCTAssertNil(etags.etag(for: key))
    }

    func testRateLimitHeadersAreRead() async throws {
        let transport = StubTransport(responses: [
            .json(
                "{}",
                headers: [
                    "x-ratelimit-limit": "5000",
                    "x-ratelimit-remaining": "4321",
                    "x-ratelimit-reset": "1800000000"
                ]
            )
        ])
        let result = try await client(transport, etags: InMemoryETagStore()).get(path: "/rate_limit")

        XCTAssertEqual(
            result.rateLimit,
            RESTRateLimit(
                limit: 5_000,
                remaining: 4_321,
                resetAt: Date(timeIntervalSince1970: 1_800_000_000)
            )
        )
    }

    /// HTTP header names are case-insensitive and the two `URLSession` implementations
    /// disagree about the casing they hand back, so every read goes through a
    /// case-insensitive lookup.
    func testHeaderLookupIsCaseInsensitive() async throws {
        let etags = InMemoryETagStore()
        let transport = StubTransport(responses: [.json("{}", headers: ["etag": "W/\"lower\""])])
        _ = try await client(transport, etags: etags).get(path: "/rate_limit")
        XCTAssertEqual(etags.etag(for: base.absoluteString + "/rate_limit"), "W/\"lower\"")
    }

    func testQueryItemsReachTheURL() async throws {
        let transport = StubTransport(responses: [.json("{}")])
        _ = try await client(transport, etags: InMemoryETagStore())
            .get(path: "repos/acme/billing/tags", queryItems: [URLQueryItem(name: "per_page", value: "100")])
        XCTAssertEqual(
            transport.requests[0].url.absoluteString,
            base.absoluteString + "/repos/acme/billing/tags?per_page=100"
        )
    }
}
