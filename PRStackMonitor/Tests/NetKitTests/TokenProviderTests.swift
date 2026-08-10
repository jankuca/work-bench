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

    /// The shared chain: an explicit value beats the environment, and both beat the
    /// Keychain. The Keychain link is only present on a platform that has one, which is why
    /// this asserts the *order* of what it finds rather than the length of the chain.
    func testCredentialChainPrefersTheExplicitValueThenTheEnvironment() throws {
        let environment = EnvironmentTokenProvider(names: names, environment: ["PRIMARY": "from-env"])

        let explicit = CredentialChain.standard(
            explicit: "from-flag",
            environment: environment,
            keychain: .github,
            service: "GitHub"
        )
        XCTAssertEqual(try explicit.token(), "from-flag")

        let fromEnvironment = CredentialChain.standard(
            environment: environment,
            keychain: .github,
            service: "GitHub"
        )
        XCTAssertEqual(try fromEnvironment.token(), "from-env")
    }

    /// An explicit value of whitespace is not a credential, and must fall through rather
    /// than short-circuiting the chain with an empty string.
    func testCredentialChainFallsThroughAnEmptyExplicitValue() throws {
        let chain = CredentialChain.standard(
            explicit: "  \n",
            environment: EnvironmentTokenProvider(names: names, environment: ["PRIMARY": "from-env"]),
            keychain: .linear,
            service: "Linear"
        )
        XCTAssertEqual(try chain.token(), "from-env")
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

    /// `path` says which field failed; `code` says why. Only the pair together makes a
    /// batched failure recoverable rather than merely attributable — one classification is
    /// cacheable ("no such entity") and the other is not.
    func testCodeReadsExtensionsCodeThenExtensionsType() {
        let body = Data(
            """
            {"errors": [
              {"message": "a", "path": ["a0"], "extensions": {"code": "ENTITY_NOT_FOUND"}},
              {"message": "b", "path": ["a1"], "extensions": {"type": "not_found"}},
              {"message": "c", "path": ["a2"], "extensions": {"code": "X", "type": "Y"}},
              {"message": "d", "path": ["a3"], "extensions": {"userPresentableMessage": "nope"}},
              {"message": "e", "path": ["a4"]}
            ]}
            """.utf8
        )
        XCTAssertEqual(
            GraphQLErrorsOnly.read(body).map { $0.code },
            ["ENTITY_NOT_FOUND", "not_found", "X", nil, nil]
        )
    }

    /// `extensions` is free-form, so a shape we did not expect must not fail the decode of
    /// the error carrying it — an error we cannot classify is still one the caller has to
    /// see.
    func testAnUnexpectedExtensionsShapeStillYieldsTheError() {
        let body = Data(#"{"errors": [{"message": "boom", "extensions": ["not", "an", "object"]}]}"#.utf8)
        let errors = GraphQLErrorsOnly.read(body)
        XCTAssertEqual(errors.map(\.message), ["boom"])
        XCTAssertNil(errors.first?.code)
    }

    /// A body whose `data` is unrelated to the query's own result type still has to give
    /// up its errors — that is the whole point of reading them separately.
    func testErrorsAreReadableFromAResponseWhoseDataIsNull() {
        let body = Data(#"{"data": null, "errors": [{"message": "boom", "type": "RATE_LIMITED"}]}"#.utf8)
        let errors = GraphQLErrorsOnly.read(body)
        XCTAssertEqual(errors.map(\.type), ["RATE_LIMITED"])
        XCTAssertEqual(errors.first?.description, "RATE_LIMITED: boom")
    }

    /// The path is what turns "something is forbidden" into "this field is forbidden".
    /// A partial failure arrives as one error per affected node, every one of them carrying
    /// the same sentence, so the path is the only part of the line that names the selection
    /// the server refused — and therefore the permission that is missing.
    func testDescriptionNamesTheFieldThatFailed() {
        let body = Data(
            """
            {"errors": [{
              "message": "Resource not accessible by personal access token",
              "type": "FORBIDDEN",
              "path": ["search", "nodes", 2, "commits", "nodes", 0, "commit", "statusCheckRollup"]
            }]}
            """.utf8
        )
        XCTAssertEqual(
            GraphQLErrorsOnly.read(body).first?.description,
            "FORBIDDEN: Resource not accessible by personal access token"
                + " (at search.nodes.2.commits.nodes.0.commit.statusCheckRollup)"
        )
    }

    /// Linear classifies in `extensions` and sends no top-level `type`, so without the
    /// fallback its failures print as a bare sentence with no classification at all.
    func testDescriptionFallsBackToTheExtensionsCode() {
        let body = Data(
            #"{"errors": [{"message": "Entity not found: Issue", "path": ["a3"], "extensions": {"code": "ENTITY_NOT_FOUND"}}]}"#.utf8
        )
        XCTAssertEqual(
            GraphQLErrorsOnly.read(body).first?.description,
            "ENTITY_NOT_FOUND: Entity not found: Issue (at a3)"
        )
    }

    /// An error with neither classification nor path is still just its message — the
    /// additions above must not decorate a line that has nothing to add.
    func testDescriptionOfABareErrorIsJustTheMessage() {
        XCTAssertEqual(
            GraphQLErrorsOnly.read(Data(#"{"errors": [{"message": "boom"}]}"#.utf8)).first?.description,
            "boom"
        )
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
