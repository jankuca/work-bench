import Foundation
import XCTest
@testable import NetKit

/// The credential seam, exercised without either service kit. What each of them adds is
/// the *names* — `$PRSTACK_GITHUB_TOKEN`, `$PRSTACK_LINEAR_KEY` — and those are tested
/// where they are declared.
final class TokenProviderTests: XCTestCase {
    private let names = ["PRIMARY", "FALLBACK"]

    func testEnvironmentProviderPrefersTheFirstName() throws {
        let provider = EnvironmentTokenProvider(
            names: names,
            environment: ["PRIMARY": "project", "FALLBACK": "generic"]
        )
        XCTAssertEqual(try provider.token(), "project")
    }

    /// A pasted credential routinely carries a trailing newline, and a variable set to
    /// whitespace is a variable that is not set.
    func testEnvironmentProviderFallsThroughEmptyValuesAndTrims() throws {
        let provider = EnvironmentTokenProvider(
            names: names,
            environment: ["PRIMARY": "  ", "FALLBACK": "generic\n"]
        )
        XCTAssertEqual(try provider.token(), "generic")
    }

    func testAbsentTokenIsMissingCredentialNotAnEmptyString() {
        let provider = EnvironmentTokenProvider(names: names, service: "Linear", environment: [:])
        XCTAssertThrowsError(try provider.token()) { error in
            XCTAssertEqual(error as? MissingCredential, MissingCredential(service: "Linear"))
        }
    }

    func testStaticProviderTreatsWhitespaceAsNothingConfigured() {
        XCTAssertThrowsError(try StaticTokenProvider(" \n ").token()) { error in
            XCTAssertTrue(error is MissingCredential)
        }
    }

    func testFirstAvailableTakesTheFirstProviderThatHasOne() throws {
        let provider = FirstAvailableTokenProvider([
            EnvironmentTokenProvider(names: names, environment: [:]),
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
        let provider = FirstAvailableTokenProvider([
            Broken(),
            EnvironmentTokenProvider(names: names, environment: [:])
        ])
        XCTAssertThrowsError(try provider.token()) { error in
            XCTAssertTrue(error is Broken.Failure)
        }
    }

    func testFirstAvailableWithNothingConfiguredIsMissingCredential() {
        let provider = FirstAvailableTokenProvider(
            [EnvironmentTokenProvider(names: names, environment: [:])],
            service: "GitHub"
        )
        XCTAssertThrowsError(try provider.token()) { error in
            XCTAssertEqual(error as? MissingCredential, MissingCredential(service: "GitHub"))
        }
    }
}

final class GraphQLErrorTests: XCTestCase {
    /// `path` is what makes a batched query recoverable: it names which aliased field
    /// failed, so the batch can be retried without it instead of being abandoned whole.
    func testPathDecodesFieldNamesAndListIndices() throws {
        let body = Data(
            """
            {"errors": [
              {"message": "Entity not found", "path": ["a3"]},
              {"message": "nope", "path": ["search", "nodes", 2], "extensions": {"code": 7}},
              {"message": "no path at all"}
            ]}
            """.utf8
        )
        let errors = GraphQLErrorsOnly.read(body)
        XCTAssertEqual(errors.count, 3)
        XCTAssertEqual(errors[0].path, ["a3"])
        XCTAssertEqual(errors[1].path, ["search", "nodes", "2"])
        XCTAssertNil(errors[2].path)
    }

    /// A body whose `data` is unrelated to the query's own result type still has to give
    /// up its errors — that is the whole point of reading them separately.
    func testErrorsAreReadableFromAResponseWhoseDataIsNull() {
        let body = Data(#"{"data": null, "errors": [{"message": "boom", "type": "RATE_LIMITED"}]}"#.utf8)
        let errors = GraphQLErrorsOnly.read(body)
        XCTAssertEqual(errors.map(\.type), ["RATE_LIMITED"])
        XCTAssertEqual(errors.first?.description, "RATE_LIMITED: boom")
    }

    func testAResponseWithNoErrorsReadsAsNone() {
        XCTAssertTrue(GraphQLErrorsOnly.read(Data(#"{"data": {"a0": null}}"#.utf8)).isEmpty)
        XCTAssertTrue(GraphQLErrorsOnly.read(Data("not json at all".utf8)).isEmpty)
    }

    func testVariablesEncodeAsTheJSONValueSpace() throws {
        let body = try GraphQLRequestBody(
            query: "query { a }",
            variables: ["s": .string("x"), "n": .int(3), "b": .bool(true), "z": .null]
        ).encoded()
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        let variables = try XCTUnwrap(object["variables"] as? [String: Any])
        XCTAssertEqual(variables["s"] as? String, "x")
        XCTAssertEqual(variables["n"] as? Int, 3)
        XCTAssertEqual(variables["b"] as? Bool, true)
        XCTAssertTrue(variables["z"] is NSNull)
    }
}
