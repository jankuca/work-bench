import Foundation
import NetKit
import XCTest
@testable import GitHubKit

/// Builds `refs(refPrefix: "refs/tags/")` responses.
///
/// Synthetic, like every other fixture here: invented repositories and tag names. The
/// shape is what matters — an annotated tag and a lightweight one carry their dates in
/// different places, and that difference is the source of two of the failures these tests
/// exist to catch.
enum TagPage {
    struct Tag {
        var name: String
        /// The commit the tag ultimately points at.
        var commit: String
        /// `tagger.date` for an annotated tag, the target commit's `committedDate` for a
        /// lightweight one — in both cases, the date the tag itself carries.
        var taggedAt: String
        /// The target commit's own date. Only an annotated tag can have this differ from
        /// ``taggedAt``, which is exactly the case that breaks server ordering.
        var committedDate: String?
        var isAnnotated: Bool

        static func lightweight(_ name: String, commit: String, date: String) -> Tag {
            Tag(name: name, commit: commit, taggedAt: date, committedDate: date, isAnnotated: false)
        }

        /// A tag cut at `taggedAt` against a commit written at `committedDate`.
        static func annotated(_ name: String, commit: String, taggedAt: String, committedDate: String) -> Tag {
            Tag(
                name: name,
                commit: commit,
                taggedAt: taggedAt,
                committedDate: committedDate,
                isAnnotated: true
            )
        }
    }

    static func json(
        tags: [Tag],
        hasNextPage: Bool = false,
        endCursor: String? = nil,
        cost: Int = 1,
        remaining: Int = 4_900
    ) -> String {
        let nodes = tags.map { tag -> String in
            if tag.isAnnotated {
                return """
                {
                  "name": "\(tag.name)",
                  "target": {
                    "__typename": "Tag",
                    "oid": "tagobject-\(tag.name)",
                    "tagger": { "date": "\(tag.taggedAt)" },
                    "target": {
                      "__typename": "Commit",
                      "oid": "\(tag.commit)",
                      "committedDate": "\(tag.committedDate ?? tag.taggedAt)"
                    }
                  }
                }
                """
            }
            return """
            {
              "name": "\(tag.name)",
              "target": {
                "__typename": "Commit",
                "oid": "\(tag.commit)",
                "committedDate": "\(tag.taggedAt)"
              }
            }
            """
        }
        let cursor = endCursor.map { "\"\($0)\"" } ?? "null"
        return """
        {
          "data": {
            "rateLimit": {
              "limit": 5000, "cost": \(cost), "remaining": \(remaining),
              "resetAt": "2026-01-10T13:00:00Z"
            },
            "repository": {
              "refs": {
                "pageInfo": { "hasNextPage": \(hasNextPage), "endCursor": \(cursor) },
                "nodes": [\(nodes.joined(separator: ","))]
              }
            }
          }
        }
        """
    }
}

final class TagRefsClientTests: XCTestCase {
    private let endpoint = URL(string: "https://api.github.test/graphql")!

    private func client(_ transport: StubTransport, pageSize: Int = 100, pageCap: Int = 10) -> TagRefsClient {
        TagRefsClient(
            transport: transport,
            tokenProvider: StaticTokenProvider("ghp_test"),
            configuration: TagRefsClient.Configuration(
                pageSize: pageSize,
                pageCap: pageCap,
                endpoint: endpoint
            )
        )
    }

    private static func day(_ number: Int) -> String {
        String(format: "2026-01-%02dT12:00:00Z", number)
    }

    /// `release-tag-on-later-page`. A repository that tags often can easily push the
    /// matching tag past the first page, and a truncated candidate list produces a false
    /// "not shipped yet" that never self-corrects.
    func testPaginationWalksEveryPage() async throws {
        let firstPage = (1...25).map { index in
            TagPage.Tag.lightweight("v1.0.\(index)", commit: "c\(index)", date: TagRefsClientTests.day(1))
        }
        let secondPage = [
            TagPage.Tag.lightweight("v1.1.0", commit: "shipped", date: TagRefsClientTests.day(9))
        ]
        let transport = StubTransport(responses: [
            .json(TagPage.json(tags: firstPage, hasNextPage: true, endCursor: "PAGE2")),
            .json(TagPage.json(tags: secondPage))
        ])

        let fetch = try await client(transport, pageSize: 25)
            .fetchCandidates(repository: "acme/billing", glob: Glob("v*"))

        XCTAssertEqual(fetch.pagesFetched, 2)
        XCTAssertEqual(fetch.candidates.count, 26)
        XCTAssertTrue(fetch.isComplete)
        XCTAssertEqual(fetch.candidates.last?.name, "v1.1.0")
        XCTAssertEqual(try transport.requestVariables(1)["cursor"] as? String, "PAGE2")
        XCTAssertEqual(fetch.pointsSpent, 2)
    }

    /// The ref list can shift under pagination, so the same tag can arrive on two pages.
    /// Keeping the first sighting makes the candidate list the same either way.
    func testARepeatedTagAcrossPagesIsCountedOnce() async throws {
        let tag = TagPage.Tag.lightweight("v1.0.0", commit: "c1", date: TagRefsClientTests.day(1))
        let transport = StubTransport(responses: [
            .json(TagPage.json(tags: [tag], hasNextPage: true, endCursor: "PAGE2")),
            .json(TagPage.json(tags: [tag]))
        ])

        let fetch = try await client(transport, pageSize: 1)
            .fetchCandidates(repository: "acme/billing", glob: Glob("v*"))

        XCTAssertEqual(fetch.candidates.map(\.name), ["v1.0.0"])
        XCTAssertEqual(fetch.pagesFetched, 2)
    }

    /// Release tracking runs after both pull request searches, so it is the last thing
    /// spending the allowance and the first thing that should stop.
    func testPaginationStopsAtTheRateLimitFloor() async throws {
        let tag = TagPage.Tag.lightweight("v1.0.0", commit: "c1", date: TagRefsClientTests.day(1))
        let transport = StubTransport(responses: [
            .json(TagPage.json(tags: [tag], hasNextPage: true, endCursor: "PAGE2", remaining: 400)),
            .json(TagPage.json(tags: [tag]))
        ])

        let fetch = try await client(transport, pageSize: 1)
            .fetchCandidates(repository: "acme/billing", glob: Glob("v*"))

        XCTAssertEqual(fetch.pagesFetched, 1)
        XCTAssertFalse(fetch.isComplete)
        XCTAssertEqual(
            fetch.warnings,
            [.rateLimitFloorReached(
                remaining: 400,
                limit: 5_000,
                resetAt: ISO8601DateFormatter().date(from: "2026-01-10T13:00:00Z")
            )]
        )
    }

    /// `release-annotated-tag-on-older-commit`. `TAG_COMMIT_DATE` sorts by the *target
    /// commit's* date, so a tag cut today against an older commit arrives first. Since the
    /// binding is permanent, taking the server's first hit would pin a pull request to a
    /// later release forever.
    func testCandidatesAreReorderedByTheirOwnTimestamps() async throws {
        let serverOrder = [
            // Cut on the 9th, but against a commit from the 2nd — so the server lists it first.
            TagPage.Tag.annotated(
                "v2.0.0",
                commit: "old-commit",
                taggedAt: TagRefsClientTests.day(9),
                committedDate: TagRefsClientTests.day(2)
            ),
            TagPage.Tag.lightweight("v1.5.0", commit: "newer-commit", date: TagRefsClientTests.day(5))
        ]
        let transport = StubTransport(responses: [.json(TagPage.json(tags: serverOrder))])

        let fetch = try await client(transport)
            .fetchCandidates(repository: "acme/billing", glob: Glob("v*"))

        XCTAssertEqual(fetch.candidates.map(\.name), ["v1.5.0", "v2.0.0"])
        // The annotated tag's commit is one level in from `target.oid`; comparing the tag
        // object's id against a merge commit would never match.
        XCTAssertEqual(fetch.candidates.last?.commit, "old-commit")
        XCTAssertEqual(fetch.candidates.last?.taggedAt, ISO8601DateFormatter().date(from: TagRefsClientTests.day(9)))
    }

    /// Two tags on the same commit share a timestamp, and the binding they produce is
    /// permanent — so the tie-break has to be deterministic rather than API order.
    func testTiesBreakOnName() async throws {
        let transport = StubTransport(responses: [
            .json(TagPage.json(tags: [
                TagPage.Tag.lightweight("v1.0.1", commit: "same", date: TagRefsClientTests.day(4)),
                TagPage.Tag.lightweight("v1.0.0", commit: "same", date: TagRefsClientTests.day(4))
            ]))
        ])

        let fetch = try await client(transport)
            .fetchCandidates(repository: "acme/billing", glob: Glob("v*"))
        XCTAssertEqual(fetch.candidates.map(\.name), ["v1.0.0", "v1.0.1"])
    }

    func testTheLiteralPrefixIsSentAsAPrefilter() async throws {
        let transport = StubTransport(responses: [.json(TagPage.json(tags: []))])
        _ = try await client(transport)
            .fetchCandidates(repository: "acme/billing", glob: Glob("release-*"))

        let variables = try transport.requestVariables(0)
        XCTAssertEqual(variables["prefilter"] as? String, "release-")
        XCTAssertEqual(variables["owner"] as? String, "acme")
        XCTAssertEqual(variables["name"] as? String, "billing")
    }

    /// A pattern that opens with a wildcard has no prefix to send, and the filter is
    /// **omitted entirely** rather than guessed at.
    func testALeadingWildcardSendsNoPrefilter() async throws {
        let transport = StubTransport(responses: [.json(TagPage.json(tags: []))])
        _ = try await client(transport)
            .fetchCandidates(repository: "acme/billing", glob: Glob("*-prod"))

        let variables = try transport.requestVariables(0)
        XCTAssertTrue(variables["prefilter"] is NSNull, "expected an omitted prefilter, got \(variables)")
    }

    /// The server-side filter is a substring match, so it admits far more than the pattern
    /// does. Without the local pass, `*-prod` would bind a pull request to a staging tag.
    func testTheGlobIsAppliedAgainLocally() async throws {
        let transport = StubTransport(responses: [
            .json(TagPage.json(tags: [
                TagPage.Tag.lightweight("2026-01-09-prod", commit: "c1", date: TagRefsClientTests.day(9)),
                TagPage.Tag.lightweight("2026-01-09-staging", commit: "c2", date: TagRefsClientTests.day(9))
            ]))
        ])

        let fetch = try await client(transport)
            .fetchCandidates(repository: "acme/billing", glob: Glob("*-prod"))
        XCTAssertEqual(fetch.candidates.map(\.name), ["2026-01-09-prod"])
    }

    /// A tag with no date of its own cannot be ordered, and a candidate that cannot be
    /// ordered cannot be tested oldest-first — so it is dropped rather than guessed at.
    func testARefWithNoDateIsSkipped() async throws {
        let json = """
        {
          "data": {
            "repository": {
              "refs": {
                "pageInfo": { "hasNextPage": false, "endCursor": null },
                "nodes": [
                  { "name": "v9.9.9", "target": { "__typename": "Tree", "oid": "tree1" } },
                  {
                    "name": "v1.0.0",
                    "target": {
                      "__typename": "Commit", "oid": "c1",
                      "committedDate": "2026-01-04T12:00:00Z"
                    }
                  }
                ]
              }
            }
          }
        }
        """
        let transport = StubTransport(responses: [.json(json)])
        let fetch = try await client(transport)
            .fetchCandidates(repository: "acme/billing", glob: Glob("v*"))
        XCTAssertEqual(fetch.candidates.map(\.name), ["v1.0.0"])
    }

    func testThePageCapStopsTheLoopAndSaysSo() async throws {
        let page = [TagPage.Tag.lightweight("v1.0.0", commit: "c1", date: TagRefsClientTests.day(1))]
        let transport = StubTransport(responses: [
            .json(TagPage.json(tags: page, hasNextPage: true, endCursor: "P2")),
            .json(TagPage.json(tags: page, hasNextPage: true, endCursor: "P3"))
        ])

        let fetch = try await client(transport, pageSize: 1, pageCap: 2)
            .fetchCandidates(repository: "acme/billing", glob: Glob("v*"))

        XCTAssertFalse(fetch.isComplete)
        XCTAssertEqual(fetch.pagesFetched, 2)
        XCTAssertEqual(fetch.warnings, [.tagPageCapReached(repository: "acme/billing", pages: 2)])
    }

    /// A repository name that cannot be split is dropped rather than sent: the query takes
    /// `owner` and `name` separately, and a malformed pair would fail the request.
    func testAMalformedRepositoryIsDroppedWithoutARequest() async throws {
        let transport = StubTransport(responses: [])
        let fetch = try await client(transport)
            .fetchCandidates(repository: "billing", glob: Glob("v*"))

        XCTAssertEqual(fetch.warnings, [.repositoryDropped("billing")])
        XCTAssertTrue(transport.requests.isEmpty)
    }
}
