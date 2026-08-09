import Foundation
import XCTest
@testable import GitHubKit

final class GlobTests: XCTestCase {
    func testTheDefaultPatternMatchesOrdinaryVersionTags() {
        let glob = Glob(TagPatterns.defaultPattern)
        XCTAssertTrue(glob.matches("v1.4.0"))
        XCTAssertTrue(glob.matches("v2026.01.09"))
        XCTAssertFalse(glob.matches("release-1.4.0"))
        XCTAssertFalse(glob.matches("1.4.0"))
    }

    /// The case the local pass exists for. `refs(query:)` is a substring filter, so a
    /// server-side prefilter cannot express this pattern at all — and admitting every tag
    /// in the repository would bind a pull request to a staging tag.
    func testALeadingWildcardMatchesOnlyTheIntendedSuffix() {
        let glob = Glob("*-prod")
        XCTAssertTrue(glob.matches("2026-01-09-prod"))
        XCTAssertFalse(glob.matches("2026-01-09-staging"))
        XCTAssertEqual(glob.literalPrefix, "", "a leading wildcard has no prefilter to send")
    }

    func testLiteralPrefixStopsAtTheFirstWildcard() {
        XCTAssertEqual(Glob("v*").literalPrefix, "v")
        XCTAssertEqual(Glob("release-*").literalPrefix, "release-")
        XCTAssertEqual(Glob("v?.*").literalPrefix, "v")
        XCTAssertEqual(Glob("v[0-9]*").literalPrefix, "v")
        XCTAssertEqual(Glob("v1.4.0").literalPrefix, "v1.4.0")
        // An escaped wildcard is a literal, so it belongs in the prefilter — and the
        // prefilter decides which tags the local matcher ever sees.
        XCTAssertEqual(Glob(#"\*-prod"#).literalPrefix, "*-prod")
    }

    func testQuestionMarkMatchesExactlyOneCharacter() {
        XCTAssertTrue(Glob("v?.0").matches("v1.0"))
        XCTAssertFalse(Glob("v?.0").matches("v10.0"))
        XCTAssertFalse(Glob("v?.0").matches("v.0"))
    }

    func testBracketExpressions() {
        XCTAssertTrue(Glob("v[0-9].*").matches("v3.1.4"))
        XCTAssertFalse(Glob("v[0-9].*").matches("vx.1.4"))
        XCTAssertTrue(Glob("v[!0-9]*").matches("vnext"))
        XCTAssertFalse(Glob("v[!0-9]*").matches("v1.0"))
        XCTAssertTrue(Glob("v[^0-9]*").matches("vnext"))
        // An unterminated bracket is a literal bracket, which is what every fnmatch does.
        XCTAssertTrue(Glob("v[1.0").matches("v[1.0"))
    }

    func testEscapingMakesAWildcardLiteral() {
        XCTAssertTrue(Glob(#"v1.0\*"#).matches("v1.0*"))
        XCTAssertFalse(Glob(#"v1.0\*"#).matches("v1.0.1"))
    }

    /// A tag name is not a path, so `FNM_PATHNAME` is deliberately absent: a repository
    /// that tags `release/1.4.0` has to be matchable by `release/*`, and by `release*`.
    func testSlashesAreOrdinaryCharacters() {
        XCTAssertTrue(Glob("release/*").matches("release/1.4.0"))
        XCTAssertTrue(Glob("release*").matches("release/1.4.0"))
    }

    func testEdgesOfTheMatcher() {
        XCTAssertTrue(Glob("*").matches(""))
        XCTAssertTrue(Glob("*").matches("anything"))
        XCTAssertTrue(Glob("**").matches("v1"))
        XCTAssertFalse(Glob("").matches("v1"))
        XCTAssertTrue(Glob("").matches(""))
        // The pathological backtracking shape, which the star-collapsing keeps linear.
        XCTAssertFalse(Glob("v*a*b*c*d*e*f").matches(String(repeating: "v", count: 64)))
    }
}

final class TagPatternsTests: XCTestCase {
    func testAnythingUnlistedTakesTheDefault() {
        let patterns = TagPatterns(["acme/billing": "release-*"])
        XCTAssertEqual(patterns.pattern(for: "acme/billing"), "release-*")
        XCTAssertEqual(patterns.pattern(for: "acme/web"), TagPatterns.defaultPattern)
    }

    /// GitHub treats `Acme/Billing` and `acme/billing` as one repository, and the user may
    /// well type one while search results show the other.
    func testLookupIsCaseInsensitive() {
        let patterns = TagPatterns(["Acme/Billing": "release-*"])
        XCTAssertEqual(patterns.pattern(for: "acme/billing"), "release-*")
    }

    /// An empty pattern matches nothing at all, so honouring it would switch release
    /// tracking off for that repository without saying so.
    func testAnEmptyPatternIsNoEntry() {
        let patterns = TagPatterns(["acme/billing": "  "])
        XCTAssertEqual(patterns.pattern(for: "acme/billing"), TagPatterns.defaultPattern)
    }

    /// The setter has to reject what the initialiser rejects, or the two disagree about
    /// their own key space: a blank repository would store its pattern under `""` and
    /// `pattern(for: "")` would answer with it instead of the default.
    func testTheSetterRejectsABlankRepository() {
        var patterns = TagPatterns()
        patterns.set("release-*", for: "  ")
        XCTAssertEqual(patterns.pattern(for: ""), TagPatterns.defaultPattern)
        XCTAssertTrue(patterns.byRepository.isEmpty)

        patterns.set("release-*", for: "Acme/Billing")
        XCTAssertEqual(patterns.pattern(for: "acme/billing"), "release-*")
        patterns.set(nil, for: "acme/billing")
        XCTAssertEqual(patterns.pattern(for: "acme/billing"), TagPatterns.defaultPattern)
    }
}
