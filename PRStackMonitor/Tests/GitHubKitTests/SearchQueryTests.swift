import XCTest
@testable import GitHubKit

final class SearchQueryTests: XCTestCase {
    func testAllScopeIsTheBaseQualifiersAlone() throws {
        let query = try XCTUnwrap(SearchQuery.build(scope: .all))
        XCTAssertEqual(query.text, "is:pr author:@me -is:draft")
        XCTAssertTrue(query.droppedRepositories.isEmpty)
    }

    func testSelectedScopeOrsRepositoriesIntoOneQuery() throws {
        let query = try XCTUnwrap(
            SearchQuery.build(scope: .selected(["acme/billing", "acme/source"]))
        )
        // One request, not one per repository: multiple `repo:` qualifiers are OR'd.
        XCTAssertEqual(
            query.text,
            "is:pr author:@me -is:draft repo:acme/billing repo:acme/source"
        )
    }

    /// The case that would be a silent widening bug: the base qualifiers alone *are* the
    /// `all` query, so falling back to them when the user has unchecked everything would
    /// quietly poll every repository they have ever opened a pull request in.
    func testEmptySelectionBuildsNoQueryRatherThanTheAllQuery() {
        XCTAssertNil(SearchQuery.build(scope: .selected([])))
        XCTAssertNil(SearchQuery.build(scope: .selected(["  ", "not-a-repo"])))
    }

    func testMalformedRepositoriesAreDroppedAndReported() throws {
        let query = try XCTUnwrap(
            SearchQuery.build(scope: .selected(["acme/billing", "acme billing", "acme"]))
        )
        // A single bad qualifier makes GitHub reject the whole search, taking every other
        // repository's results with it, so it never goes on the wire.
        XCTAssertEqual(query.text, "is:pr author:@me -is:draft repo:acme/billing")
        XCTAssertEqual(query.droppedRepositories, ["acme billing", "acme"])
    }

    func testDuplicateRepositoriesCollapseAndAreNotReportedAsDropped() throws {
        let query = try XCTUnwrap(
            SearchQuery.build(scope: .selected(["acme/Billing", " acme/billing ", "acme/billing"]))
        )
        XCTAssertEqual(query.text, "is:pr author:@me -is:draft repo:acme/Billing")
        XCTAssertTrue(query.droppedRepositories.isEmpty)
    }

    func testExtraQualifiersAreAppended() throws {
        let all = try XCTUnwrap(SearchQuery.build(scope: .all, extraQualifiers: ["is:open"]))
        XCTAssertEqual(all.text, "is:pr author:@me -is:draft is:open")

        let selected = try XCTUnwrap(
            SearchQuery.build(scope: .selected(["acme/billing"]), extraQualifiers: ["is:open"])
        )
        XCTAssertEqual(selected.text, "is:pr author:@me -is:draft repo:acme/billing is:open")
    }

    func testWellFormednessRejectsWhatWouldChangeTheQualifier() {
        XCTAssertTrue(RepoScope.isWellFormed("acme/billing"))
        XCTAssertTrue(RepoScope.isWellFormed("acme-corp/billing.api"))
        XCTAssertFalse(RepoScope.isWellFormed("acme"))
        XCTAssertFalse(RepoScope.isWellFormed("acme/billing/extra"))
        XCTAssertFalse(RepoScope.isWellFormed("/billing"))
        XCTAssertFalse(RepoScope.isWellFormed("acme/"))
        XCTAssertFalse(RepoScope.isWellFormed("acme/bil ling"))
        XCTAssertFalse(RepoScope.isWellFormed("acme/\"billing\""))
    }
}
