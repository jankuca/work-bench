import Foundation
import PRStackCore
import XCTest
@testable import LinearKit

final class IssueIdentifierScannerTests: XCTestCase {
    private func pullRequest(
        title: String = "Untitled",
        body: String? = nil,
        headRef: String = "jk/work"
    ) -> PullRequest {
        PullRequest(
            repo: "acme/billing",
            number: 4012,
            title: title,
            body: body,
            headRef: headRef,
            baseRef: "main",
            updatedAt: Date(timeIntervalSince1970: 1_767_000_000)
        )
    }

    // MARK: - Order

    /// Branch, then title, then body — and the order is the contract, because the primary
    /// issue is the first of these with a project and the primary decides the section.
    func testScansBranchThenTitleThenBody() {
        let pullRequest = pullRequest(
            title: "Also touches PAY-90",
            body: "Closes OPS-4",
            headRef: "jk/bil-312-add-tax-rows"
        )
        XCTAssertEqual(
            IssueIdentifierScanner.identifiers(in: pullRequest),
            ["BIL-312", "PAY-90", "OPS-4"]
        )
    }

    func testDeduplicatesKeepingFirstSeenPosition() {
        let pullRequest = pullRequest(
            title: "Fixes BIL-312, BIL-313 and BIL-312 again",
            body: "BIL-313 BIL-312 SRC-97",
            headRef: "jk/bil-313"
        )
        XCTAssertEqual(
            IssueIdentifierScanner.identifiers(in: pullRequest),
            ["BIL-313", "BIL-312", "SRC-97"]
        )
    }

    /// `pr-body-only-identifier` (IMPLEMENTATION_PLAN §6). The body is the third source in
    /// the scan and the only one here, so dropping it — which is exactly what an absent
    /// `body` in the DTO would do — files this pull request under `Other`.
    func testBodyOnlyIdentifierIsFound() {
        let pullRequest = pullRequest(
            title: "Tidy the ledger export",
            body: "Closes: https://linear.app/acme/issue/BIL-312/add-tax-rows",
            headRef: "jk/tidy-ledger-export"
        )
        XCTAssertEqual(IssueIdentifierScanner.identifiers(in: pullRequest), ["BIL-312"])
    }

    func testBodyKeepsReadingOrderAcrossURLsAndBareIdentifiers() {
        let body = """
        Part of https://linear.app/acme/issue/BIL-312/add-tax-rows

        Also closes SRC-97, and see https://linear.app/acme/issue/PAY-90 for the follow-up.
        """
        XCTAssertEqual(
            IssueIdentifierScanner.scanBody(body),
            ["BIL-312", "SRC-97", "PAY-90"]
        )
    }

    // MARK: - Branch names

    /// Branch names are conventionally lower-case, and the trailing slug is the single
    /// most common shape. Neither may cost the identifier.
    func testBranchIdentifiersAreCaseInsensitiveAndSurviveASlug() {
        XCTAssertEqual(
            IssueIdentifierScanner.scan("jk/bil-312-add-tax-rows", requiringUppercase: false)
                .map(\.identifier),
            ["BIL-312"]
        )
        XCTAssertEqual(
            IssueIdentifierScanner.scan("feature/BIL-312", requiringUppercase: false).map(\.identifier),
            ["BIL-312"]
        )
        XCTAssertEqual(
            IssueIdentifierScanner.scan("jk_bil-312", requiringUppercase: false).map(\.identifier),
            ["BIL-312"]
        )
    }

    /// A number is not truncated to make a shorter identifier, and a trailing segment is
    /// not read as a second one.
    func testNumbersAreNotTruncatedAndSlugsAreNotIdentifiers() {
        XCTAssertEqual(
            IssueIdentifierScanner.scan("jk/bil-3120", requiringUppercase: false).map(\.identifier),
            ["BIL-3120"]
        )
        XCTAssertEqual(
            IssueIdentifierScanner.scan("bil-312-9", requiringUppercase: false).map(\.identifier),
            ["BIL-312"]
        )
    }

    func testSingleLetterKeysAndDigitKeysAreNotIdentifiers() {
        XCTAssertEqual(IssueIdentifierScanner.scan("x-1", requiringUppercase: false).count, 0)
        XCTAssertEqual(IssueIdentifierScanner.scan("no-digits-here", requiringUppercase: false).count, 0)
        // A date's first component is not a key, so `2026-01` is not an identifier.
        XCTAssertEqual(
            IssueIdentifierScanner.scan("2026-01-10", requiringUppercase: false).map(\.identifier),
            []
        )
    }

    /// A release branch scans as `RELEASE-2026`, and that is the accepted cost of the
    /// case-insensitive branch pass.
    ///
    /// Nothing local can tell a seven-letter team key from the word "release", so the
    /// alternatives were a length cap on team keys — a constraint Linear does not publish —
    /// or a deny list that goes stale. What makes it cheap instead is the negative cache:
    /// Linear is asked once, answers no, and the answer is remembered.
    func testAReleaseBranchScansAsAnIdentifierAndIsLeftForResolution() {
        XCTAssertEqual(
            IssueIdentifierScanner.scan("release-2026-01-10", requiringUppercase: false)
                .map(\.identifier),
            ["RELEASE-2026"]
        )
    }

    // MARK: - Prose

    /// Titles and bodies are written in English, so they are matched case-sensitively.
    /// Matching `covid-19` there would put junk ahead of the real ticket in an order the
    /// primary issue is chosen from — and the primary decides the section.
    func testProseDoesNotMatchLowerCaseWords() {
        let pullRequest = pullRequest(
            title: "Post-covid-19 top-10 rewrite, fixes BIL-312",
            headRef: "jk/rewrite"
        )
        XCTAssertEqual(IssueIdentifierScanner.identifiers(in: pullRequest), ["BIL-312"])
    }

    /// `UTF-8` has the exact shape of a Linear identifier and no local rule can say
    /// otherwise. It is scanned, and resolution is what drops it — pinned here so the
    /// behaviour is a decision on record rather than a surprise in the field.
    func testUpperCaseFalsePositivesAreScannedAndLeftForResolution() {
        let pullRequest = pullRequest(title: "Fix UTF-8 handling in the SHA-256 digest")
        XCTAssertEqual(IssueIdentifierScanner.identifiers(in: pullRequest), ["UTF-8", "SHA-256"])
    }

    // MARK: - URLs

    func testIssueURLsAreReadCaseInsensitivelyAndWithoutTheirSlug() {
        XCTAssertEqual(
            IssueIdentifierScanner.scanBody("see https://linear.app/acme/issue/bil-312/add-tax-rows"),
            ["BIL-312"]
        )
        XCTAssertEqual(
            IssueIdentifierScanner.scanBody("(https://linear.app/acme/issue/BIL-312)"),
            ["BIL-312"]
        )
        XCTAssertEqual(
            IssueIdentifierScanner.scanBody("https://linear.app/acme/issue/BIL-312?tab=activity"),
            ["BIL-312"]
        )
    }

    /// A URL that merely *contains* `linear.app` is not a Linear URL, and reading one as
    /// though it were resolves a real ticket whose project then groups somebody else's
    /// pull request under it. The host has to be the whole host.
    func testOnlyACompleteLinearHostIsReadAsALinearURL() {
        // Lower case throughout, because the URL pass is case-insensitive and these would
        // otherwise be caught by the case-sensitive bare-identifier scan instead.
        XCTAssertEqual(
            IssueIdentifierScanner.scanBody("https://notlinear.app/acme/issue/bil-312"),
            []
        )
        XCTAssertEqual(
            IssueIdentifierScanner.scanBody("https://example.com/linear.app/acme/issue/bil-312"),
            []
        )
        XCTAssertEqual(
            IssueIdentifierScanner.scanBody("https://linear.apple.com/acme/issue/bil-312"),
            []
        )
        // …while the shapes that really are Linear still resolve.
        XCTAssertEqual(
            IssueIdentifierScanner.scanBody("https://linear.app/acme/issue/bil-312"),
            ["BIL-312"]
        )
        XCTAssertEqual(
            IssueIdentifierScanner.scanBody("https://www.linear.app/acme/issue/bil-312"),
            ["BIL-312"]
        )
        XCTAssertEqual(
            IssueIdentifierScanner.scanBody("linear.app/acme/issue/bil-312"),
            ["BIL-312"]
        )
    }

    /// A `linear.app` mention in one paragraph and an `/issue/` path in another are not
    /// one URL, and joining them would invent an identifier neither of them names.
    func testAnIssuePathInADifferentURLIsNotJoinedToLinear() {
        let body = """
        We use linear.app for tickets.

        See https://example.com/issue/BOGUS-1 for the write-up.
        """
        // `BOGUS-1` is still scanned — it is upper-case prose, and resolution will drop it.
        // What must not happen is it being read as a *Linear* issue URL.
        XCTAssertEqual(IssueIdentifierScanner.scanBody(body), ["BOGUS-1"])
    }
}
