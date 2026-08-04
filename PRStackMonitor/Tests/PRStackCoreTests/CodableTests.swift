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
        let malformed = [
            "acme/billing",         // no number at all
            "#12",                  // no repository
            "acme/billing#",        // separator, but nothing after it
            "acme/billing#twelve",  // not a number
            "acme#12",              // no owner — the shape `LocalState.rekey` must reject
            "/billing#12",          // empty owner
            "acme/#12",             // empty name
            "acme/billing/api#12",  // three components; `nameWithOwner` is always two
            "acme/bil#ling#12",     // stray separator inside the repository
            "acme/billing#0",       // pull request numbers start at 1
            "acme/billing#-3",
            "acme/billing#+12",     // parses as 12, so it would round-trip as a different key
            "acme/billing#012"
        ]
        for raw in malformed {
            XCTAssertNil(PRID(rawValue: raw), "'\(raw)' should not parse as a pull request id")
        }
    }

    /// Parsing must be the exact inverse of ``PRID/rawValue``. `LocalState` keys survive a
    /// decode/encode cycle on every panel interaction, so a value that parses to something
    /// spelled differently would silently rewrite the user's stored state.
    func testPRIDParsingIsTheExactInverseOfItsRawValue() {
        for raw in ["acme/billing#4012", "acme/web#1", "a/b#999999"] {
            XCTAssertEqual(PRID(rawValue: raw)?.rawValue, raw)
        }
    }

    /// Decoding is where untrusted text becomes a `PRID`, so a pull request whose identity
    /// could not survive `rawValue` is rejected at the door — it never reaches `LocalState`
    /// to fail *that* decode, which would cost the user every dismissal and snooze.
    func testPullRequestRejectsAMalformedIdentity() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let malformed = [
            ("acme", 4012),             // no owner
            ("acme/billing", 0),        // numbers start at 1
            ("acme/billing", -3),
            ("acme/bil#ling", 7),       // would re-parse as a different repository
            ("acme/billing/api", 7)
        ]
        for (repo, number) in malformed {
            let json = """
            {"repo": "\(repo)", "number": \(number), "updatedAt": "2026-01-09T15:00:00Z"}
            """
            XCTAssertThrowsError(
                try decoder.decode(PullRequest.self, from: Data(json.utf8)),
                "'\(repo)#\(number)' should not decode as a pull request"
            )
        }
    }

    /// The inverse property has to hold for every id the system actually constructs, not
    /// only for the canonical strings picked above. `LocalState` persists exactly these
    /// keys, and decoding *throws* on one it cannot parse — so a single unparseable id
    /// costs the user their whole stored state, not one entry.
    func testEveryConstructedFixtureIDSurvivesItsOwnRawValue() throws {
        for name in Fixtures.allNames {
            let fixture = try Fixtures.load(name)
            for pullRequest in fixture.snapshot.pullRequests {
                XCTAssertTrue(
                    PRID.isWellFormed(repo: pullRequest.repo, number: pullRequest.number),
                    "\(name): \(pullRequest.id) is not a well-formed id"
                )
                XCTAssertEqual(
                    PRID(rawValue: pullRequest.id.rawValue),
                    pullRequest.id,
                    "\(name): \(pullRequest.id) does not survive its own rawValue"
                )
            }
        }
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
