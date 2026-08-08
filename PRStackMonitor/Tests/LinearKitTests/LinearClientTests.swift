import Foundation
import NetKit
import PRStackCore
import XCTest
@testable import LinearKit

final class LinearClientTests: XCTestCase {
    private func client(
        _ transport: StubTransport,
        key: String = "lin_api_test",
        batchSize: Int = LinearClient.Configuration.defaultBatchSize
    ) -> LinearClient {
        LinearClient(
            transport: transport,
            tokenProvider: StaticTokenProvider(key),
            configuration: LinearClient.Configuration(batchSize: batchSize)
        )
    }

    // MARK: - Request shape

    func testPostsOneAliasedIssueFieldPerIdentifier() async throws {
        let transport = StubTransport(responses: [
            .json(
                """
                {"data": {
                  "a0": {"identifier": "BIL-312", "url": "https://linear.app/acme/issue/BIL-312",
                         "project": {"id": "proj-billing", "name": "Billing"}},
                  "a1": {"identifier": "SRC-97", "url": "https://linear.app/acme/issue/SRC-97",
                         "project": {"id": "proj-source", "name": "Source"}}
                }}
                """
            )
        ])

        let result = try await client(transport).resolve(identifiers: ["BIL-312", "SRC-97"])

        XCTAssertEqual(result.found["BIL-312"]?.projectName, "Billing")
        XCTAssertEqual(result.found["SRC-97"]?.projectName, "Source")
        XCTAssertTrue(result.unknown.isEmpty)
        XCTAssertTrue(result.unresolved.isEmpty)

        let request = try XCTUnwrap(transport.requests.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.url, LinearAPI.endpoint)
        XCTAssertEqual(request.header("Content-Type"), "application/json")
        XCTAssertEqual(request.header("User-Agent"), LinearAPI.userAgent)

        let query = try transport.query(0)
        XCTAssertTrue(query.contains("a0: issue(id: $a0)"), query)
        XCTAssertTrue(query.contains("a1: issue(id: $a1)"), query)
        XCTAssertTrue(query.contains("project { id name }"), query)
        XCTAssertEqual(try transport.requestedIdentifiers(0), ["BIL-312", "SRC-97"])
    }

    /// `linear-cross-team-number-collision` (IMPLEMENTATION_PLAN §2).
    ///
    /// The unsafe form is `issues(filter: { team: { key: { in: [...] } }, number: { in:
    /// [...] } })`: the two `in` lists match the cross-product, so asking for `BIL-312` and
    /// `SRC-97` also matches `BIL-97` and `SRC-312` and files pull requests under the wrong
    /// project. Per-identifier `issue(id:)` cannot express that shape at all — this asserts
    /// the query never acquires it, and that the full identifier is what travels.
    func testResolutionIsPerIdentifierAndNeverACrossProductFilter() async throws {
        let transport = StubTransport(responses: [
            .json(
                """
                {"data": {
                  "a0": {"identifier": "BIL-312", "project": {"id": "proj-billing", "name": "Billing"}},
                  "a1": {"identifier": "SRC-97", "project": {"id": "proj-source", "name": "Source"}}
                }}
                """
            )
        ])

        let result = try await client(transport).resolve(identifiers: ["BIL-312", "SRC-97"])

        let query = try transport.query(0)
        XCTAssertFalse(query.contains("issues("), "the cross-product filter form must never appear")
        XCTAssertFalse(query.contains("number:"), query)
        XCTAssertFalse(query.contains("team:"), query)
        // The full identifier is the key throughout — never split into a key and a number,
        // which is what makes the collision impossible to reintroduce.
        XCTAssertEqual(try transport.requestedIdentifiers(0).sorted(), ["BIL-312", "SRC-97"])
        XCTAssertEqual(Set(result.found.keys), ["BIL-312", "SRC-97"])
        XCTAssertNil(result.found["BIL-97"])
        XCTAssertNil(result.found["SRC-312"])
    }

    /// A personal API key goes in `Authorization` bare; the `Bearer` prefix is for OAuth
    /// tokens and sending it with a personal key is answered with an authentication error.
    func testPersonalKeysAreSentWithoutABearerPrefix() async throws {
        let transport = StubTransport.always(.json(#"{"data": {}}"#))
        _ = try await client(transport, key: "lin_api_abc").resolve(identifiers: ["BIL-1"])
        XCTAssertEqual(transport.requests.first?.header("Authorization"), "lin_api_abc")

        let oauth = StubTransport.always(.json(#"{"data": {}}"#))
        _ = try await client(oauth, key: "oauth-token").resolve(identifiers: ["BIL-1"])
        XCTAssertEqual(oauth.requests.first?.header("Authorization"), "Bearer oauth-token")
    }

    func testMissingKeyNeverReachesTheNetwork() async {
        let transport = StubTransport(responses: [])
        let client = LinearClient(transport: transport, tokenProvider: StaticTokenProvider("  "))
        do {
            _ = try await client.resolve(identifiers: ["BIL-312"])
            XCTFail("expected a missing-key failure")
        } catch {
            XCTAssertEqual(error as? LinearError, LinearError.missingKey)
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    func testNothingToResolveSendsNoRequest() async throws {
        let transport = StubTransport(responses: [])
        let result = try await client(transport).resolve(identifiers: [])
        XCTAssertTrue(result.found.isEmpty)
        XCTAssertEqual(transport.requestCount, 0)
    }

    // MARK: - Unknown identifiers

    /// The scanner cannot tell `UTF-8` from a team key, so a batch routinely carries
    /// identifiers Linear has never heard of. They come back as unknown — a *cacheable*
    /// answer — rather than as a failure.
    func testANullAliasIsAnUnknownIdentifierNotAFailure() async throws {
        let transport = StubTransport(responses: [
            .json(
                """
                {"data": {
                  "a0": {"identifier": "BIL-312", "project": {"id": "proj-billing", "name": "Billing"}},
                  "a1": null
                }}
                """
            )
        ])

        let result = try await client(transport).resolve(identifiers: ["BIL-312", "UTF-8"])
        XCTAssertEqual(Set(result.found.keys), ["BIL-312"])
        XCTAssertEqual(result.unknown, ["UTF-8"])
        XCTAssertTrue(result.unresolved.isEmpty)
    }

    /// The failure mode this client exists to survive: Linear declares `issue(id:)` as
    /// non-null, so an identifier it does not have nulls `data` **for the whole batch**.
    /// One `UTF-8` in a title would otherwise cost every other row its project heading.
    ///
    /// `errors[].path` names the alias that failed, so the batch is retried without it —
    /// once.
    func testAWhollyNulledBatchIsRetriedWithoutTheAliasTheErrorBlames() async throws {
        let transport = StubTransport(responses: [
            .json(
                """
                {"data": null,
                 "errors": [{"message": "Entity not found: Issue", "path": ["a1"]}]}
                """
            ),
            .json(
                """
                {"data": {
                  "a0": {"identifier": "BIL-312", "project": {"id": "proj-billing", "name": "Billing"}},
                  "a1": {"identifier": "SRC-97", "project": {"id": "proj-source", "name": "Source"}}
                }}
                """
            )
        ])

        let result = try await client(transport).resolve(identifiers: ["BIL-312", "UTF-8", "SRC-97"])

        XCTAssertEqual(Set(result.found.keys), ["BIL-312", "SRC-97"])
        XCTAssertEqual(result.unknown, ["UTF-8"])
        XCTAssertTrue(result.unresolved.isEmpty)
        XCTAssertEqual(transport.requestCount, 2)
        XCTAssertEqual(try transport.requestedIdentifiers(0), ["BIL-312", "UTF-8", "SRC-97"])
        // The retry drops only the blamed identifier, and keeps the rest in their original
        // order so the second request is the first one minus one field.
        XCTAssertEqual(try transport.requestedIdentifiers(1), ["BIL-312", "SRC-97"])
    }

    /// Exactly one retry. A response that blames nothing gives no way to make progress, and
    /// re-sending the identical request would spin.
    func testABatchThatBlamesNothingIsNotRetried() async throws {
        let transport = StubTransport(responses: [
            .json(#"{"data": null, "errors": [{"message": "Internal error"}]}"#)
        ])

        let result = try await client(transport).resolve(identifiers: ["BIL-312", "SRC-97"])

        XCTAssertTrue(result.found.isEmpty)
        XCTAssertTrue(result.unknown.isEmpty, "nothing is known to be missing, so nothing may be cached")
        XCTAssertEqual(result.unresolved, ["BIL-312", "SRC-97"])
        XCTAssertEqual(transport.requestCount, 1)
    }

    /// Two missing aliases, blamed one per round: the second failure has spent the retry,
    /// so what is left comes back unresolved rather than driving a third request.
    func testTheRetryIsSpentOnceEvenIfMoreAliasesFail() async throws {
        let missing = #"{"data": null, "errors": [{"message": "Entity not found: Issue", "path": ["a1"]}]}"#
        let transport = StubTransport(responses: [.json(missing), .json(missing)])

        let result = try await client(transport).resolve(identifiers: ["BIL-312", "UTF-8", "SHA-256"])

        XCTAssertEqual(result.unknown, ["UTF-8", "SHA-256"])
        XCTAssertEqual(result.unresolved, ["BIL-312"])
        XCTAssertEqual(transport.requestCount, 2)
    }

    /// `path` names the field that failed; it says nothing about *why*, and the difference
    /// decides whether the answer may be cached. "No such issue" holds tomorrow. A
    /// permission failure does not — caching it as unknown would strip a real ticket's
    /// project heading for a day over a transient fault.
    func testOnlyANotFoundIsCacheableAndEverythingElseIsUnresolved() async throws {
        let transport = StubTransport(responses: [
            .json(
                """
                {"data": null,
                 "errors": [
                   {"message": "Entity not found: Issue", "path": ["a0"],
                    "extensions": {"code": "ENTITY_NOT_FOUND"}},
                   {"message": "You do not have access to this resource", "path": ["a1"],
                    "extensions": {"code": "FEATURE_NOT_ACCESSIBLE"}},
                   {"message": "Something went wrong", "path": ["a2"]}
                 ]}
                """
            )
        ])

        let result = try await client(transport).resolve(identifiers: ["UTF-8", "SEC-1", "OPS-2"])

        XCTAssertEqual(result.unknown, ["UTF-8"], "only the not-found may be remembered")
        XCTAssertEqual(result.unresolved, ["SEC-1", "OPS-2"], "asked again next poll")
        XCTAssertEqual(transport.requestCount, 1, "every alias was settled, so there is nothing to retry")
    }

    /// The classification reads `extensions.code`, the error `type`, or the message — Linear
    /// carries the answer in whichever of those the response has.
    func testANotFoundIsRecognisedFromCodeTypeOrMessage() async throws {
        for error in [
            #"{"message": "boom", "path": ["a0"], "extensions": {"code": "ENTITY_NOT_FOUND"}}"#,
            #"{"message": "boom", "path": ["a0"], "type": "not_found"}"#,
            #"{"message": "Entity not found: Issue", "path": ["a0"]}"#
        ] {
            let transport = StubTransport(responses: [.json(#"{"data": null, "errors": [\#(error)]}"#)])
            let result = try await client(transport).resolve(identifiers: ["UTF-8"])
            XCTAssertEqual(result.unknown, ["UTF-8"], error)
            XCTAssertTrue(result.unresolved.isEmpty, error)
        }
    }

    // MARK: - Failures

    func testUnauthorizedIsRaisedRatherThanCountedAsUnknownIdentifiers() async {
        let transport = StubTransport(responses: [
            .json(#"{"errors": [{"message": "Authentication required, not authenticated"}]}"#, status: 401)
        ])
        do {
            _ = try await client(transport).resolve(identifiers: ["BIL-312"])
            XCTFail("expected an authentication failure")
        } catch {
            XCTAssertEqual(
                error as? LinearError,
                LinearError.unauthorized("Authentication required, not authenticated")
            )
            XCTAssertEqual((error as? LinearError)?.isAuthenticationFailure, true)
        }
    }

    /// Some Linear deployments answer an expired key with a `200` and an `errors` array.
    /// Read as an ordinary partial failure that would cache forty identifiers as unknown
    /// and quietly empty every project heading.
    func testAnAuthenticationErrorInA200IsStillAnAuthenticationFailure() async {
        let transport = StubTransport(responses: [
            .json(
                """
                {"data": null,
                 "errors": [{"message": "invalid key", "type": "AUTHENTICATION_ERROR", "path": ["a0"]}]}
                """
            )
        ])
        do {
            _ = try await client(transport).resolve(identifiers: ["BIL-312"])
            XCTFail("expected an authentication failure")
        } catch {
            XCTAssertEqual((error as? LinearError)?.isAuthenticationFailure, true)
        }
    }

    func testATransportFailureBecomesALinearError() async {
        struct Offline: Error {}
        let transport = StubTransport([.fail(Offline())])
        do {
            _ = try await client(transport).resolve(identifiers: ["BIL-312"])
            XCTFail("expected a transport failure")
        } catch {
            guard let linear = error as? LinearError, case .transport = linear else {
                return XCTFail("expected LinearError.transport, got \(error)")
            }
        }
    }

    /// Cancellation is the user closing the panel, not an outage. It has to survive the
    /// wrapping above so the caller can tell the two apart.
    func testCancellationIsRethrownRatherThanWrapped() async {
        let transport = StubTransport([.fail(CancellationError())])
        do {
            _ = try await client(transport).resolve(identifiers: ["BIL-312"])
            XCTFail("expected the cancellation to propagate")
        } catch {
            XCTAssertTrue(error is CancellationError, "got \(error)")
        }
    }

    func testARefusedInsecureEndpointNeverSendsTheKey() async {
        let transport = StubTransport(responses: [])
        let client = LinearClient(
            transport: transport,
            tokenProvider: StaticTokenProvider("lin_api_test"),
            configuration: LinearClient.Configuration(
                endpoint: URL(string: "http://api.linear.app/graphql")!
            )
        )
        do {
            _ = try await client.resolve(identifiers: ["BIL-312"])
            XCTFail("expected the request to be refused")
        } catch {
            guard let linear = error as? LinearError, case .insecureEndpoint = linear else {
                return XCTFail("expected LinearError.insecureEndpoint, got \(error)")
            }
        }
        XCTAssertTrue(transport.requests.isEmpty)
    }

    // MARK: - Batching

    func testIdentifiersArePagedIntoBatchesInOrder() async throws {
        let transport = StubTransport(responses: [
            .json(#"{"data": {}}"#),
            .json(#"{"data": {}}"#)
        ])

        _ = try await client(transport, batchSize: 2)
            .resolve(identifiers: ["BIL-1", "BIL-2", "BIL-3"])

        XCTAssertEqual(transport.requestCount, 2)
        XCTAssertEqual(try transport.requestedIdentifiers(0), ["BIL-1", "BIL-2"])
        XCTAssertEqual(try transport.requestedIdentifiers(1), ["BIL-3"])
    }

    /// An empty `data` means the aliases were neither answered nor blamed. Nothing is
    /// known, so nothing is cached either way.
    func testAnEmptyDataObjectLeavesIdentifiersUnresolved() async throws {
        let transport = StubTransport(responses: [.json(#"{"data": {}}"#)])
        let result = try await client(transport).resolve(identifiers: ["BIL-312"])
        XCTAssertTrue(result.found.isEmpty)
        XCTAssertTrue(result.unknown.isEmpty)
        XCTAssertEqual(result.unresolved, ["BIL-312"])
    }
}
