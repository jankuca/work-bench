import Foundation
import XCTest
@testable import PRStackCore

final class CodableTests: XCTestCase {
    func testPRIDRoundTripsThroughItsRawValue() {
        let id = PRID(repo: "acme/billing", number: 4012)
        XCTAssertEqual(id.rawValue, "acme/billing#4012")
        XCTAssertEqual(PRID(rawValue: id.rawValue), id)
    }

    func testPRIDRejectsMalformedRawValues() {
        XCTAssertNil(PRID(rawValue: "acme/billing"))
        XCTAssertNil(PRID(rawValue: "#12"))
        XCTAssertNil(PRID(rawValue: "acme/billing#"))
        XCTAssertNil(PRID(rawValue: "acme/billing#twelve"))
    }

    /// `LocalState` is written to disk on every panel interaction, so its keys have to
    /// survive a round trip as readable JSON object keys rather than as key/value arrays.
    func testLocalStateRoundTrips() throws {
        let id = PRID(repo: "acme/billing", number: 4012)
        let other = PRID(repo: "acme/web", number: 77)
        let state = LocalState(
            dismissed: [other],
            snoozedUntil: [id: Date(timeIntervalSince1970: 1_767_960_000)],
            readDigests: [id: ReadDigest(value: "rd=-;ck=passing;mg=mergeable;cc=0;lc=-;rs=unmerged")],
            releaseBindings: [other: "v1.4.0"]
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let decoded = try decoder.decode(LocalState.self, from: encoder.encode(state))
        XCTAssertEqual(decoded, state)
    }

    func testCheckRollupAcceptsBothFixtureSpellings() throws {
        struct Wrapper: Decodable {
            let checks: CheckRollup
        }
        let decoder = JSONDecoder()
        XCTAssertEqual(
            try decoder.decode(Wrapper.self, from: Data(#"{"checks":"passing"}"#.utf8)).checks,
            .passing
        )
        XCTAssertEqual(
            try decoder.decode(Wrapper.self, from: Data(#"{"checks":{"state":"failing","failingCount":2}}"#.utf8)).checks,
            .failing(2)
        )
    }

    /// The digest is a canonical string, not a hash, precisely so that it means the same
    /// thing in the next process. Pin the exact spelling.
    func testReadDigestSpelling() {
        let pullRequest = PullRequest(
            repo: "acme/billing",
            number: 4012,
            title: "Invoice renderer",
            headRef: "jk/invoice",
            baseRef: "main",
            reviewDecision: .changesRequested,
            checks: .failing(2),
            mergeable: .mergeable,
            updatedAt: Date(timeIntervalSince1970: 1_767_960_000),
            commentCount: 7,
            lastCommentAt: Date(timeIntervalSince1970: 1_767_950_000)
        )

        XCTAssertEqual(
            ReadDigest.make(for: pullRequest, releaseStage: .unmerged).value,
            "rd=changesRequested;ck=failing:2;mg=mergeable;cc=7;lc=1767950000;rs=unmerged"
        )
    }

    func testPullRequestDecodesWithMinimalFixtureFields() throws {
        let json = #"""
        {
          "repo": "acme/billing",
          "number": 4012,
          "title": "Invoice renderer",
          "headRef": "jk/invoice",
          "baseRef": "main",
          "updatedAt": "2026-01-09T15:00:00Z"
        }
        """#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let pullRequest = try decoder.decode(PullRequest.self, from: Data(json.utf8))

        XCTAssertEqual(pullRequest.id, PRID(repo: "acme/billing", number: 4012))
        XCTAssertEqual(pullRequest.state, .open)
        XCTAssertEqual(pullRequest.checks, .noChecks)
        XCTAssertEqual(pullRequest.mergeable, .unknown)
        XCTAssertEqual(pullRequest.createdAt, pullRequest.updatedAt)
        XCTAssertEqual(pullRequest.url.absoluteString, "https://github.com/acme/billing/pull/4012")
        XCTAssertTrue(pullRequest.linearIssues.isEmpty)
    }

    func testSnapshotFillsInTheViewerAsTheDefaultAuthor() {
        let snapshot = RawSnapshot(
            viewerLogin: "jankuca",
            pullRequests: [
                PullRequest(repo: "acme/billing", number: 1, title: "Mine", headRef: "a", baseRef: "main", updatedAt: Date()),
                PullRequest(
                    repo: "acme/billing",
                    number: 2,
                    title: "Theirs",
                    headRef: "b",
                    baseRef: "main",
                    authorLogin: "otherdev",
                    updatedAt: Date()
                )
            ]
        )

        XCTAssertEqual(snapshot.pullRequests[0].authorLogin, "jankuca")
        XCTAssertEqual(snapshot.pullRequests[1].authorLogin, "otherdev")
    }
}
